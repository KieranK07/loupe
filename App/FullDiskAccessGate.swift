import Foundation
import AppKit
import LoupeCore

/// Full Disk Access cannot be requested programmatically and there is no API to
/// query it. The only honest test is to attempt a read of something TCC
/// protects and see what happens.
///
/// Loupe never blocks on this. Without the grant it scans the home directory and
/// says plainly which parts of the machine it cannot see.
@MainActor
@Observable
final class FullDiskAccessGate {

    enum Status: Equatable {
        case granted
        case denied
        case unknown

        var canSeeWholeMachine: Bool { self == .granted }
    }

    private(set) var status: Status = .unknown

    /// Paths TCC protects that a normal process cannot read without the grant.
    /// Several are probed because any single one may be absent on a given Mac,
    /// and "missing" must never be mistaken for "denied".
    private static let probes: [String] = [
        "\(NSHomeDirectory())/Library/Application Support/com.apple.TCC",
        "\(NSHomeDirectory())/Library/Safari",
        "/Library/Application Support/com.apple.TCC",
    ]

    /// Reads a directory listing only. Never opens a file: opening a dataless
    /// iCloud placeholder would materialise it, and this runs at launch.
    func refresh() {
        var sawProbe = false
        for path in Self.probes {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue
            else { continue }
            sawProbe = true
            if (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil {
                status = .granted
                return
            }
        }
        // Every protected path we could find refused us. If none existed at all,
        // we genuinely do not know rather than assuming the worst.
        status = sawProbe ? .denied : .unknown
    }

    /// Deep-links to the exact pane. The user still has to grant it themselves —
    /// there is no way around that, and Loupe does not pretend otherwise.
    func openSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// One sentence. Not a paragraph, not a pitch.
    var explanation: String {
        switch status {
        case .granted:
            "Loupe can see the whole volume."
        case .denied:
            "Without Full Disk Access, Loupe can only measure your home folder — other users' files and most of /Library stay invisible."
        case .unknown:
            "Loupe could not determine whether it has Full Disk Access."
        }
    }
}