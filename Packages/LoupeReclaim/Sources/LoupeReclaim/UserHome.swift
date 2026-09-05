import Darwin
import Foundation

/// The invoking user's home directory, taken from the password database.
///
/// Not `NSHomeDirectory()`, which returns the container path under sandboxing,
/// and not `$HOME`, which any parent process can set to anything it likes.
/// Every `~` in the catalog is expanded through here, so a rule written as
/// `~/Library/Keychains` protects the real keychain directory and nothing else.
public enum UserHome {

    public static func resolved() -> URL {
        if let directory = passwordDatabaseHome() {
            return URL(filePath: directory, directoryHint: .isDirectory)
        }
        // getpwuid failing means the directory service is unreachable. Falling
        // back to NSHomeDirectory is worse than useless for the blocklist — it
        // would anchor every `~` rule at a container path and quietly protect
        // nothing — so this is logged rather than passed off as equivalent.
        LoupeLogReclaim.security.error("getpwuid returned no home directory; falling back to NSHomeDirectory")
        return URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
    }

    private static func passwordDatabaseHome() -> String? {
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        // sysconf can report -1 ("no limit"); 4 KiB is the documented starting
        // point and getpwuid_r tells us if it needs more.
        var capacity = sysconf(_SC_GETPW_R_SIZE_MAX)
        if capacity <= 0 { capacity = 4096 }
        var buffer = [CChar](repeating: 0, count: Int(capacity))

        while true {
            let code = getpwuid_r(getuid(), &entry, &buffer, buffer.count, &result)
            if code == ERANGE, buffer.count < 1 << 20 {
                buffer = [CChar](repeating: 0, count: buffer.count * 2)
                continue
            }
            guard code == 0, let record = result, let directory = record.pointee.pw_dir else {
                return nil
            }
            let path = String(cString: directory)
            return path.isEmpty ? nil : path
        }
    }
}
