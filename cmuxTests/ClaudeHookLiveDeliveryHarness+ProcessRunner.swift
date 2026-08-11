import Darwin
import Dispatch
import Foundation
import os

extension ClaudeHookLiveDeliveryHarness {
    /// Runs a hook CLI child with authoritative POSIX exit tracking.
    ///
    /// App-hosted tests cannot rely on `Foundation.Process` publishing an exit
    /// promptly while other fixture children remain alive. One `waitpid` owner
    /// makes child completion independent of Foundation notifications.
    static func runHookProcess(
        context: Context,
        arguments: [String],
        environment: [String: String],
        standardInput: String
    ) -> ProcessRunResult {
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let descriptors = [
            stdinPipe.fileHandleForReading.fileDescriptor,
            stdinPipe.fileHandleForWriting.fileDescriptor,
            stdoutPipe.fileHandleForReading.fileDescriptor,
            stdoutPipe.fileHandleForWriting.fileDescriptor,
            stderrPipe.fileHandleForReading.fileDescriptor,
            stderrPipe.fileHandleForWriting.fileDescriptor,
        ]
        guard descriptors.allSatisfy({ $0 > STDERR_FILENO }) else {
            return processLaunchFailure(code: EINVAL, detail: "capture pipe collided with standard I/O")
        }

        var fileActions: posix_spawn_file_actions_t?
        var setupStatus = posix_spawn_file_actions_init(&fileActions)
        guard setupStatus == 0 else {
            return processLaunchFailure(code: setupStatus)
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        setupStatus = posix_spawn_file_actions_adddup2(
            &fileActions,
            stdinPipe.fileHandleForReading.fileDescriptor,
            STDIN_FILENO
        )
        if setupStatus == 0 {
            setupStatus = posix_spawn_file_actions_adddup2(
                &fileActions,
                stdoutPipe.fileHandleForWriting.fileDescriptor,
                STDOUT_FILENO
            )
        }
        if setupStatus == 0 {
            setupStatus = posix_spawn_file_actions_adddup2(
                &fileActions,
                stderrPipe.fileHandleForWriting.fileDescriptor,
                STDERR_FILENO
            )
        }
        for descriptor in descriptors where setupStatus == 0 {
            setupStatus = posix_spawn_file_actions_addclose(&fileActions, descriptor)
        }
        guard setupStatus == 0 else {
            return processLaunchFailure(code: setupStatus)
        }

        var attributes: posix_spawnattr_t?
        setupStatus = posix_spawnattr_init(&attributes)
        guard setupStatus == 0 else {
            return processLaunchFailure(code: setupStatus)
        }
        defer { posix_spawnattr_destroy(&attributes) }
        let spawnFlags = Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP)
        setupStatus = posix_spawnattr_setpgroup(&attributes, 0)
        if setupStatus == 0 {
            setupStatus = posix_spawnattr_setflags(&attributes, spawnFlags)
        }
        guard setupStatus == 0 else {
            return processLaunchFailure(code: setupStatus)
        }

        let argumentStrings = [context.cliPath] + arguments
        let environmentStrings = environment.map { "\($0.key)=\($0.value)" }.sorted()
        guard (argumentStrings + environmentStrings).allSatisfy({ !$0.utf8.contains(0) }) else {
            return processLaunchFailure(code: EINVAL, detail: "argument or environment contains NUL")
        }
        var argumentPointers = argumentStrings.map { strdup($0) }
        var environmentPointers = environmentStrings.map { strdup($0) }
        defer {
            for pointer in argumentPointers where pointer != nil { free(pointer) }
            for pointer in environmentPointers where pointer != nil { free(pointer) }
        }
        guard argumentPointers.allSatisfy({ $0 != nil }),
              environmentPointers.allSatisfy({ $0 != nil }) else {
            return processLaunchFailure(code: ENOMEM)
        }
        argumentPointers.append(nil)
        environmentPointers.append(nil)

        var processIdentifier: pid_t = 0
        let spawnStatus = context.cliPath.withCString { executablePointer in
            argumentPointers.withUnsafeMutableBufferPointer { argumentBuffer in
                environmentPointers.withUnsafeMutableBufferPointer { environmentBuffer in
                    guard let argumentBase = argumentBuffer.baseAddress,
                          let environmentBase = environmentBuffer.baseAddress else {
                        return Int32(EINVAL)
                    }
                    return posix_spawn(
                        &processIdentifier,
                        executablePointer,
                        &fileActions,
                        &attributes,
                        argumentBase,
                        environmentBase
                    )
                }
            }
        }
        guard spawnStatus == 0, processIdentifier > 1 else {
            return processLaunchFailure(code: spawnStatus == 0 ? ECHILD : spawnStatus)
        }

        try? stdinPipe.fileHandleForReading.close()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        let waiter = POSIXProcessWaiter(processIdentifier: processIdentifier)
        stdinPipe.fileHandleForWriting.write(Data(standardInput.utf8))
        try? stdinPipe.fileHandleForWriting.close()

        // SocketClient allows a response up to 15 seconds; the harness must not
        // terminate a best-effort hook before its own bounded operation expires.
        var timedOut = false
        if !waiter.wait(timeout: 20), waiter.outcome == nil {
            timedOut = true
            signalProcessGroup(processIdentifier, signal: SIGTERM)
            if !waiter.wait(timeout: 1) {
                signalProcessGroup(processIdentifier, signal: SIGKILL)
                _ = waiter.wait(timeout: 5)
            }
        }

        guard let outcome = waiter.outcome else {
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            return ProcessRunResult(
                status: SIGKILL,
                stdout: "",
                stderr: "test runner could not reap hook process group after SIGKILL",
                timedOut: true
            )
        }

        let stdout = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let capturedStderr = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let stderr: String
        if let waitError = outcome.waitError {
            let message = "test runner waitpid failed: \(String(cString: strerror(waitError)))"
            stderr = capturedStderr.isEmpty ? message : "\(capturedStderr)\n\(message)"
        } else {
            stderr = capturedStderr
        }
        return ProcessRunResult(
            status: outcome.status,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
    }

    private static func processLaunchFailure(
        code: Int32,
        detail: String? = nil
    ) -> ProcessRunResult {
        ProcessRunResult(
            status: -1,
            stdout: "",
            stderr: detail ?? String(cString: strerror(code)),
            timedOut: false
        )
    }

    private static func signalProcessGroup(_ processIdentifier: pid_t, signal: Int32) {
        if kill(-processIdentifier, signal) != 0 {
            _ = kill(processIdentifier, signal)
        }
    }
}

private struct ClaudeHookPOSIXProcessOutcome: Sendable {
    let status: Int32
    let waitError: Int32?
}

/// Owns the only `waitpid` call for a hook child and publishes one immutable outcome.
///
/// Safety: the dedicated reaper is the only writer, and `outcomeState` protects
/// the single cross-thread publication read by the synchronous test caller.
private final class POSIXProcessWaiter: @unchecked Sendable {
    private let processIdentifier: pid_t
    // One-shot synchronous publication is the lock carve-out; no ongoing state is shared.
    private let outcomeState = OSAllocatedUnfairLock<ClaudeHookPOSIXProcessOutcome?>(
        initialState: nil
    )
    private let finished = DispatchSemaphore(value: 0)

    init(processIdentifier: pid_t) {
        self.processIdentifier = processIdentifier
        let thread = Thread { [self] in reap() }
        thread.name = "cmux-claude-hook-test-process-reaper"
        thread.stackSize = 1 << 20
        thread.start()
    }

    var outcome: ClaudeHookPOSIXProcessOutcome? {
        outcomeState.withLock { $0 }
    }

    func wait(timeout: TimeInterval) -> Bool {
        if outcome != nil { return true }
        if finished.wait(timeout: .now() + timeout) == .success { return true }
        // Do not turn a waitpid completion racing the deadline into a timeout.
        return outcome != nil
    }

    private func reap() {
        var rawStatus: Int32 = 0
        var waitResult: pid_t
        repeat {
            waitResult = waitpid(processIdentifier, &rawStatus, 0)
        } while waitResult == -1 && errno == EINTR

        let outcome: ClaudeHookPOSIXProcessOutcome
        if waitResult == processIdentifier {
            let terminatingSignal = rawStatus & 0x7f
            let status = terminatingSignal == 0
                ? (rawStatus >> 8) & 0xff
                : terminatingSignal
            outcome = ClaudeHookPOSIXProcessOutcome(status: status, waitError: nil)
        } else {
            outcome = ClaudeHookPOSIXProcessOutcome(status: -1, waitError: errno)
        }
        outcomeState.withLock { $0 = outcome }
        finished.signal()
    }
}
