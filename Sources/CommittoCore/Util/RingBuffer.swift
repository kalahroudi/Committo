import Foundation

/// Fixed-capacity FIFO for log lines and console output: appending past `capacity` drops the oldest element,
/// so a chatty CI run or agent cannot grow memory without bound. Appends are amortised O(1).
public struct RingBuffer<Element> {
    public let capacity: Int
    private var storage: [Element] = []
    private var head = 0
    /// Elements evicted so far. Also the id of the oldest retained element, so ids stay stable as the window slides.
    public private(set) var dropped = 0

    public init(capacity: Int) { precondition(capacity > 0); self.capacity = capacity }

    public var count: Int { storage.count - head }
    public var isEmpty: Bool { count == 0 }
    /// Total elements ever appended (retained + dropped); changes on every append, handy for scroll triggers.
    public var totalAppended: Int { dropped + count }
    /// Retained elements, oldest first.
    public var elements: ArraySlice<Element> { storage[head...] }
    /// Retained elements with ids that never change while the element is retained.
    public func indexed() -> [(id: Int, element: Element)] { elements.enumerated().map { (dropped + $0.offset, $0.element) } }
    public var last: Element? { isEmpty ? nil : storage.last }

    public mutating func append(_ e: Element) {
        storage.append(e)
        if count > capacity { head += 1; dropped += 1 }
        if head >= capacity { storage.removeFirst(head); head = 0 }   // compact once per `capacity` evictions
    }

    public mutating func removeAll() { storage = []; head = 0; dropped = 0 }
}

extension RingBuffer: Sendable where Element: Sendable {}
