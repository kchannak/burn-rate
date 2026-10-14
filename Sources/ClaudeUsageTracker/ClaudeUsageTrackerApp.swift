import AppKit
import SwiftUI
import UsageCore

@main
struct ClaudeUsageTrackerApp: App {
    @StateObject private var model = TrackerModel()

    init() {
        // Running the bare binary (`swift run`) starts as a background process; make it a
        // regular app so the window and menu bar item show up.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("Claude Usage", id: "sessions") {
            SessionsWindow()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 500)
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var model: TrackerModel

    var body: some View {
        let attention = model.needsAttentionCount
        if let rate = model.liveTokensPerSecond {
            Label("\(Int(rate)) tok/s", systemImage: "bolt.fill")
        } else if attention > 0 {
            Label("\(attention)", systemImage: "bubble.left.fill")
        } else {
            Label(TokenFormat.short(model.tokensToday.total), systemImage: "gauge.with.dots.needle.33percent")
        }
    }
}
