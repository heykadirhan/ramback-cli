import CryptoKit
import Foundation

/// Makes a snapshot safe to share for Export diagnostics. The home folder becomes `~`, and folder and file names that
/// could name a person or a project become short hashes (the same name always gets the same hash within one export).
/// What the detectors read survives: executable names, system and tool folders (Library/Developer, .gradle, Android/sdk,
/// node_modules), simulator UDIDs, flags, ports and class names. Long tokens and values after key/token/password flags
/// are hashed too, since arguments can carry secrets.
// ponytail: name lists and heuristics, not a parser; a secret in a short bare argument (mysql -pSECRET) gets through,
// which is why the user sees the whole file before saving it.
public struct Anonymizer: Sendable {
    let home: String
    /// Random per export, so a hash can't be looked up in a list of common folder names.
    let salt: String

    public init(home: String = NSHomeDirectory(), salt: String = UUID().uuidString) {
        self.home = home
        self.salt = salt
    }

    public func callAsFunction(_ snapshot: Snapshot) -> Snapshot {
        // The first pass only learns which names are the user's folders, so the second can also catch them as bare
        // words and executable names ("MyApp" inside MyApp.app).
        var names = Set<String>()
        _ = snapshot.procs.map { mask($0, &names) }
        var masked = snapshot
        masked.procs = snapshot.procs.map { mask($0, &names) }
        return masked
    }

    /// An executable's path, such as a tool found in Settings > Tools: masked, keeping the executable's name.
    public func executable(_ path: String) -> String {
        var names = Set<String>()
        return self.path(path, &names, keepLast: true)
    }

    // MARK: Masking

    private func mask(_ proc: Proc, _ names: inout Set<String>) -> Proc {
        var p = proc
        p.path = path(p.path, &names, keepLast: true)
        p.name = (p.path as NSString).lastPathComponent
        p.cwd = path(p.cwd, &names)
        var secret = false
        p.args = p.args.map { arg($0, &names, secret: &secret) }
        return p
    }

    private func path(_ path: String, _ names: inout Set<String>, keepLast: Bool = false) -> String {
        var path = path
        if path == home || path.hasPrefix(home + "/") { path = "~" + path.dropFirst(home.count) }
        if Self.system.contains(where: path.hasPrefix) { return path }
        var parts = path.components(separatedBy: "/")
        var inPackage = false
        for i in parts.indices where !inPackage {
            inPackage = parts[i] == "node_modules"  // package names are public
            if keepLast, i == parts.count - 1, !names.contains(parts[i]) { break }
            parts[i] = component(parts[i], &names)
        }
        return parts.joined(separator: "/")
    }

    /// Paths are masked whole; anything else is split into words, and words with a slash are masked as paths.
    private func arg(_ arg: String, _ names: inout Set<String>, secret: inout Bool) -> String {
        if arg.hasPrefix("/") || arg.hasPrefix("~") { return path(arg, &names) }
        var out = "", word = ""
        for c in arg {
            if c.isWhitespace || ":=,;\"'".contains(c) {
                out += self.word(word, &names, secret: &secret) + String(c)
                word = ""
            } else {
                word.append(c)
            }
        }
        return out + self.word(word, &names, secret: &secret)
    }

    private func word(_ word: String, _ names: inout Set<String>, secret: inout Bool) -> String {
        guard !word.isEmpty else { return word }
        if word.contains("/") { return path(word, &names) }
        // user:password@host in URLs and email addresses: everything before the @, and any host but this Mac.
        if word.contains("@") {
            let parts = word.split(separator: "@", omittingEmptySubsequences: false).map(String.init)
            let host = parts.last ?? ""
            return parts.dropLast().map(hash).joined(separator: "@") + "@" + (["localhost", "127.0.0.1"].contains(host) ? host : hash(host))
        }
        if secret {
            secret = false
            return hash(word)
        }
        let lower = word.lowercased()
        secret = ["key", "token", "secret", "pass", "auth", "credential"].contains { lower.contains($0) }
        let long = word.count >= 20 && word.contains(where: \.isNumber) && word.contains(where: \.isLetter)
        return long || names.contains(word) ? hash(word) : word
    }

    private func component(_ name: String, _ names: inout Set<String>) -> String {
        if name.isEmpty || name.hasPrefix(".") || name == "~" || Self.known.contains(name) || !name.contains(where: \.isLetter)
            || (name.count == 36 && UUID(uuidString: name) != nil) { return name }
        // Keep the extension: ".app/Contents/" is how detection tells an app from a server.
        let ext = (name as NSString).pathExtension
        let keepExt = !ext.isEmpty && ext.count <= 8 && ext.allSatisfy(\.isLetter)
        let stem = keepExt ? String(name.dropLast(ext.count + 1)) : name
        names.formUnion([name, stem])
        return hash(stem) + (keepExt ? "." + ext : "")
    }

    private func hash(_ text: String) -> String {
        SHA256.hash(data: Data((salt + text).utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Names that stay

    /// Installed software, not the user's files.
    static let system = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/", "/Applications/", "/opt/homebrew/", "/opt/local/",
                         "/private/etc/", "/dev/"]

    /// Folders and files that belong to tools, the usual folders projects sit in, script words that would otherwise be
    /// hashed wherever a folder shares their name (~/dev, npm run dev), and the words detectors look for in paths.
    static let known: Set<String> = Set([
        "Desktop", "Documents", "Downloads", "dev", "code", "projects", "Projects", "work", "repos", "git", "github", "Sites",
        "workspace", "start", "serve", "server", "test", "watch", "preview", "main", "index",
        "Users", "Shared", "Library", "Developer", "CoreSimulator", "Devices", "Xcode", "UserData", "Previews", "Simulator Devices",
        "DerivedData", "Build", "Products", "Debug", "Release", "Debug-iphonesimulator", "data", "Containers", "Bundle",
        "Application", "Application Support", "Caches", "Logs", "Applications", "Contents", "MacOS", "Frameworks", "Resources",
        "XPCServices", "Versions", "Current", "A", "Android", "sdk", "emulator", "qemu", "platform-tools", "build-tools",
        "cmdline-tools", "system-images", "avd", "daemon", "wrapper", "dists", "caches", "bin", "sbin", "lib", "libexec",
        "share", "etc", "var", "run", "tmp", "private", "opt", "usr", "local", "homebrew", "Cellar", "versions", "installation",
        "node", "bun", "deno", "java", "jbr", "python", "ruby", "go", "flutter", "dart", "cache", "gradle", "kotlin",
        "node_modules", "src", "dist", "build", "out", "target", "debug", "release", "localhost",
        "next", "vite", "nuxt", "nuxi", "astro", "remix", "storybook", "webpack", "webpack-dev-server", "wrangler", "vercel",
        "netlify", "firebase", "convex", "rails", "puma", "uvicorn", "gunicorn", "flask", "hugo", "jekyll", "phx.server",
        "react-native", "expo", "cli", "cli.js", "flutter_tools.snapshot", "launchd_sim", "launchd_bootstrap.plist", "device.plist",
    ]).union(Detection.agents.keys).union(Detection.databases.keys)
}
