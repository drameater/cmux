import CmuxCore
import Testing
import XCTest
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class WorkspaceRemoteBadgeTruthTests: XCTestCase {
    @MainActor
    func testPersistentPTYDaemonTransportErrorPropagatesAsError() {
        let workspace = Workspace()
        let config = remoteConfiguration(preserveAfterTerminalExit: true)
        workspace.configureRemoteConnection(config, autoConnect: false)

        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 1)

        let proxyError = "Remote proxy to host unavailable: Remote daemon transport failed: daemon transport keepalive timed out"
        workspace.applyRemoteConnectionStateUpdate(.error, detail: proxyError, target: "host")

        XCTAssertEqual(workspace.remoteConnectionState, .error)
        XCTAssertEqual(workspace.remoteConnectionDetail, proxyError)
        XCTAssertEqual(workspace.remoteStatusPayload()["connected"] as? Bool, false)
    }

    @MainActor
    func testLegacySSHProxyOnlyErrorStillPreservesConnectedState() {
        let workspace = Workspace()
        let config = remoteConfiguration(preserveAfterTerminalExit: false)
        workspace.configureRemoteConnection(config, autoConnect: false)

        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 1)

        let proxyError = "Remote proxy to host unavailable: Remote daemon transport failed: daemon transport keepalive timed out"
        workspace.applyRemoteConnectionStateUpdate(.error, detail: proxyError, target: "host")

        XCTAssertEqual(workspace.remoteConnectionState, .connected)
        XCTAssertEqual(workspace.remoteConnectionDetail, proxyError)
        XCTAssertEqual(workspace.remoteStatusPayload()["connected"] as? Bool, true)
    }

    @MainActor
    func testLegacySSHProxyOnlyErrorDowngradesAfterLastTerminalSessionEnds() throws {
        let workspace = Workspace()
        let config = remoteConfiguration(preserveAfterTerminalExit: false)
        workspace.configureRemoteConnection(config, autoConnect: false)

        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 1)

        try endSeededLegacyTerminalSession(in: workspace)

        let proxyError = "Remote proxy to host unavailable: Remote daemon transport failed: daemon transport keepalive timed out"
        workspace.applyRemoteConnectionStateUpdate(.error, detail: proxyError, target: "host")

        XCTAssertEqual(workspace.remoteConnectionState, .error)
        XCTAssertEqual(workspace.remoteStatusPayload()["connected"] as? Bool, false)
    }

    @MainActor
    func testProxyOnlyRetryDoesNotPinConnectedWithoutLiveTerminalSessions() throws {
        let workspace = Workspace()
        let config = remoteConfiguration(preserveAfterTerminalExit: false)
        workspace.configureRemoteConnection(config, autoConnect: false)

        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 1)

        try endSeededLegacyTerminalSession(in: workspace)

        let proxyError = "Remote proxy to host unavailable: Remote daemon transport failed: daemon transport keepalive timed out"
        workspace.applyRemoteConnectionStateUpdate(.error, detail: proxyError, target: "host")
        workspace.applyRemoteConnectionStateUpdate(.reconnecting, detail: "Reconnecting to host (retry 1)", target: "host")

        XCTAssertEqual(workspace.remoteConnectionState, .reconnecting)
    }

    private func remoteConfiguration(preserveAfterTerminalExit: Bool) -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "host",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64007,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh-pty-attach",
            preserveAfterTerminalExit: preserveAfterTerminalExit
        )
    }

    @MainActor
    private func endSeededLegacyTerminalSession(in workspace: Workspace) throws {
        let surfaceId = try seededTerminalSurfaceID(in: workspace)
        workspace.markRemoteTerminalSessionEnded(surfaceId: surfaceId, relayPort: 64007)

        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 0)
        XCTAssertEqual(workspace.remoteConnectionState, .disconnected)
    }

    @MainActor
    private func seededTerminalSurfaceID(in workspace: Workspace) throws -> UUID {
        let terminalSurfaceIds = workspace.panels.compactMap { panelId, panel in
            panel is TerminalPanel ? panelId : nil
        }
        XCTAssertEqual(terminalSurfaceIds.count, 1)
        return try XCTUnwrap(terminalSurfaceIds.first)
    }
}

@Suite(.serialized)
@MainActor
struct WorkspaceRecoveredTransportArtifactsTests {
    @Test
    func successfulRecoveryClearsOnlyRemoteTransportErrorArtifacts() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let notificationStore = TerminalNotificationStore.shared
        let originalNotificationStore = appDelegate.notificationStore
        let originalNotifications = notificationStore.notifications
        let originalCooldownDates = notificationStore.lastNotificationDateByCooldownKey
        notificationStore.replaceNotificationsForTesting([])
        notificationStore.lastNotificationDateByCooldownKey.removeAll()
        notificationStore.configureNotificationDeliveryHandlerForTesting { _, _ in }
        notificationStore.configureSuppressedNotificationFeedbackHandlerForTesting { _, _ in }
        appDelegate.notificationStore = notificationStore
        defer {
            notificationStore.replaceNotificationsForTesting(originalNotifications)
            notificationStore.lastNotificationDateByCooldownKey = originalCooldownDates
            notificationStore.resetNotificationDeliveryHandlerForTesting()
            notificationStore.resetSuppressedNotificationFeedbackHandlerForTesting()
            appDelegate.notificationStore = originalNotificationStore
        }

        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "host",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64007,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh-pty-attach",
            preserveAfterTerminalExit: true
        )
        workspace.configureRemoteConnection(config, autoConnect: false)

        let unrelatedNotificationBody = "Build completed"
        notificationStore.addNotification(
            tabId: workspace.id,
            surfaceId: UUID(),
            title: "Build",
            subtitle: "",
            body: unrelatedNotificationBody,
            resolvedHooks: []
        )

        let proxyError = "Remote proxy to host unavailable: Remote daemon transport failed: daemon transport keepalive timed out"
        let daemonError = "Remote daemon transport needs re-bootstrap after proxy failure (retry 1 in 2s)"
        workspace.applyRemoteConnectionStateUpdate(.error, detail: proxyError, target: "host")
        workspace.applyRemoteDaemonStatusUpdate(
            WorkspaceRemoteDaemonStatus(state: .error, detail: daemonError),
            target: "host"
        )
        workspace.logEntries.append(
            SidebarLogEntry(
                message: "Compilation failed",
                level: .error,
                source: "build",
                timestamp: Date()
            )
        )
        #expect(notificationStore.sidebarUnread.latestNotificationText(forWorkspaceId: workspace.id) == proxyError)

        workspace.applyRemoteDaemonStatusUpdate(
            WorkspaceRemoteDaemonStatus(state: .ready, detail: "Remote daemon ready"),
            target: "host"
        )
        workspace.applyRemoteConnectionStateUpdate(.connected, detail: "Connected to host", target: "host")

        #expect(workspace.statusEntries["remote.error"] == nil)
        #expect(!workspace.logEntries.contains(where: { $0.source == "remote-proxy" }))
        #expect(!workspace.logEntries.contains(where: { $0.source == "remote-daemon" }))
        #expect(workspace.logEntries.contains(where: { $0.source == "build" }))
        #expect(notificationStore.sidebarUnread.latestNotificationText(forWorkspaceId: workspace.id) == unrelatedNotificationBody)
        #expect(notificationStore.notifications(forTabId: workspace.id, surfaceId: nil).isEmpty)
        #expect(notificationStore.notifications.contains(where: { $0.body == unrelatedNotificationBody }))
    }
}
