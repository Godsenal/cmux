import Foundation

extension CMUXCLI {
    private static let legacyClaudeBlockingAttentionRequestId = "legacy-session-blocker"

    func claudeBlockingAttentionRequestId(
        toolUseId: String?
    ) -> String {
        nonEmptyClaudeHookIdentifier(toolUseId)
            ?? Self.legacyClaudeBlockingAttentionRequestId
    }

    func beginClaudeBlockingAttention(
        client: SocketClient,
        sessionId: String,
        toolUseId: String?,
        workspaceId: String,
        surfaceId: String,
        owner: ClaudeHookSessionRecord?,
        title: String,
        subtitle: String,
        body: String
    ) {
        var params: [String: Any] = [
            "source": "claude",
            "session_id": sessionId,
            "request_id": claudeBlockingAttentionRequestId(toolUseId: toolUseId),
            "workspace_id": workspaceId,
            "surface_id": surfaceId,
            "title": title,
            "subtitle": subtitle,
            "body": body,
        ]
        if !client.isRelayBacked {
            guard let owner,
                  let ownerPID = owner.pid,
                  ownerPID > 0,
                  ownerPID <= Int(Int32.max),
                  let ownerPIDStartSeconds = owner.pidStartSeconds,
                  let ownerPIDStartMicroseconds = owner.pidStartMicroseconds,
                  ownerPIDStartSeconds >= 0,
                  (0..<1_000_000).contains(ownerPIDStartMicroseconds) else {
                return
            }
            params["ppid"] = ownerPID
            params["ppid_start_seconds"] = ownerPIDStartSeconds
            params["ppid_start_microseconds"] = ownerPIDStartMicroseconds
        }
        _ = try? client.sendV2(method: "feed.attention.begin", params: params)
    }

    @discardableResult
    func endClaudeBlockingAttention(
        client: SocketClient,
        sessionId: String,
        toolUseId: String?
    ) -> Bool {
        do {
            _ = try client.sendV2(method: "feed.attention.end", params: [
                "source": "claude",
                "session_id": sessionId,
                "request_id": claudeBlockingAttentionRequestId(toolUseId: toolUseId),
            ])
            return true
        } catch let error as CLIError where error.v2Code == "method_not_found"
                || error.v2Code == "unrecognized_method" {
            // Older app builds never acquired transient attention, so an
            // unsupported release is already reconciled.
            return true
        } catch {
            return false
        }
    }

    /// A turn boundary supersedes any tool callback that never arrived (for
    /// example after native permission denial or interruption). Feed-owned
    /// requests are harmless no-ops here; bypass-mode requests release every
    /// transient request in this session without clearing pane-wide attention.
    func endClaudeBlockingAttentionForTurnBoundary(
        client: SocketClient,
        sessionId: String
    ) {
        // Send a session-scoped release even after an earlier boundary cleared
        // durable blocker IDs. If its first transport attempt failed, the next
        // current turn boundary can still reconcile app-owned attention.
        _ = try? client.sendV2(method: "feed.attention.end", params: [
            "source": "claude",
            "session_id": sessionId,
            "all_requests": true,
        ])
    }
}
