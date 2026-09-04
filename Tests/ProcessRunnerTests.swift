import XCTest
@testable import XcodeSwitcher

final class ProcessRunnerTests: XCTestCase {
    func testCapturesOutputAndStreamsProgress() {
        let progress = TextBox()

        let result = ProcessRunner.run(
            executable: "/bin/echo",
            arguments: ["hello"],
            timeout: 2
        ) { chunk in
            progress.append(chunk)
        }

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout, "hello")
        XCTAssertTrue(progress.value.contains("hello"))
    }

    func testTimeoutTerminatesProcess() {
        let startedAt = Date()
        let result = ProcessRunner.run(
            executable: "/bin/sleep",
            arguments: ["5"],
            timeout: 0.1
        )

        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    }

    func testCancellationTerminatesProcess() async {
        let task = Task.detached {
            ProcessRunner.run(
                executable: "/bin/sleep",
                arguments: ["5"],
                timeout: 10
            )
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        let result = await task.value

        XCTAssertTrue(result.cancelled)
        XCTAssertFalse(result.succeeded)
    }
}

private final class TextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    var value: String { lock.withLock { text } }

    func append(_ value: String) {
        lock.withLock { text += value }
    }
}
