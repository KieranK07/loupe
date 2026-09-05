import Foundation

/// A tagged index into one of the two node arenas.
///
/// Files and directories live in separate arenas because they need different
/// fields, so a reference has to say which arena it points into. The high bit
/// selects the arena; the low 31 bits are the slot.
public struct NodeRef: Hashable, Sendable, Codable {
    public let rawValue: UInt32

    @usableFromInline static let directoryBit: UInt32 = 0x8000_0000
    @usableFromInline static let indexMask: UInt32 = 0x7FFF_FFFF

    /// Sentinel for "no node". Distinct from any real slot because a walk that
    /// produced 2^31-1 directories would have exhausted memory long before.
    public static let invalid = NodeRef(rawValue: .max)

    @inlinable public init(rawValue: UInt32) { self.rawValue = rawValue }

    @inlinable public static func file(_ slot: UInt32) -> NodeRef {
        NodeRef(rawValue: slot & indexMask)
    }

    @inlinable public static func directory(_ slot: UInt32) -> NodeRef {
        NodeRef(rawValue: (slot & indexMask) | directoryBit)
    }

    @inlinable public var isDirectory: Bool { rawValue & Self.directoryBit != 0 }
    @inlinable public var isFile: Bool { !isDirectory && isValid }
    @inlinable public var slot: UInt32 { rawValue & Self.indexMask }
    @inlinable public var isValid: Bool { rawValue != UInt32.max }
}

extension NodeRef: CustomStringConvertible {
    public var description: String {
        guard isValid else { return "NodeRef(invalid)" }
        return isDirectory ? "dir#\(slot)" : "file#\(slot)"
    }
}
