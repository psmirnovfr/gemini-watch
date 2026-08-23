import SwiftUI
import UserNotifications

@main
struct gemini_watchApp: App {
    @StateObject private var settingsStore = AppSettingsStore()
    @StateObject private var speaker = Speaker.shared

    var body: some Scene {
        WindowGroup {
            ConversationListView()
                .environmentObject(settingsStore)
                .environmentObject(speaker)
        }
    }
}

enum NotificationPermission {
    /// Deliberately *not* requested at launch. An Action-button press can be a
    /// user's first ever launch, and a permission alert there would land in the
    /// middle of the one flow that must cost zero taps. `ConversationListView`
    /// asks instead, and only when no Quick Ask is on screen.
    static func requestIfIdle() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
