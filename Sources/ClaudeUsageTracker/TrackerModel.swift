import AppKit
import Foundation
import UsageCore
import UserNotifications

/// Polls the session logs in the background and publishes snapshots to the UI.
@MainActor
final class TrackerModel: ObservableObject {
    @Published private(set) var sessions: [SessionSummary] = []
    @Published private(set) var lastRefresh: Date?
    @Published var showIdle = false

    @Published var notifyOnNeedsReply: Bool {
        didSet {
            UserDefaults.standard.set(notifyOnNeedsReply, forKey: "notifyOnNeedsReply")
            if notifyOnNeedsReply { requestNotificationPermission() }
        }
    }

    private let store = UsageStore()
    private let queue = DispatchQueue(label: "ClaudeUsageTracker.store")
    private var timer: Timer?
    private var isRefreshing = false
    private var previousStates: [String: SessionState] = [:]

    init() {
        notifyOnNeedsReply = UserDefaults.standard.object(forKey: "notifyOnNeedsReply") as? Bool ?? true
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        if notifyOnNeedsReply { requestNotificationPermission() }
    }

    var visibleSessions: [SessionSummary] {
        showIdle ? sessions : sessions.filter { $0.state != .idle }
    }

    var activeSessions: [SessionSummary] {
        sessions.filter { $0.state != .idle }
    }

    var needsAttentionCount: Int {
        sessions.filter { $0.state == .needsReply || $0.state == .waitingOnTool }.count
    }

    var tokensToday: TokenCounts {
        sessions.tokens(since: Calendar.current.startOfDay(for: Date()))
    }

    /// Sum of the latest speed of every session that is generating right now.
    var liveTokensPerSecond: Double? {
        let rates = sessions.filter { $0.state == .working }.compactMap(\.recentTokensPerSecond)
        return rates.isEmpty ? nil : rates.reduce(0, +)
    }

    func session(id: String?) -> SessionSummary? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let store = self.store
        queue.async {
            let snapshot = store.refresh(now: Date())
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isRefreshing = false
                self.notifyTransitions(snapshot)
                self.sessions = snapshot
                self.lastRefresh = Date()
            }
        }
    }

    // MARK: Notifications

    /// Notifications need a bundled app; running the bare binary (`swift run`) has no bundle id.
    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    private func requestNotificationPermission() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyTransitions(_ snapshot: [SessionSummary]) {
        defer { previousStates = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0.state) }) }
        // Don't notify for everything already waiting when the app starts.
        guard notifyOnNeedsReply, canNotify, !previousStates.isEmpty else { return }

        for session in snapshot {
            let previous = previousStates[session.id]
            guard previous != session.state,
                  session.state == .needsReply || session.state == .waitingOnTool else { continue }
            let content = UNMutableNotificationContent()
            content.title = session.state == .needsReply ? "Claude is waiting for you" : "Claude may need permission"
            content.subtitle = session.projectName
            content.body = session.title
            content.userInfo = ["sessionId": session.id]
            let request = UNNotificationRequest(identifier: "\(session.id)-\(session.state.rawValue)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }
}
