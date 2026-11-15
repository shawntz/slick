import SlickCoreC

/// An error status returned by the Rust core.
///
/// Every function in the C ABI returns an `Int32`: zero or more is success, often a count, and a
/// negative value is one of these errors.
public enum CoreError: Error, Equatable, Sendable {
    /// A required pointer argument was NULL.
    case nullPointer
    /// A string argument was not valid UTF-8.
    case invalidUTF8
    /// Rust panicked. The panic was caught at the boundary and the process keeps running.
    case panic
    /// A lock was poisoned by an earlier panic. The handle must be rebuilt.
    case poisoned
    /// An argument was out of range.
    case invalidArgument
    /// An output buffer was too small.
    case bufferTooSmall
    /// The data directory could not be created, read or written.
    case io
    /// The linked static library implements another ABI version than the header: run `make core`.
    case abiMismatch(expected: UInt32, linked: UInt32)
    /// A status this version of CoreBridge does not know.
    case unknown(Int32)

    /// Returns `status` when it is zero or more, and throws the matching error when it is negative.
    @discardableResult
    static func check(_ status: Int32) throws(CoreError) -> Int32 {
        guard status < 0 else { return status }
        throw CoreError(status: status)
    }

    private init(status: Int32) {
        switch status {
        case SLICK_STATUS_NULL_POINTER.rawValue: self = .nullPointer
        case SLICK_STATUS_INVALID_UTF8.rawValue: self = .invalidUTF8
        case SLICK_STATUS_PANIC.rawValue: self = .panic
        case SLICK_STATUS_POISONED.rawValue: self = .poisoned
        case SLICK_STATUS_INVALID_ARGUMENT.rawValue: self = .invalidArgument
        case SLICK_STATUS_BUFFER_TOO_SMALL.rawValue: self = .bufferTooSmall
        case SLICK_STATUS_IO.rawValue: self = .io
        default: self = .unknown(status)
        }
    }
}
