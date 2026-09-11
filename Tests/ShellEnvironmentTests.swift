import Foundation
import Testing
@testable import XcodeSwitcher

/// New tests use Swift Testing. XCTest stays in place for the existing suite,
/// which the migration guidance explicitly allows to coexist.
@Suite("Zsh 项目环境 Hook")
struct ShellEnvironmentTests {
    /// Runs the generated hook in a real `zsh -f` with a stubbed `xcodeswitcher`
    /// on PATH, so the assertions cover behaviour rather than source text.
    private func runHook(_ script: String, fixture: URL) -> ProcessResult {
        ProcessRunner.run(
            executable: "/bin/zsh",
            arguments: ["-f", "-c", script],
            currentDirectory: fixture,
            timeout: 30
        )
    }

    private func makeFixture() throws -> (root: URL, counter: URL, bin: URL, hook: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("XcodeSwitcherHook-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let counter = root.appendingPathComponent("count")
        let stub = bin.appendingPathComponent("xcodeswitcher")
        try """
        #!/bin/zsh
        printf 'x' >> "\(counter.path)"
        printf 'unset DEVELOPER_DIR\\n'
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let hook = root.appendingPathComponent("hook.zsh")
        try ZshProjectEnvironmentHook.source.write(to: hook, atomically: true, encoding: .utf8)
        return (root, counter, bin, hook)
    }

    @Test("目录未变化时不再解析，且不注册到 precmd")
    func resolvesOncePerDirectoryChange() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let script = """
        PATH="\(fixture.bin.path):$PATH"
        source "\(fixture.hook.path)"
        __xcodeswitcher_update_developer_dir
        __xcodeswitcher_update_developer_dir
        print -r -- "precmd=${(j:,:)precmd_functions}"
        print -r -- "chpwd=${(j:,:)chpwd_functions}"
        """

        let result = runHook(script, fixture: fixture.root)

        #expect(result.succeeded)
        // Sourcing the hook resolves once; the two extra calls are the same
        // directory and must not spawn the CLI again.
        let invocations = try String(contentsOf: fixture.counter, encoding: .utf8).count
        #expect(invocations == 1)
        #expect(result.stdout.contains("precmd="))
        #expect(!result.stdout.contains("precmd=__xcodeswitcher_update_developer_dir"))
        #expect(result.stdout.contains("chpwd=__xcodeswitcher_update_developer_dir"))
    }

    @Test("切换目录后重新解析")
    func resolvesAgainAfterDirectoryChange() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let other = fixture.root.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

        let script = """
        PATH="\(fixture.bin.path):$PATH"
        source "\(fixture.hook.path)"
        cd "\(other.path)"
        __xcodeswitcher_update_developer_dir
        """

        let result = runHook(script, fixture: fixture.root)

        #expect(result.succeeded)
        let invocations = try String(contentsOf: fixture.counter, encoding: .utf8).count
        #expect(invocations >= 2)
    }
}
