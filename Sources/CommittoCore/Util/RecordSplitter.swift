import Foundation

/// Splits a byte stream into records on a separator byte (newline, NUL, RS ...).
/// Memory is bounded: a record longer than `maxRecord` is cut at the limit and flagged, the rest of it is dropped.
final class RecordSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var truncated = false
    private let separator: UInt8
    private let maxRecord: Int
    private let emit: @Sendable (Data, Bool) -> Void

    init(separator: UInt8 = 0x0A, maxRecord: Int = 1 << 20, _ emit: @escaping @Sendable (Data, Bool) -> Void) {
        self.separator = separator; self.maxRecord = maxRecord; self.emit = emit
    }

    func feed(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        var start = d.startIndex
        while let i = d[start...].firstIndex(of: separator) {
            add(d[start..<i]); flush(); start = d.index(after: i)
        }
        add(d[start...])
    }

    /// Emits a final record that has no trailing separator.
    func finish() {
        lock.lock(); defer { lock.unlock() }
        if !pending.isEmpty || truncated { flush() }
    }

    private func add(_ piece: Data) {
        if truncated { return }
        if pending.count + piece.count > maxRecord { pending.append(piece.prefix(maxRecord - pending.count)); truncated = true }
        else { pending.append(piece) }
    }
    private func flush() {
        emit(pending, truncated)
        pending = Data(); truncated = false
    }
}
