import Foundation
import Testing
@testable import RambackCore

private let mask = Anonymizer(home: "/Users/me", salt: "test")

/// Rows by kind with their pids, to compare detection before and after masking.
private func shape(_ items: [Item]) -> [String] { items.map { "\($0.kind) \($0.pids.sorted())" }.sorted() }

@Test func maskedSnapshotDetectsTheSame() {
    let masked = World(snapshot: mask(fixture.snapshot), simulators: fixture.simulators, containers: fixture.containers)
    #expect(shape(detect(masked)) == shape(detect(fixture)))
}

@Test func maskedSnapshotNamesNoUserFolder() throws {
    var snapshot = fixture.snapshot
    snapshot.procs.append(Proc(pid: 900, ppid: 1, path: "/Users/me/clients/acme-portal/bin/acme-portal",
                               args: ["acme-portal", "--config=/Users/me/clients/acme-portal/dev.json", "--api-key=sk_live_51HxQ",
                                      "--password", "hunter2", "run acme-portal",
                                      "DATABASE_URL=postgres://admin:komma@localhost:5432/shop", "--notify=jane@acme.dev"],
                               cwd: "/Users/me/clients/acme-portal"))
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    let json = String(decoding: try encoder.encode(mask(snapshot)), as: UTF8.self)
    for name in ["/Users/me", "/p/", "web", "/api", "MyApp", "/x/", "clients", "acme", "sk_live", "hunter2", "komma", "admin", "jane"] {
        #expect(!json.contains(name), "\(name) is in the masked snapshot")
    }
    for kept in ["~/Library/Developer/CoreSimulator/Devices/F9E4B8E5-497E-44BE-BE92-B3B08CE788BD/data", "node_modules/.bin/react-native",
                 "org.gradle.launcher.daemon.bootstrap.GradleDaemon", "\"-avd\"", "qemu-system-aarch64", "~/.gradle/daemon/8.7", "--password"] {
        #expect(json.contains(kept), "\(kept) was masked")
    }
    #expect(mask.executable("/Users/me/Library/Android/sdk/platform-tools/adb") == "~/Library/Android/sdk/platform-tools/adb")
}
