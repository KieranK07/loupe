import OSLog

/// Loupe is 100% local and logs nothing off the machine. These categories exist
/// so a curious user can inspect exactly what the app did, via Console.app.
public enum LoupeLog {
    public static let subsystem = "com.loupe.app"
    public static let scan = Logger(subsystem: subsystem, category: "scan")
    public static let tree = Logger(subsystem: subsystem, category: "tree")
    public static let ui = Logger(subsystem: subsystem, category: "ui")
    public static let reclaim = Logger(subsystem: subsystem, category: "reclaim")
    public static let security = Logger(subsystem: subsystem, category: "security")
    public static let helper = Logger(subsystem: subsystem, category: "helper")
}
