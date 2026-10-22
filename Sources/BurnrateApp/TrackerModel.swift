import AppKit
import Foundation
import UsageCore
import UserNotifications

/// Polls the session logs in the background and publishes snapshots to the UI.
@MainActor
final class TrackerModel: ObservableObject {
    /// Sessions from every agent.
    @Published private(set) var allSessions: [SessionSummary] = []

    /// "all", or an `Agent` raw value to show one agent only.
    @Published var agentFilter: String {
        didSet { UserDefaults.standard.set(agentFilter, forKey: "agentFilter") }
    }

    /// Sessions after the agent filter; everything in the panel is computed from these.
    var sessions: [SessionSummary] {
        agentFilter == "all" ? allSessions : allSessions.filter { $0.agent.rawValue == agentFilter }
    }

    /// Agents that have at least one session, in a stable order.
    var agentsSeen: [Agent] {
        Agent.allCases.filter { agent in allSessions.contains { $0.agent == agent } }
    }
    @Published private(set) var lastRefresh: Date?
    @Published var showIdle = false

    /// Seconds between reads of the session logs.
    @Published var refreshInterval: TimeInterval {
        didSet {
            UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval")
            startTimer()
        }
    }

    @Published var notifyOnNeedsReply: Bool {
        didSet {
            UserDefaults.standard.set(notifyOnNeedsReply, forKey: "notifyOnNeedsReply")
            if notifyOnNeedsReply { requestNotificationPermission() }
        }
    }

    private let store = AllSources()
    private let queue = DispatchQueue(label: "Burnrate.store")
    private var timer: Timer?
    private var isRefreshing = false
    private var previousStates: [String: SessionState] = [:]

    init() {
        notifyOnNeedsReply = UserDefaults.standard.object(forKey: "notifyOnNeedsReply") as? Bool ?? true
        agentFilter = UserDefaults.standard.string(forKey: "agentFilter") ?? "all"
        refreshInterval = UserDefaults.standard.object(forKey: "refreshInterval") as? TimeInterval ?? 30
        refresh()
        startTimer()
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

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(refreshInterval, 1), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
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
                self.allSessions = snapshot
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
            content.title = session.state == .needsReply
                ? "\(session.agent.label) is waiting for you" : "\(session.agent.label) may need permission"
            content.subtitle = session.projectName
            content.body = session.title
            content.userInfo = ["sessionId": session.id]
            let request = UNNotificationRequest(identifier: "\(session.id)-\(session.state.rawValue)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }
}
