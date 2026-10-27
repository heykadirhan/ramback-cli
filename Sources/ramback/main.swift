import Darwin
import Foundation
#if canImport(RambackCore)
import RambackCore  // SwiftPM; the Xcode target compiles the core sources straight in.
typealias Scanner = RambackCore.Scanner  // not Foundation's
#endif

let usage = """
    ramback: your Mac's dev stack and its RAM, from the command line.

    USAGE
      ramback status [--json]          What's running, by project, with RAM, ports and ids
      ramback stop <id|port|project>   Stop one row by id or port, or a project's rows
             [--yes] [--force] [--dry-run] [--json]
      ramback free <GB>                Stop idle simulators, emulators and daemons until about GB are freed
             [--dry-run] [--json]
      ramback mcp                      MCP server over stdio, for coding agents

    stop <project> and free leave pinned rows, databases and builds alone, like Clean slate. A pinned row or a
    database picked by id or port needs --yes. Stops are polite and wait 5 s; --force kills right away.

    EXIT CODES
      0 done   1 something failed or is still running   2 nothing matched or nothing to stop
      3 pinned or a database, pass --yes   64 usage
    """

let args = Array(CommandLine.arguments.dropFirst())
let words = args.filter { !$0.hasPrefix("-") }
let flags = Set(args.filter { $0.hasPrefix("-") })
let commands: [String: (words: Int, flags: Set<String>)] = [
    "status": (1, ["--json"]), "stop": (2, ["--yes", "--force", "--dry-run", "--json"]), "free": (2, ["--dry-run", "--json"]), "mcp": (1, []),
]

if args.isEmpty || flags.contains("--help") || flags.contains("-h") || words == ["help"] {
    print(usage)
    exit(0)
}
guard let command = words.first, let spec = commands[command], words.count == spec.words, flags.isSubset(of: spec.flags) else {
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(64)
}
let json = flags.contains("--json")

switch command {
case "status":
    exit(await status(json: json))
case "stop":
    exit(await stop(words[1], confirmed: flags.contains("--yes"), force: flags.contains("--force"), dryRun: flags.contains("--dry-run"), json: json))
case "free":
    guard let gb = Double(words[1]), gb > 0, gb < 1024 else {
        FileHandle.standardError.write(Data("free takes gigabytes, e.g. `ramback free 2`.\n".utf8))
        exit(64)
    }
    exit(await free(gb, dryRun: flags.contains("--dry-run"), json: json))
default:
    exit(await mcp())
}
