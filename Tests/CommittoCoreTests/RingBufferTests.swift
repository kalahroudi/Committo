import XCTest
@testable import CommittoCore

final class RingBufferTests: XCTestCase {
    func testKeepsOnlyTheNewestAndCountsDropped() {
        var b = RingBuffer<Int>(capacity: 3)
        for i in 1...10 { b.append(i) }
        XCTAssertEqual(Array(b.elements), [8, 9, 10])
        XCTAssertEqual(b.count, 3); XCTAssertEqual(b.dropped, 7); XCTAssertEqual(b.totalAppended, 10); XCTAssertEqual(b.last, 10)
    }
    func testIdsAreStableWhileRetained() {
        var b = RingBuffer<String>(capacity: 2)
        b.append("a"); b.append("b")
        XCTAssertEqual(b.indexed().map(\.id), [0, 1])
        b.append("c")
        XCTAssertEqual(b.indexed().map(\.id), [1, 2])
        XCTAssertEqual(b.indexed().map(\.element), ["b", "c"])
    }
    func testBackingStorageStaysBounded() {
        var b = RingBuffer<Int>(capacity: 100)
        for i in 0..<1_000_000 { b.append(i) }
        XCTAssertEqual(b.count, 100)
        XCTAssertEqual(b.elements.first, 999_900)
        XCTAssertEqual(Mirror(reflecting: b).descendant("storage").map { ($0 as! [Int]).count }!, b.count + (Mirror(reflecting: b).descendant("head") as! Int))
        XCTAssertLessThan((Mirror(reflecting: b).descendant("storage") as! [Int]).count, 2 * 100 + 1)
    }
    func testRemoveAllResets() {
        var b = RingBuffer<Int>(capacity: 2)
        b.append(1); b.append(2); b.append(3)
        b.removeAll()
        XCTAssertTrue(b.isEmpty); XCTAssertEqual(b.dropped, 0); XCTAssertEqual(b.totalAppended, 0)
        b.append(9); XCTAssertEqual(Array(b.elements), [9])
    }
}
