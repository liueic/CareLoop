import SwiftData
import SwiftUI

struct RootTabView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    @Query private var profiles: [UserProfile]
    @State private var selectedTab = 0

    var body: some View {
        Group {
            if profiles.first?.onboardingCompleted == true {
                TabView(selection: $selectedTab) {
                    JournalHomeView(selectedTab: $selectedTab)
                        .tabItem { Label("手帐", systemImage: "book.closed") }
                        .tag(0)
                    TodayView()
                        .tabItem { Label("今日", systemImage: "sun.max") }
                        .tag(1)
                    MedicationHomeView()
                        .tabItem { Label("用药", systemImage: "pills") }
                        .tag(2)
                    SettingsHomeView()
                        .tabItem { Label("我的", systemImage: "person") }
                        .tag(3)
                }
            } else {
                OnboardingFlowView()
            }
        }
        .task {
            await appEnvironment.refreshTodayPipeline()
            let profile = appEnvironment.profile()
            NotificationService.scheduleDailyJournalReminder(hour: profile.reminderHour, minute: profile.reminderMinute)
        }
    }
}
