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

    /// A surviving grandchild keeps the inherited pipe open long after the direct
    /// child exits. Reading to EOF would block the caller until that grandchild
    /// dies, so the runner must stop once the child is gone and its output has
    /// drained.
    func testDoesNotWaitForSurvivingGrandchildHoldingThePipe() {
        let startedAt = Date()
        let result = ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "echo done; sleep 5 & exit 0"],
            timeout: 30
        )

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout, "done")
    }

    func testSeparatesStandardOutputAndStandardError() {
        let result = ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "echo out; echo err >&2"],
            timeout: 5
        )

        XCTAssertEqual(result.stdout, "out")
        XCTAssertEqual(result.stderr, "err")
    }

    func testCapturesLargeOutputWithoutTruncation() {
        let result = ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "i=0; while [ $i -lt 4000 ]; do echo 0123456789012345678901234567890123456789; i=$((i+1)); done"],
            timeout: 30
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout.split(separator: "\n").count, 4000)
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
