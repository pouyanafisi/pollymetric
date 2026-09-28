import HarnessKit
import XCTest

final class ChildProcessTests: XCTestCase {
    private func run(_ script: String, disclaim: Bool = true, cwd: String? = nil) throws -> (status: Int32, output: String) {
        let out = Pipe()
        let child = ChildProcess(executable: "/bin/sh", arguments: ["-c", script], environment: ["GREETING": "hi"], disclaim: disclaim)
        child.currentDirectory = cwd
        child.standardOutput = out
        try child.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        XCTAssertFalse(child.isRunning)
        return (child.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func testDisclaimedChildRunsWithItsEnvironmentAndFolder() throws {
        XCTAssertTrue(ChildProcess.canDisclaim)
        let result = try run("printf '%s %s' \"$GREETING\" \"$(pwd)\"; read x; printf ' [%s]' \"$x\"", cwd: "/tmp")
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "hi /private/tmp []") // stdin is /dev/null
    }

    func testExitCodeAndSignalAreReportedLikeProcess() throws {
        XCTAssertEqual(try run("exit 3", disclaim: false).status, 3)
        XCTAssertEqual(try run("kill -TERM $$").status, SIGTERM)
    }

    func testTerminationHandlerFiresOnceAndOnlyStdioIsInherited() throws {
        let fired = expectation(description: "terminated")
        let out = Pipe()
        // An fd the child mustn't see: CLOEXEC_DEFAULT closes everything but 0, 1, 2.
        let secret = open("/dev/null", O_RDONLY)
        defer { close(secret) }
        let child = ChildProcess(executable: "/bin/sh", arguments: ["-c", "[ -e /dev/fd/\(secret) ] && echo leaked || echo closed"],
                                 environment: [:], disclaim: true)
        child.standardOutput = out
        child.terminationHandler = { _ in fired.fulfill() }
        try child.run()
        XCTAssertEqual(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "closed\n")
        wait(for: [fired], timeout: 5)
    }
}
