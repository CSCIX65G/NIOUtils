import XCTest
import NIO
@testable import NIOUtils

extension String: Identifiable {
    public var id: String { self }
}

extension RangeReplaceableCollection where Self: StringProtocol {
    func paddingToLeft(upTo length: Int, using element: Element = " ") -> SubSequence {
        return repeatElement(element, count: Swift.max(0, length-count)) + suffix(Swift.max(count, count-length))
    }
}

final class NIOPublisherTests: XCTestCase {
    var _numCompleted = 0
    var _numQueued = 0
    var _numInProgress = 0
    var numQueued: String { string(for: _numQueued) }
    var numInProgress: String { string(for: _numInProgress) }
    var numCompleted: String { string(for: _numCompleted) }

    static var allTests = [
        ("testPublisher", testPublisher),
    ]

    fileprivate var stats: String {
        "Queued: \(numQueued), InProgress: \(numInProgress), Completed: \(numCompleted)"
    }

    fileprivate func padded(_ value: String) -> String {
        String(value.paddingToLeft(upTo: 3, using: " "))
    }

    fileprivate func string(for value: Int) -> String {
        String(format: "%3d", value)
    }

    fileprivate func checkBaseCounts(_ stage: NIOPublisher<String, Int>.Output) {
        switch stage {
            case let .queued(id, count):
                _numQueued += 1
                XCTAssertEqual(count, _numQueued, "Bad queue accounting")
                return count <= 20
                    ? print("    Queued ID: \(padded(id)), \(stats)")
                    : XCTFail("Queue count exceeded: \(count)")
            case let .started(id, count):
                _numQueued -= 1
                _numInProgress += 1
                XCTAssertEqual(count, _numInProgress, "Bad in progress accounting")
                return count <= 8
                    ? print("Progressed ID: \(padded(id)), \(stats)")
                    : XCTFail("In progress count exceeded: \(count)")
            case let .completed(id, count, _):
                _numInProgress -= 1
                _numCompleted += 1
                XCTAssertEqual(count, _numCompleted, "Bad completion accounting")
                return count <= 40
                    ? print(" Completed ID: \(padded(id)), \(stats)")
                    : XCTFail("Completed count exceeded: \(count)")
        }
    }

    func scheduleRandomWork<T>(_ value: T) -> NIOPublisher<String, T>.Queueable {
        NIOPublisher.Queueable(id: "\(value)") {
            $0.scheduleTask(in: .milliseconds(.random(in: 250 ... 750))) { value }
            .futureResult
        }
    }

    func testPublisher() {
        let expectation = XCTestExpectation(description: "expectation")
        let numToDo = 40
        _numCompleted = 0

        let publisher = NIOPublisher((0 ..< numToDo).map(scheduleRandomWork).publisher)
        let cancellable = publisher.sink { _ in
            self._numCompleted == numToDo ? expectation.fulfill() : XCTFail("Something got lost!")
        } receiveValue: { (stage) in
            self.checkBaseCounts(stage)
        }

        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 30.0), .completed, "Timed out")
        cancellable.cancel()
        print("completed!")
    }

    func testArray() {
        let expectation = XCTestExpectation(description: "expectation")
        let numToDo = 20
        _numCompleted = 0

        let publisher = NIOPublisher((0 ..< numToDo).map(scheduleRandomWork))
        let cancellable = publisher.sink { _ in
            self._numCompleted == numToDo ? expectation.fulfill() : XCTFail("Something got lost!")
        } receiveValue: { (stage) in
            self.checkBaseCounts(stage)
        }

        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 20.0), .completed, "Timed out")
        cancellable.cancel()
        print("completed!")
    }
}
