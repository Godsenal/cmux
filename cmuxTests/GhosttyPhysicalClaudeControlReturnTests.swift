import AppKit
import Carbon.HIToolbox
import CmuxTerminal
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

#if DEBUG
// Ghostty may invoke manual input off-main; the lock guards every access to `inputs`.
private final class GhosttyManualInputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var inputs: [TerminalManualInput] = []

    func record(_ input: TerminalManualInput) {
        lock.lock()
        inputs.append(input)
        lock.unlock()
    }

    func containsNamedKey(_ name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return inputs.contains { input in
            guard case .namedKey(let observedName) = input else { return false }
            return observedName == name
        }
    }
}

@MainActor
@Suite("Ghostty physical Claude control-Return", .serialized)
struct GhosttyPhysicalClaudeControlReturnTests {
    private struct HostedTerminal {
        let surface: TerminalSurface
        let surfaceView: GhosttyNSView
        let window: NSWindow
    }

    @Test
    func physicalControlReturnCreatesRecoverablePromptBoundary() throws {
        let inputCapture = GhosttyManualInputCapture()
        let terminal = try makeHostedTerminal(inputCapture: inputCapture)
        defer {
            terminal.surface.releaseSurfaceForTesting()
            terminal.window.orderOut(nil)
        }
        try #require(
            waitUntil { terminal.surface.hasLiveSurface },
            "Physical-input verification requires a live Ghostty surface"
        )

        terminal.surface.synchronizePromptInputAgentScope(
            "agentPIDKey:claude.physical-control-return",
            controlReturnIsPromptSubmissionBoundary: true
        )
        terminal.surface.recordHumanPromptInput(.unknown)

        let previousKeyObserver =
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        let previousTextInputHandler = GhosttyNSView.debugTextInputEventHandler
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver =
                previousKeyObserver
            GhosttyNSView.debugTextInputEventHandler =
                previousTextInputHandler
        }
        var observedControlReturn = false
        var fellThroughToTextInput = false
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyObserver?(keyEvent)
            guard keyEvent.action == GHOSTTY_ACTION_PRESS,
                  keyEvent.keycode == UInt32(kVK_Return),
                  keyEvent.mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 else {
                return
            }
            observedControlReturn = true
        }
        GhosttyNSView.debugTextInputEventHandler = { _, _ in
            fellThroughToTextInput = true
            return true
        }

        let event = try makeControlReturnEvent(in: terminal.window)
        terminal.surfaceView.keyDown(with: event)

        try #require(
            waitUntil { inputCapture.containsNamedKey("ctrl+enter") },
            "The manual-input transport must receive the physical Ctrl+Return key"
        )
        #expect(
            observedControlReturn,
            "The physical event must reach Ghostty's control-key send path"
        )
        #expect(
            !fellThroughToTextInput,
            "The manual Ctrl+Return key must be handled before text interpretation"
        )
        #expect(
            terminal.surface.confirmPromptSubmission(message: "human prompt")
                == .human
        )
        #expect(!terminal.surface.hasUnconfirmedHumanPromptInput)
        #expect(
            terminal.surface.sendPromptSubmission(
                "automation after the human boundary",
                submitKey: "return",
                rejectIfHumanComposerBusy: true,
                hookRecordingSource: "workspace.agent_submit"
            ) == .sent,
            "The confirmed physical boundary must not leave the composer busy"
        )
    }

    private func makeHostedTerminal(
        inputCapture: GhosttyManualInputCapture
    ) throws -> HostedTerminal {
        _ = NSApplication.shared
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil,
            ioMode: .manualMirror,
            manualInputHandler: { inputCapture.record($0) },
            manualInputKeyNameResolver: { keyEvent in
                guard keyEvent.keycode == UInt32(kVK_Return),
                      keyEvent.mods.rawValue
                        & GHOSTTY_MODS_CTRL.rawValue != 0 else {
                    return nil
                }
                return "ctrl+enter"
            }
        )
        let hostedView = surface.hostedView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let contentView = try #require(window.contentView)
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.layoutSubtreeIfNeeded()
        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)

        return HostedTerminal(
            surface: surface,
            surfaceView: try #require(findSurfaceView(in: hostedView)),
            window: window
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition(),
              ProcessInfo.processInfo.systemUptime < deadline {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            _ = RunLoop.current.run(
                mode: .default,
                before: Date().addingTimeInterval(min(0.01, remaining))
            )
        }
        return condition()
    }

    private func findSurfaceView(in view: NSView) -> GhosttyNSView? {
        if let surfaceView = view as? GhosttyNSView {
            return surfaceView
        }
        for subview in view.subviews {
            if let surfaceView = findSurfaceView(in: subview) {
                return surfaceView
            }
        }
        return nil
    }

    private func makeControlReturnEvent(in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: UInt16(kVK_Return)
        ))
    }
}
#endif
