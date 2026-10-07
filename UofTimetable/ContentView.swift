//
//  ContentView.swift
//  UofTimetable
//

import ActivityKit
import SwiftData
import SwiftUI
import UIKit

private let appStoreReviewURL = URL(string: "https://apps.apple.com/app/id6801203216?action=write-review")!

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @AppStorage("dismissedUpdateVersion") private var dismissedUpdateVersion = ""
    @AppStorage("dismissedUpdateAt") private var dismissedUpdateAt = 0.0
    @AppStorage("backendSyncStatus") private var backendSyncStatus = "Not synced yet"
    @AppStorage("pushStartSyncStatus") private var pushStartSyncStatus = "Waiting for device registration"
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CourseEvent.startTime) private var courseEvents: [CourseEvent]
    @AppStorage("reminderLeadMinutes") private var reminderLeadMinutes = 30
    @AppStorage("alertCueMinutes") private var alertCueMinutes = 5
    @AppStorage("isLiveActivityPaused") private var isLiveActivityPaused = false
    @AppStorage("hasCompletedProfileSetup") private var hasCompletedProfileSetup = false
    @AppStorage("studentDisplayName") private var studentDisplayName = ""
    @AppStorage("studentCampus") private var studentCampus = ""
    @AppStorage("studentMajor") private var studentMajor = ""
    @AppStorage("studentYear") private var studentYear = ""

    @State private var isAddingCourse = false
    @State private var isImportingImage = false
    @State private var isShowingProfileSetup = false
    @State private var toastMessage: String?
    @State private var toastTask: Task<Void, Never>?
    @State private var islandTask: Task<Void, Never>?
    @State private var selectedHomeSection = HomeSection.today
    @State private var pendingUpdate: AppUpdate?

    var body: some View {
        Group {
            if !hasCompletedProfileSetup || isShowingProfileSetup {
                OnboardingFlowView(
                    displayName: $studentDisplayName,
                    campus: $studentCampus,
                    major: $studentMajor,
                    year: $studentYear
                ) {
                    hasCompletedProfileSetup = true
                    isShowingProfileSetup = false
                }
            } else {
                NavigationStack {
                    ScrollView {
                        VStack(spacing: 12) {
                            selectedSectionContent
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 16)
                        .padding(.bottom, 22)
                    }
                    .background(AppTheme.background.ignoresSafeArea())
                    .toolbar(.hidden, for: .navigationBar)
                    .safeAreaInset(edge: .bottom) {
                        HomeBottomNavigation(selectedSection: $selectedHomeSection)
                            .padding(.horizontal, 18)
                            .padding(.top, 10)
                            .padding(.bottom, 8)
                            .background {
                                LinearGradient(
                                    colors: [
                                        AppTheme.background.opacity(0),
                                        AppTheme.background.opacity(0.92),
                                        AppTheme.background
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                                .ignoresSafeArea()
                            }
                    }
                }
                .overlay(alignment: .top) {
                    if let toastMessage {
                        FloatingStatusToast(message: toastMessage)
                            .padding(.horizontal, 18)
                            .padding(.top, 10)
                            .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.98)))
                            .zIndex(1)
                    }
                }
                .sheet(isPresented: $isAddingCourse) {
                    ManualCourseView(save: { try addCourse($0) })
                }
                .sheet(isPresented: $isImportingImage) {
                    TimetableImageImportView { drafts in
                        try addCourse(drafts, replacingSchedule: true)
                        isImportingImage = false
                    }
                }
            }
        }
        .onAppear {
            clampAlertCueMinutes()
            restartIslandScheduler()
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            syncSchedule()
            await PushToStartTokenManager.shared.retryRegistrations()
            await checkForAppUpdate()
        }
        .alert("Update available", isPresented: Binding(
            get: { pendingUpdate != nil },
            set: { if !$0 { pendingUpdate = nil } }
        ), presenting: pendingUpdate) { update in
            Button("Update") { openURL(update.storeURL) }
            Button("Later", role: .cancel) {
                dismissedUpdateVersion = update.version
                dismissedUpdateAt = Date().timeIntervalSince1970
            }
        } message: { update in
            Text("UTime \(update.version) is on the App Store. Update to get the latest fixes and keep your Live Activities working.")
        }
        .onChange(of: reminderLeadMinutes) { _, newValue in
            reminderLeadMinutes = min(max(newValue, 1), 60)
            clampAlertCueMinutes()
        }
        .onChange(of: alertCueMinutes) { _, newValue in
            alertCueMinutes = min(max(newValue, 1), 60)
            clampAlertCueMinutes()
        }
        .onChange(of: isLiveActivityPaused) { _, _ in
            applyReminderSettings()
        }
    }

    private func checkForAppUpdate() async {
        guard hasCompletedProfileSetup, !isShowingProfileSetup, pendingUpdate == nil,
              let update = await AppUpdateChecker.availableUpdate() else { return }

        let recentlyDismissed = dismissedUpdateVersion == update.version
            && Date().timeIntervalSince1970 - dismissedUpdateAt < 24 * 60 * 60
        guard !recentlyDismissed else { return }

        pendingUpdate = update
    }

    private var upcomingEvents: [CourseEvent] {
        courseEvents.filter { $0.endTime > Date() }
    }

    private var todayEvents: [CourseEvent] {
        upcomingEvents.filter { Calendar.current.isDateInToday($0.startTime) }
    }

    @ViewBuilder
    private var selectedSectionContent: some View {
        switch selectedHomeSection {
        case .today:
            AppHeaderView(
                hasSchedule: !courseEvents.isEmpty,
                profileName: studentDisplayName
            )

            if let nextEvent = upcomingEvents.first {
                NextClassCard(event: nextEvent)
            } else {
                EmptyNextClassCard(
                    importAction: { isAddingCourse = true },
                    imageAction: { isImportingImage = true }
                )
            }

            DaySnapshotCard(
                todayCount: todayEvents.count,
                upcomingCount: upcomingEvents.count,
                leadMinutes: reminderLeadMinutes,
                isPaused: isLiveActivityPaused
            )
        case .schedule:
            ScheduleHeroCard(events: upcomingEvents)

            AddScheduleCard(
                importAction: { isAddingCourse = true },
                imageAction: { isImportingImage = true }
            )

            ScheduleListCard(
                events: upcomingEvents,
                deleteAction: deleteEvent,
                clearAction: clearSchedule
            )
        case .alerts:
            AlertsHeroCard(
                nextEvent: upcomingEvents.first,
                leadMinutes: reminderLeadMinutes,
                alertCueMinutes: alertCueMinutes,
                isPaused: isLiveActivityPaused
            )

            ReminderSettingsCard(
                leadMinutes: $reminderLeadMinutes,
                alertCueMinutes: $alertCueMinutes,
                isPaused: $isLiveActivityPaused
            ) {
                applyReminderSettings()
            }

            AlertStatusCard(
                upcomingCount: upcomingEvents.count,
                leadMinutes: reminderLeadMinutes,
                alertCueMinutes: alertCueMinutes,
                isPaused: isLiveActivityPaused,
                backendStatus: backendSyncStatus,
                deviceStatus: pushStartSyncStatus,
                retryAction: {
                    syncSchedule()
                    Task { await PushToStartTokenManager.shared.retryRegistrations() }
                }
            )
        case .profile:
            ProfileSummaryCard(
                displayName: studentDisplayName,
                campus: studentCampus,
                major: studentMajor,
                year: studentYear,
                importedCount: courseEvents.count,
                editAction: { isShowingProfileSetup = true }
            )
        }
    }

    private func addCourse(_ drafts: [CourseEventDraft], replacingSchedule: Bool = false) throws {
        let existingSnapshots = replacingSchedule ? [] : courseEvents.map(snapshot(from:))
        if replacingSchedule {
            for event in courseEvents {
                modelContext.delete(event)
            }
        }
        for draft in drafts {
            modelContext.insert(
                CourseEvent(
                    uid: draft.uid,
                    courseCode: draft.courseCode,
                    title: draft.title,
                    building: draft.building,
                    roomNumber: draft.roomNumber,
                    location: draft.location,
                    meetingType: draft.meetingType,
                    section: draft.section,
                    deliveryMode: draft.deliveryMode,
                    startTime: draft.startTime,
                    endTime: draft.endTime
                )
            )
        }

        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
        let snapshots = existingSnapshots + drafts.map(CourseReminderSnapshot.init)
        restartIslandScheduler(with: snapshots, endingCurrentActivity: replacingSchedule)
        syncSchedule(with: snapshots)
        selectedHomeSection = .schedule
        showToast(replacingSchedule
            ? "Replaced your schedule with \(drafts.count) classes."
            : "Added \(drafts.count) classes to your schedule.")
    }

    private func clearSchedule() {
        withAnimation {
            for event in courseEvents {
                modelContext.delete(event)
            }
            try? modelContext.save()
        }
        islandTask?.cancel()
        Task {
            await ClassLiveActivityManager.shared.end(dismissalPolicy: .immediate)
            await LiveActivityPushRegistrationClient.shared.syncSchedule(
                events: [],
                liveActivityLeadMinutes: reminderLeadMinutes,
                alertCueMinutes: alertCueMinutes
            )
        }
        showToast("Schedule cleared.")
    }

    private func deleteEvent(_ event: CourseEvent) {
        let deletedCourseCode = event.courseCode
        let remainingEvents = courseEvents.filter { $0 !== event }
        let remainingSnapshots = remainingEvents.map(snapshot(from:))

        withAnimation {
            modelContext.delete(event)
            try? modelContext.save()
        }

        islandTask?.cancel()
        Task {
            await ClassLiveActivityManager.shared.end(dismissalPolicy: .immediate)
            await MainActor.run {
                syncSchedule(with: remainingSnapshots)
                restartIslandScheduler(with: remainingSnapshots)
                showToast("Deleted \(deletedCourseCode).")
            }
        }
    }

    private func applyReminderSettings() {
        clampAlertCueMinutes()

        if isLiveActivityPaused {
            pauseLiveActivities()
            showToast("Live Activities paused.")
        } else {
            restartIslandScheduler()
            syncSchedule()
            showToast("Live Activity timing updated.")
        }
    }

    private func restartIslandScheduler() {
        restartIslandScheduler(with: upcomingEvents.map(snapshot(from:)))
    }

    private func restartIslandScheduler(with snapshots: [CourseReminderSnapshot], endingCurrentActivity: Bool = false) {
        islandTask?.cancel()
        guard !isLiveActivityPaused else {
            if endingCurrentActivity {
                Task { await ClassLiveActivityManager.shared.end(dismissalPolicy: .immediate) }
            }
            return
        }

        let leadMinutes = reminderLeadMinutes

        islandTask = Task {
            if endingCurrentActivity {
                await ClassLiveActivityManager.shared.end(dismissalPolicy: .immediate)
            }
            await ClassLiveActivityManager.shared.endIfStartTimePassed()
            await runIslandScheduler(
                events: snapshots,
                leadMinutes: leadMinutes
            )
        }
    }

    private func syncSchedule() {
        syncSchedule(with: upcomingEvents.map(snapshot(from:)))
    }

    private func syncSchedule(with snapshots: [CourseReminderSnapshot]) {
        let leadMinutes = reminderLeadMinutes
        let cueMinutes = alertCueMinutes
        let events = isLiveActivityPaused ? [] : snapshots

        Task {
            await LiveActivityPushRegistrationClient.shared.syncSchedule(
                events: events,
                liveActivityLeadMinutes: leadMinutes,
                alertCueMinutes: cueMinutes
            )
        }
    }

    private func pauseLiveActivities() {
        islandTask?.cancel()
        islandTask = nil

        Task {
            await ClassLiveActivityManager.shared.end(dismissalPolicy: .immediate)
            await LiveActivityPushRegistrationClient.shared.syncSchedule(
                events: [],
                liveActivityLeadMinutes: reminderLeadMinutes,
                alertCueMinutes: alertCueMinutes
            )
        }
    }

    private func runIslandScheduler(
        events: [CourseReminderSnapshot],
        leadMinutes: Int
    ) async {
        let sortedEvents = events.sorted { $0.startTime < $1.startTime }

        for event in sortedEvents {
            guard event.endTime > Date() else { continue }

            let leadSeconds = TimeInterval(min(max(leadMinutes, 1), 60) * 60)
            let islandStartTime = event.startTime.addingTimeInterval(-leadSeconds)
            let delayUntilIsland = max(0, islandStartTime.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(delayUntilIsland * 1_000_000_000))
            guard !Task.isCancelled, Date() < event.endTime else { continue }

            await startLiveActivity(for: event)
            await switchToCompactCountdownIfNeeded(for: event, leadMinutes: leadMinutes)

            let delayUntilEnd = max(0, event.endTime.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(delayUntilEnd * 1_000_000_000))
            guard !Task.isCancelled else { return }

            await ClassLiveActivityManager.shared.end(dismissalPolicy: .immediate)
        }
    }

    private func switchToCompactCountdownIfNeeded(for event: CourseReminderSnapshot, leadMinutes: Int) async {
        guard alertCueMinutes <= leadMinutes else { return }

        let cueStart = event.startTime.addingTimeInterval(TimeInterval(-alertCueMinutes * 60))
        let delayUntilCue = max(0, cueStart.timeIntervalSinceNow)

        try? await Task.sleep(nanoseconds: UInt64(delayUntilCue * 1_000_000_000))
        guard !Task.isCancelled, Date() < event.startTime else { return }

        await updateLiveActivity(
            for: event,
            compactShowsCountdown: true,
            compactCueID: 1,
            compactCueMinutes: alertCueMinutes,
            compactCountdownUntil: event.startTime
        )
    }

    private func startLiveActivity(for event: CourseReminderSnapshot) async {
        do {
            let shouldShowCountdown = Date() >= event.startTime.addingTimeInterval(TimeInterval(-alertCueMinutes * 60))

            try await ClassLiveActivityManager.shared.start(
                courseCode: event.courseCode,
                building: event.building,
                roomNumber: event.roomNumber,
                meetingType: event.meetingType,
                section: event.section,
                deliveryMode: event.deliveryMode,
                startTime: event.startTime,
                endTime: event.endTime,
                compactShowsCountdown: shouldShowCountdown,
                compactCueID: shouldShowCountdown ? 1 : 0,
                compactCueMinutes: alertCueMinutes,
                compactCountdownUntil: shouldShowCountdown ? event.startTime : nil
            )
            showToast("Dynamic Island is tracking \(event.courseCode).")
        } catch {
            showToast("Could not start Dynamic Island: \(error.localizedDescription)")
        }
    }

    private func showToast(_ message: String) {
        toastTask?.cancel()

        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            toastMessage = message
        }

        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            guard !Task.isCancelled else { return }

            withAnimation(.spring(response: 0.34, dampingFraction: 0.92)) {
                toastMessage = nil
            }
        }
    }

    private func updateLiveActivity(
        for event: CourseReminderSnapshot,
        compactShowsCountdown: Bool,
        compactCueID: Int,
        compactCueMinutes: Int,
        compactCountdownUntil: Date? = nil
    ) async {
        await ClassLiveActivityManager.shared.update(
            courseCode: event.courseCode,
            building: event.building,
            roomNumber: event.roomNumber,
            meetingType: event.meetingType,
            section: event.section,
            deliveryMode: event.deliveryMode,
            startTime: event.startTime,
            endTime: event.endTime,
            compactShowsCountdown: compactShowsCountdown,
            compactCueID: compactCueID,
            compactCueMinutes: compactCueMinutes,
            compactCountdownUntil: compactCountdownUntil
        )
    }

    private func snapshot(from event: CourseEvent) -> CourseReminderSnapshot {
        CourseReminderSnapshot(
            uid: event.uid,
            courseCode: event.courseCode,
            building: event.building,
            roomNumber: event.roomNumber,
            meetingType: event.meetingType,
            section: event.section,
            deliveryMode: event.deliveryMode,
            startTime: event.startTime,
            endTime: event.endTime
        )
    }

    private func clampAlertCueMinutes() {
        if alertCueMinutes > reminderLeadMinutes {
            let validOptions = ReminderSettingsCard.alertOptions.filter { $0 <= reminderLeadMinutes }
            alertCueMinutes = validOptions.max() ?? reminderLeadMinutes
        }
    }

    private func startPrimaryFlow() {
        if hasCompletedProfileSetup {
            isAddingCourse = true
        } else {
            isShowingProfileSetup = true
        }
    }

}

private enum HomeSection: String, CaseIterable, Identifiable {
    case today
    case schedule
    case alerts
    case profile

    var id: Self { self }

    var title: String {
        switch self {
        case .today: return "Today"
        case .schedule: return "Schedule"
        case .alerts: return "Alerts"
        case .profile: return "Profile"
        }
    }

    var systemImage: String {
        switch self {
        case .today: return "house.fill"
        case .schedule: return "calendar"
        case .alerts: return "timer"
        case .profile: return "person.crop.circle"
        }
    }
}

private struct HomeBottomNavigation: View {
    @Binding var selectedSection: HomeSection

    var body: some View {
        HStack(spacing: 6) {
            ForEach(HomeSection.allCases) { section in
                Button {
                    selectedSection = section
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: section.systemImage)
                            .font(.system(size: 16, weight: .semibold, design: .default))
                            .frame(height: 18)

                        Text(section.title)
                            .font(OnboardingFont.semibold(11))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }
                    .foregroundStyle(selectedSection == section ? AppTheme.blue : AppTheme.secondaryText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(
                        selectedSection == section ? AppTheme.blue.opacity(0.10) : .clear,
                        in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .animation(.spring(response: 0.22, dampingFraction: 0.9), value: selectedSection)
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel(section.title)
            }
        }
        .padding(6)
        .background(AppTheme.surface.opacity(0.96), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(AppTheme.border.opacity(0.9), lineWidth: 1)
        }
        .shadow(color: AppTheme.shadow.opacity(0.08), radius: 18, y: 10)
    }
}

private struct AppHeaderView: View {
    let hasSchedule: Bool
    let profileName: String

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 11) {
                Image("UofTimetableLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 70, height: 70)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: AppTheme.shadow.opacity(0.14), radius: 18, y: 10)

                Text("UTime")
                    .font(OnboardingFont.semibold(35))
                    .foregroundStyle(AppTheme.navy)

                Text("U of T classes, rooms, and live alerts.")
                    .font(OnboardingFont.medium(16))
                    .foregroundStyle(AppTheme.secondaryText)
                    .multilineTextAlignment(.center)
            }

            headerCopy
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.horizontal, 8)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .background { HeroCardBackground() }
    }

    private var headerCopy: Text {
        let trimmedName = profileName.trimmingCharacters(in: .whitespacesAndNewlines)

        if hasSchedule, !trimmedName.isEmpty {
            return Text("Ready for your next class, ")
                .font(OnboardingFont.regular(14))
                .foregroundColor(AppTheme.secondaryText)
            + Text(trimmedName)
                .font(OnboardingFont.semibold(14))
                .foregroundColor(AppTheme.secondaryText)
            + Text(". UTime keeps your timetable on your iPhone and brings class updates to your Lock Screen.")
                .font(OnboardingFont.regular(14))
                .foregroundColor(AppTheme.secondaryText)
        }

        return Text("Add your timetable once. UTime keeps your classes ready and brings the next room to your Lock Screen.")
            .font(OnboardingFont.regular(14))
            .foregroundColor(AppTheme.secondaryText)
    }
}

private struct HeroCardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        AppTheme.card,
                        AppTheme.cream.opacity(0.82),
                        AppTheme.sky.opacity(0.72),
                        AppTheme.background
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                ZStack {
                    RadialGradient(
                        colors: [AppTheme.blue.opacity(0.18), .clear],
                        center: .bottomLeading,
                        startRadius: 18,
                        endRadius: 260
                    )

                    RadialGradient(
                        colors: [AppTheme.navy.opacity(0.10), .clear],
                        center: .topTrailing,
                        startRadius: 8,
                        endRadius: 230
                    )

                    LinearGradient(
                        colors: [AppTheme.highlight.opacity(0.82), AppTheme.highlight.opacity(0.18), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(AppTheme.border.opacity(0.8), lineWidth: 1)
            }
    }
}

private struct OnboardingFlowView: View {
    @Binding var displayName: String
    @Binding var campus: String
    @Binding var major: String
    @Binding var year: String

    let onComplete: () -> Void

    @State private var hasStarted = false

    var body: some View {
        ZStack {
            OnboardingBackground()

            if hasStarted {
                ProfileSetupView(
                    displayName: $displayName,
                    campus: $campus,
                    major: $major,
                    year: $year,
                    onBack: {
                        withAnimation(.spring(response: 0.48, dampingFraction: 0.88)) {
                            hasStarted = false
                        }
                    },
                    onComplete: onComplete
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                WelcomeOnboardingView {
                    withAnimation(.spring(response: 0.48, dampingFraction: 0.88)) {
                        hasStarted = true
                    }
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
    }
}

private enum OnboardingFont {
    static func regular(_ size: CGFloat) -> Font {
        .custom("AvenirNext-Regular", size: size)
    }

    static func medium(_ size: CGFloat) -> Font {
        .custom("AvenirNext-Medium", size: size)
    }

    static func semibold(_ size: CGFloat) -> Font {
        .custom("AvenirNext-DemiBold", size: size)
    }
}

private struct WelcomeOnboardingView: View {
    let onGetStarted: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 42)

            VStack(spacing: 16) {
                Image("UofTimetableLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: AppTheme.shadow.opacity(0.16), radius: 28, y: 16)

                VStack(spacing: 8) {
                    Text("UTime")
                        .font(OnboardingFont.medium(44))
                        .foregroundStyle(AppTheme.navy)

                    Text("Your U of T timetable, ready before class.")
                        .font(OnboardingFont.regular(17))
                        .foregroundStyle(AppTheme.secondaryText)
                        .multilineTextAlignment(.center)
                }
            }

            Spacer(minLength: 48)

            VStack(alignment: .leading, spacing: 14) {
                WelcomeFeatureRow(systemImage: "calendar", title: "Add your courses", detail: "Enter your weekly meetings and rooms.")
                WelcomeFeatureRow(systemImage: "location.fill", title: "Find the room", detail: "Course and room show on the Lock Screen.")
                WelcomeFeatureRow(systemImage: "timer", title: "Arrive on time", detail: "Live cues appear before class.")
            }
            .padding(18)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                AppTheme.card.opacity(0.96),
                                AppTheme.cream.opacity(0.90),
                                AppTheme.sky.opacity(0.62)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(AppTheme.highlight.opacity(0.86), lineWidth: 1)
            }
            .overlay(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(AppTheme.blue.opacity(0.06), lineWidth: 8)
                    .blur(radius: 10)
                    .offset(x: -2, y: -2)
                    .mask(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                    )
            }
            .shadow(color: AppTheme.shadow.opacity(0.06), radius: 18, y: 12)

            Spacer(minLength: 32)

            VStack(spacing: 12) {
                WelcomeActionButton(action: onGetStarted)

                Text("No account needed.")
                    .font(OnboardingFont.medium(13))
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 22)
    }
}

private struct WelcomeActionButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.right")
                    .font(.system(size: 17, weight: .medium, design: .default))

                Text("Get Started")
                    .font(OnboardingFont.medium(17))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [AppTheme.blue, AppTheme.blue.opacity(0.92)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            }
            .shadow(color: AppTheme.blue.opacity(0.20), radius: 14, y: 8)
        }
        .buttonStyle(PressableButtonStyle())
    }
}

private struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.82), value: configuration.isPressed)
    }
}

private struct WelcomeFeatureRow: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold, design: .default))
                .foregroundStyle(AppTheme.blue)
                .frame(width: 32, height: 32)
                .background(AppTheme.surface.opacity(0.68), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(OnboardingFont.medium(14))
                    .foregroundStyle(AppTheme.primaryText)

                Text(detail)
                    .font(OnboardingFont.regular(13))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }

            Spacer(minLength: 0)
        }
    }
}

private struct ProfileSetupView: View {
    @Binding var displayName: String
    @Binding var campus: String
    @Binding var major: String
    @Binding var year: String

    let onBack: () -> Void
    let onComplete: () -> Void

    @State private var step = 0
    @FocusState private var isTextFieldFocused: Bool

    private let campuses = ["St. George", "UTM", "UTSC"]
    private let years = ["1st year", "2nd year", "3rd year", "4th year", "Graduate"]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: goBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold, design: .default))
                        .foregroundStyle(AppTheme.navy)
                        .frame(width: 38, height: 38)
                        .background(AppTheme.surface.opacity(0.62), in: Circle())
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)

            OnboardingProgressBar(currentStep: step, totalSteps: 4)
                .padding(.top, 10)

            Spacer(minLength: 34)

            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(stepTitle)
                        .font(OnboardingFont.medium(31))
                        .foregroundStyle(AppTheme.navy)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(stepSubtitle)
                        .font(OnboardingFont.regular(15))
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineSpacing(2)
                }

                stepContent

                OnboardingActionButton(
                    title: step == 3 ? "Finish" : "Next",
                    systemImage: step == 3 ? "checkmark" : "arrow.right",
                    isEnabled: canAdvance,
                    action: advance
                )
            }
            .padding(22)
            .background {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                AppTheme.card.opacity(0.96),
                                AppTheme.cream.opacity(0.90),
                                AppTheme.sky.opacity(0.62)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(AppTheme.highlight.opacity(0.86), lineWidth: 1)
            }
            .overlay(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(AppTheme.blue.opacity(0.06), lineWidth: 8)
                    .blur(radius: 10)
                    .offset(x: -2, y: -2)
                    .mask(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                    )
            }
            .shadow(color: AppTheme.shadow.opacity(0.06), radius: 18, y: 12)
            .padding(.horizontal, 20)

            Spacer(minLength: 38)
        }
        .onAppear {
            if campus.isEmpty {
                campus = campuses[0]
            }

            if year.isEmpty {
                year = years[0]
            }

        }
        .onChange(of: campus) { _, newCampus in
            let available = UofTPrograms.sections(for: newCampus).flatMap(\.programs)
            if !available.contains(major) {
                major = ""
            }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case 0:
            OnboardingTextField(
                title: "Name",
                placeholder: "",
                text: $displayName,
                systemImage: "person.fill"
            )
            .focused($isTextFieldFocused)
            .onAppear { isTextFieldFocused = true }
        case 1:
            OptionGrid(options: campuses, selection: $campus)
        case 2:
            ProgramPickerField(selection: $major, campus: campus)
        default:
            OptionGrid(options: years, selection: $year)
        }
    }

    private var stepTitle: String {
        switch step {
        case 0: return "What should UTime call you?"
        case 1: return "Which campus are you on?"
        case 2: return "What are you studying?"
        default: return "What year are you in?"
        }
    }

    private var stepSubtitle: String {
        switch step {
        case 0: return "This stays on your iPhone and is only used to personalize the app."
        case 1: return "Campus helps UTime feel built around your day."
        case 2: return "Pick your program or faculty. Not sure yet? Choose Undeclared."
        default: return "Last one. You can add your timetable from the home screen."
        }
    }

    private var canAdvance: Bool {
        switch step {
        case 0: return !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case 1: return !campus.isEmpty
        case 2: return !major.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: return !year.isEmpty
        }
    }

    private func advance() {
        guard canAdvance else { return }
        isTextFieldFocused = false

        if step < 3 {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                step += 1
            }
        } else {
            onComplete()
        }
    }

    private func goBack() {
        isTextFieldFocused = false

        if step > 0 {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                step -= 1
            }
        } else {
            onBack()
        }
    }
}

private struct OnboardingBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    AppTheme.cream,
                    AppTheme.background,
                    AppTheme.sky.opacity(0.86),
                    AppTheme.sky
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            LinearGradient(
                colors: [
                    AppTheme.blue.opacity(0.00),
                    AppTheme.blue.opacity(0.15),
                    AppTheme.navy.opacity(0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .mask(
                Rectangle()
                    .frame(height: 470)
                    .rotationEffect(.degrees(-12))
                    .offset(y: 286)
                    .blur(radius: 36)
            )

            LinearGradient(
                colors: [AppTheme.highlight.opacity(0.78), AppTheme.highlight.opacity(0.16), AppTheme.highlight.opacity(0.0)],
                startPoint: .top,
                endPoint: .center
            )
        }
        .ignoresSafeArea()
    }
}

private struct OnboardingProgressBar: View {
    let currentStep: Int
    let totalSteps: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<totalSteps, id: \.self) { index in
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(AppTheme.navy.opacity(0.10))

                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [AppTheme.blue, AppTheme.navy.opacity(0.86)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: proxy.size.width * fillAmount(for: index))
                            .shadow(color: AppTheme.blue.opacity(index == currentStep ? 0.25 : 0), radius: 5, y: 1)
                    }
                }
                .frame(height: index == currentStep ? 6 : 5)
                .scaleEffect(x: index == currentStep ? 1.025 : 1, y: index == currentStep ? 1.18 : 1)
            }
        }
        .padding(.horizontal, 48)
        .animation(.spring(response: 0.56, dampingFraction: 0.58, blendDuration: 0.08), value: currentStep)
    }

    private func fillAmount(for index: Int) -> CGFloat {
        index <= currentStep ? 1 : 0
    }
}

private struct OnboardingActionButton: View {
    let title: String
    let systemImage: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(OnboardingFont.medium(16))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(AppTheme.blue)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.white.opacity(0.18), lineWidth: 1)
                }
                .shadow(color: isEnabled ? AppTheme.blue.opacity(0.20) : .clear, radius: 12, y: 7)
        }
        .buttonStyle(PressableButtonStyle())
        .opacity(isEnabled ? 1 : 0.42)
        .disabled(!isEnabled)
    }
}

private struct OnboardingTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(OnboardingFont.medium(13))
                .foregroundStyle(AppTheme.secondaryText)

            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold, design: .default))
                    .foregroundStyle(AppTheme.blue)
                    .frame(width: 20)

                TextField(placeholder, text: $text)
                    .font(OnboardingFont.regular(17))
                    .foregroundStyle(AppTheme.primaryText)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .background(AppTheme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppTheme.blue.opacity(0.20), lineWidth: 1)
            }
        }
    }
}

private struct ProgramPickerField: View {
    @Binding var selection: String
    let campus: String

    @State private var isPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Program")
                .font(OnboardingFont.medium(13))
                .foregroundStyle(AppTheme.secondaryText)

            Button {
                isPresented = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "graduationcap.fill")
                        .font(.system(size: 15, weight: .semibold, design: .default))
                        .foregroundStyle(AppTheme.blue)
                        .frame(width: 20)

                    Text(selection.isEmpty ? "Select your program" : selection)
                        .font(OnboardingFont.regular(17))
                        .foregroundStyle(selection.isEmpty ? AppTheme.secondaryText : AppTheme.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold, design: .default))
                        .foregroundStyle(AppTheme.secondaryText)
                }
                .padding(.horizontal, 14)
                .frame(height: 52)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppTheme.blue.opacity(0.20), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $isPresented) {
            ProgramPickerSheet(selection: $selection, campus: campus)
        }
    }
}

private struct ProgramPickerSheet: View {
    @Binding var selection: String
    let campus: String

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var sections: [ProgramSection] {
        UofTPrograms.filtered(UofTPrograms.sections(for: campus), query: query)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.programs, id: \.self) { program in
                            Button {
                                selection = program
                                dismiss()
                            } label: {
                                HStack {
                                    Text(program)
                                        .foregroundStyle(AppTheme.primaryText)

                                    Spacer(minLength: 8)

                                    if selection == program {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(AppTheme.blue)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .overlay {
                if sections.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search programs")
            .navigationTitle("Your program")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
}

private struct OptionGrid: View {
    let options: [String]
    @Binding var selection: String

    var body: some View {
        VStack(spacing: 10) {
            if options.count == 3 {
                ForEach(options, id: \.self) { option in
                    optionButton(option)
                }
            } else {
                HStack(spacing: 10) {
                    optionButton(options[0])
                    optionButton(options[1])
                }

                HStack(spacing: 10) {
                    optionButton(options[2])
                    optionButton(options[3])
                }

                optionButton(options[4])
            }
        }
    }

    private func optionButton(_ option: String) -> some View {
        Button {
            selection = option
        } label: {
            Text(option)
                .font(OnboardingFont.medium(14))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .foregroundStyle(selection == option ? .white : AppTheme.navy)
        .background(selection == option ? AppTheme.blue : AppTheme.surface.opacity(0.78), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(selection == option ? .white.opacity(0.18) : AppTheme.border.opacity(0.9), lineWidth: 1)
        }
        .shadow(color: selection == option ? AppTheme.blue.opacity(0.16) : AppTheme.navy.opacity(0.04), radius: selection == option ? 10 : 6, y: selection == option ? 6 : 3)
    }
}

private struct NextClassCard: View {
    let event: CourseEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Next class")
                    .font(OnboardingFont.semibold(13))
                    .foregroundStyle(AppTheme.blue)

                Spacer()

                Text(event.startTime.formatted(date: .omitted, time: .shortened))
                    .font(OnboardingFont.semibold(15).monospacedDigit())
                    .foregroundStyle(AppTheme.navy)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(event.courseCode)
                    .font(OnboardingFont.semibold(30))
                    .foregroundStyle(AppTheme.navy)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Text(eventSubtitle)
                    .font(OnboardingFont.medium(14))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            HStack(spacing: 10) {
                Label(locationLabel, systemImage: locationIcon)
                    .font(OnboardingFont.semibold(15))
                    .foregroundStyle(AppTheme.navy)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(AppTheme.navy.opacity(0.07), in: Capsule())

                Spacer(minLength: 0)

                Text(event.startTime.formatted(date: .abbreviated, time: .omitted))
                    .font(OnboardingFont.medium(13))
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
        .padding(18)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        }
    }

    private var eventSubtitle: String {
        if event.deliveryMode == "Asynchronous" {
            return [event.meetingType, event.section]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        return [event.meetingType, event.section, event.deliveryMode]
            .filter { !$0.isEmpty }
            .joined(separator: " • ")
    }

    private var locationLabel: String {
        let room = [event.building, event.roomNumber]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        if !room.isEmpty {
            return room
        }

        return event.deliveryMode.isEmpty ? "No room" : event.deliveryMode
    }

    private var locationIcon: String {
        if event.deliveryMode == "Asynchronous" {
            return "clock.fill"
        }

        if event.deliveryMode == "Online" {
            return "wifi"
        }

        return "location.fill"
    }
}

private struct EmptyNextClassCard: View {
    let importAction: () -> Void
    let imageAction: () -> Void

    var body: some View {
        ActionPanel(title: "Next Class", subtitle: "Add your timetable and your next room appears here") {
            AddScheduleCard(importAction: importAction, imageAction: imageAction)
        }
    }
}

private struct DaySnapshotCard: View {
    let todayCount: Int
    let upcomingCount: Int
    let leadMinutes: Int
    let isPaused: Bool

    var body: some View {
        ActionPanel(title: "Today Overview", subtitle: snapshotSubtitle) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                SnapshotMetricPill(value: "\(todayCount)", label: "Today", systemImage: "sun.max.fill", tint: AppTheme.blue)
                SnapshotMetricPill(value: "\(upcomingCount)", label: "Upcoming", systemImage: "calendar", tint: AppTheme.navy)
                SnapshotMetricPill(value: "\(leadMinutes)", label: "Min before", systemImage: "timer", tint: AppTheme.blue)
                SnapshotMetricPill(value: isPaused ? "Off" : "On", label: "Island", systemImage: isPaused ? "pause.fill" : "sparkles", tint: isPaused ? AppTheme.secondaryText : AppTheme.navy)
            }
        }
    }

    private var snapshotSubtitle: String {
        todayCount == 0 ? "Nothing else today" : "\(todayCount) class\(todayCount == 1 ? "" : "es") left today"
    }
}

private struct SnapshotMetricPill: View {
    let value: String
    let label: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold, design: .default))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.10), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(OnboardingFont.semibold(17).monospacedDigit())
                    .foregroundStyle(AppTheme.navy)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Text(label)
                    .font(OnboardingFont.regular(12))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 58)
        .background(AppTheme.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct HeroIconBadge: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 20, weight: .semibold, design: .default))
            .foregroundStyle(.white)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 50, height: 50)
            .background(AppTheme.brandGradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(AppTheme.highlight.opacity(0.5), lineWidth: 1)
            }
            .shadow(color: AppTheme.blue.opacity(0.22), radius: 12, y: 6)
            .accessibilityHidden(true)
    }
}

private struct HeroInsetPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(AppTheme.card.opacity(0.66), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(AppTheme.border.opacity(0.7), lineWidth: 1)
            }
    }
}

private struct ScheduleHeroCard: View {
    let events: [CourseEvent]

    private var calendar: Calendar { .current }

    private var nextSevenDays: [Date] {
        let today = calendar.startOfDay(for: Date())
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 13) {
                HeroIconBadge(systemImage: "calendar")

                VStack(alignment: .leading, spacing: 2) {
                    Text("Schedule")
                        .font(OnboardingFont.semibold(27))
                        .foregroundStyle(AppTheme.navy)

                    Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()))
                        .font(OnboardingFont.medium(14))
                        .foregroundStyle(AppTheme.secondaryText)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                ForEach(nextSevenDays, id: \.self) { day in
                    WeekDayChip(
                        date: day,
                        classCount: classCount(on: day),
                        isToday: calendar.isDateInToday(day)
                    )
                }
            }

            HeroInsetPanel {
                HStack(spacing: 0) {
                    HeroStat(value: classCount(on: Date()), label: "Today")
                    HeroStatDivider()
                    HeroStat(value: nextSevenDays.reduce(0) { $0 + classCount(on: $1) }, label: "This week")
                    HeroStatDivider()
                    HeroStat(value: events.count, label: "Upcoming")
                }
                .padding(.vertical, 12)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background { HeroCardBackground() }
    }

    private func classCount(on day: Date) -> Int {
        events.filter { calendar.isDate($0.startTime, inSameDayAs: day) }.count
    }
}

private struct WeekDayChip: View {
    let date: Date
    let classCount: Int
    let isToday: Bool

    var body: some View {
        VStack(spacing: 5) {
            Text(date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                .font(OnboardingFont.semibold(10))
                .tracking(0.6)
                .foregroundStyle(isToday ? .white.opacity(0.82) : AppTheme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(date.formatted(.dateTime.day()))
                .font(OnboardingFont.semibold(17).monospacedDigit())
                .foregroundStyle(isToday ? .white : AppTheme.navy)

            HStack(spacing: 3) {
                ForEach(0..<min(classCount, 3), id: \.self) { _ in
                    Circle()
                        .fill(isToday ? .white : AppTheme.blue)
                        .frame(width: 4, height: 4)
                }
            }
            .frame(height: 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background {
            if isToday {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppTheme.brandGradient)
                    .shadow(color: AppTheme.blue.opacity(0.24), radius: 10, y: 5)
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppTheme.card.opacity(0.66))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(AppTheme.border.opacity(0.7), lineWidth: 1)
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(date.formatted(.dateTime.weekday(.wide).month().day())), \(classCount) class\(classCount == 1 ? "" : "es")")
    }
}

private struct HeroStat: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(OnboardingFont.semibold(20).monospacedDigit())
                .foregroundStyle(AppTheme.navy)
                .contentTransition(.numericText())

            Text(label)
                .font(OnboardingFont.medium(12))
                .foregroundStyle(AppTheme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct HeroStatDivider: View {
    var body: some View {
        Rectangle()
            .fill(AppTheme.border.opacity(0.8))
            .frame(width: 1, height: 30)
    }
}

private struct AddScheduleCard: View {
    let importAction: () -> Void
    let imageAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            QuickActionTile(
                systemImage: "plus",
                title: "Add a course",
                detail: "Enter meetings and rooms",
                isProminent: true,
                action: importAction
            )

            QuickActionTile(
                systemImage: "photo.on.rectangle.angled",
                title: "Upload timetable",
                detail: "Scan an ACORN PNG",
                isProminent: false,
                action: imageAction
            )
        }
    }
}

private struct QuickActionTile: View {
    let systemImage: String
    let title: String
    let detail: String
    let isProminent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold, design: .default))
                    .foregroundStyle(isProminent ? .white : AppTheme.blue)
                    .frame(width: 36, height: 36)
                    .background(
                        isProminent ? Color.white.opacity(0.18) : AppTheme.blue.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(OnboardingFont.semibold(15))
                        .foregroundStyle(isProminent ? .white : AppTheme.navy)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text(detail)
                        .font(OnboardingFont.regular(12))
                        .foregroundStyle(isProminent ? .white.opacity(0.78) : AppTheme.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isProminent ? AnyShapeStyle(AppTheme.mutedBrandGradient) : AnyShapeStyle(AppTheme.surface))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isProminent ? Color.white.opacity(0.18) : AppTheme.border, lineWidth: 1)
            }
            .shadow(color: isProminent ? AppTheme.blue.opacity(0.12) : AppTheme.shadow.opacity(0.04), radius: 14, y: 8)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
    }
}

private struct ReminderSettingsCard: View {
    static let alertOptions = [1, 5, 10, 15, 30, 60]

    @Binding var leadMinutes: Int
    @Binding var alertCueMinutes: Int
    @Binding var isPaused: Bool
    let rescheduleAction: () -> Void

    var body: some View {
        ActionPanel(title: "Live Activity Settings", subtitle: "Choose when the Lock Screen and island appear") {
            VStack(spacing: 12) {
                LiveActivityPauseControl(isPaused: $isPaused)

                VStack(spacing: 10) {
                    SettingHeader(
                        systemImage: "timer",
                        title: "Island appears",
                        value: leadMinutes,
                        tint: AppTheme.blue
                    )

                    Slider(
                        value: Binding(
                            get: { Double(leadMinutes) },
                            set: { leadMinutes = min(max(Int($0.rounded()), 1), 60) }
                        ),
                        in: 1...60,
                        step: 1
                    )
                    .tint(AppTheme.blue)

                    HStack {
                        Text("1 min")
                        Spacer()
                        Text("60 min max")
                    }
                    .font(OnboardingFont.medium(12))
                    .foregroundStyle(AppTheme.secondaryText)
                }
                .padding(14)
                .background(AppTheme.field, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 12) {
                    SettingHeader(
                        systemImage: "exclamationmark",
                        title: "Red alert cue",
                        value: alertCueMinutes,
                        tint: AppTheme.red
                    )

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(Self.alertOptions, id: \.self) { minutes in
                            AlertCueButton(
                                minutes: minutes,
                                isSelected: alertCueMinutes == minutes,
                                isEnabled: minutes <= leadMinutes
                            ) {
                                alertCueMinutes = minutes
                                rescheduleAction()
                            }
                        }
                    }

                    Text("Options after the island start time are disabled.")
                        .font(OnboardingFont.regular(12))
                        .foregroundStyle(AppTheme.secondaryText)
                }
                .padding(14)
                .background(AppTheme.field, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                SecondaryActionButton(
                    title: isPaused ? "Resume Live Activity" : "Update Live Activity",
                    systemImage: isPaused ? "play.fill" : "timer",
                    action: {
                        if isPaused {
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                                isPaused = false
                            }
                        } else {
                            rescheduleAction()
                        }
                    }
                )
            }
        }
    }
}

private struct SettingHeader: View {
    let systemImage: String
    let title: String
    let value: Int
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .bold, design: .default))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.12), in: Circle())

            Text(title)
                .font(OnboardingFont.semibold(15))
                .foregroundStyle(AppTheme.primaryText)

            Spacer()

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(value)")
                    .font(OnboardingFont.semibold(24).monospacedDigit())
                    .contentTransition(.numericText())

                Text("min")
                    .font(OnboardingFont.medium(13))
            }
            .foregroundStyle(tint)
            .animation(.snappy, value: value)
        }
    }
}

private struct AlertsHeroCard: View {
    let nextEvent: CourseEvent?
    let leadMinutes: Int
    let alertCueMinutes: Int
    let isPaused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 13) {
                HeroIconBadge(systemImage: isPaused ? "bell.slash.fill" : "bell.badge.fill")

                VStack(alignment: .leading, spacing: 2) {
                    Text("Alerts")
                        .font(OnboardingFont.semibold(27))
                        .foregroundStyle(AppTheme.navy)

                    Text(isPaused ? "Live Activities are paused" : "Lock Screen and Dynamic Island")
                        .font(OnboardingFont.medium(14))
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 0)
            }

            IslandPreview(event: nextEvent, alertCueMinutes: alertCueMinutes, isPaused: isPaused)

            AlertTimeline(leadMinutes: leadMinutes, alertCueMinutes: alertCueMinutes, isPaused: isPaused)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background { HeroCardBackground() }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: isPaused)
    }
}

private struct IslandPreview: View {
    let event: CourseEvent?
    let alertCueMinutes: Int
    let isPaused: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var isLight: Bool { colorScheme == .light }

    var body: some View {
        HStack(spacing: 12) {
            Image("UofTimetableLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(event?.courseCode ?? "Your next class")
                    .font(OnboardingFont.semibold(16))
                    .foregroundStyle(isLight ? AppTheme.navy : .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Label(locationText, systemImage: locationIcon)
                    .labelStyle(CompactLabelStyle())
                    .font(OnboardingFont.medium(12))
                    .foregroundStyle(isLight ? AppTheme.secondaryText : .white.opacity(0.6))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(alertCueMinutes):00")
                    .font(OnboardingFont.semibold(18).monospacedDigit())
                    .foregroundStyle(isLight ? AppTheme.red : AppTheme.islandRed)
                    .contentTransition(.numericText())

                Text(event.map { "Starts \($0.startTime.formatted(date: .omitted, time: .shortened))" } ?? "Red cue")
                    .font(OnboardingFont.medium(11))
                    .foregroundStyle(isLight ? AppTheme.secondaryText : .white.opacity(0.55))
                    .lineLimit(1)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 18)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 29, style: .continuous)
                .fill(
                    isLight
                        ? AnyShapeStyle(LinearGradient(
                            colors: [AppTheme.surface, AppTheme.sky.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        : AnyShapeStyle(Color.black)
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 29, style: .continuous)
                .stroke(isLight ? AppTheme.border : .white.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: AppTheme.shadow.opacity(isLight ? 0.08 : 0.22), radius: 16, y: 10)
        .saturation(isPaused ? 0 : 1)
        .opacity(isPaused ? 0.55 : 1)
        .animation(.snappy, value: alertCueMinutes)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live Activity preview for \(event?.courseCode ?? "your next class")")
    }

    private var locationIcon: String {
        switch event?.deliveryMode.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "Asynchronous": return "clock.fill"
        case "Online": return "wifi"
        default: return "location.fill"
        }
    }

    private var locationText: String {
        guard let event else { return "Room appears here" }
        let room = [event.building, event.roomNumber]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !room.isEmpty { return room }
        return event.deliveryMode.isEmpty ? "No room" : event.deliveryMode
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

private struct AlertTimeline: View {
    let leadMinutes: Int
    let alertCueMinutes: Int
    let isPaused: Bool

    private var cueFraction: CGFloat {
        guard leadMinutes > 0 else { return 1 }
        return 1 - CGFloat(min(alertCueMinutes, leadMinutes)) / CGFloat(leadMinutes)
    }

    var body: some View {
        HeroInsetPanel {
            VStack(spacing: 12) {
                GeometryReader { proxy in
                    let width = proxy.size.width
                    let cueX = width * cueFraction

                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(AppTheme.blue.opacity(0.85))
                            .frame(width: max(cueX, 0), height: 5)

                        Capsule()
                            .fill(AppTheme.red.opacity(0.85))
                            .frame(width: max(width - cueX, 0), height: 5)
                            .offset(x: cueX)

                        TimelineMarker(tint: AppTheme.blue)
                            .offset(x: -8)

                        TimelineMarker(tint: AppTheme.red)
                            .offset(x: cueX - 8)

                        TimelineMarker(tint: AppTheme.navy)
                            .offset(x: width - 8)
                    }
                    .frame(height: 16)
                }
                .frame(height: 16)
                .padding(.horizontal, 8)

                HStack(alignment: .top) {
                    TimelineLabel(title: "Island", detail: "\(leadMinutes) min before", tint: AppTheme.blue, alignment: .leading)
                    Spacer(minLength: 4)
                    TimelineLabel(title: "Red cue", detail: "\(alertCueMinutes) min before", tint: AppTheme.red, alignment: .center)
                    Spacer(minLength: 4)
                    TimelineLabel(title: "Class", detail: "Starts", tint: AppTheme.navy, alignment: .trailing)
                }
            }
            .padding(14)
        }
        .saturation(isPaused ? 0 : 1)
        .opacity(isPaused ? 0.6 : 1)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: cueFraction)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Island appears \(leadMinutes) minutes before class. Red cue \(alertCueMinutes) minutes before class.")
    }
}

private struct TimelineMarker: View {
    let tint: Color

    var body: some View {
        Circle()
            .fill(AppTheme.surface)
            .frame(width: 16, height: 16)
            .overlay { Circle().stroke(tint, lineWidth: 3.5) }
            .shadow(color: tint.opacity(0.25), radius: 4, y: 2)
    }
}

private struct TimelineLabel: View {
    let title: String
    let detail: String
    let tint: Color
    let alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(title)
                .font(OnboardingFont.semibold(13))
                .foregroundStyle(tint)

            Text(detail)
                .font(OnboardingFont.regular(11).monospacedDigit())
                .foregroundStyle(AppTheme.secondaryText)
                .contentTransition(.numericText())
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

private struct LiveActivityPauseControl: View {
    @Binding var isPaused: Bool

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                isPaused.toggle()
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isPaused ? "pause.circle.fill" : "sparkles")
                    .font(.system(size: 18, weight: .semibold, design: .default))
                    .foregroundStyle(isPaused ? AppTheme.secondaryText : AppTheme.blue)
                    .frame(width: 34, height: 34)
                    .background(AppTheme.card.opacity(0.76), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(isPaused ? "Live Activities Paused" : "Live Activities On")
                        .font(OnboardingFont.semibold(14))
                        .foregroundStyle(AppTheme.primaryText)

                    Text(isPaused ? "Your schedule stays saved. Island stays off." : "Next class can appear on the island.")
                        .font(OnboardingFont.regular(12))
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }

                Spacer(minLength: 0)

                LiveActivitySwitch(isOn: !isPaused)
            }
            .padding(12)
            .background(
                LinearGradient(
                    colors: [
                        AppTheme.card.opacity(0.92),
                        AppTheme.sky.opacity(isPaused ? 0.28 : 0.54)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isPaused ? AppTheme.border : AppTheme.blue.opacity(0.16), lineWidth: 1)
            }
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(isPaused ? "Resume Live Activities" : "Pause Live Activities")
    }
}

private struct LiveActivitySwitch: View {
    let isOn: Bool

    var body: some View {
        Capsule()
            .fill(isOn ? AppTheme.blue : AppTheme.switchOff)
            .frame(width: 52, height: 32)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .frame(width: 28, height: 28)
                    .padding(2)
                    .shadow(color: AppTheme.shadow.opacity(0.12), radius: 3, y: 1)
            }
            .animation(.spring(response: 0.24, dampingFraction: 0.9), value: isOn)
            .accessibilityHidden(true)
    }
}

private struct AlertCueButton: View {
    let minutes: Int
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold, design: .default))
                        .transition(.scale.combined(with: .opacity))
                }

                Text("\(minutes) min")
                    .font(OnboardingFont.semibold(13).monospacedDigit())
            }
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .foregroundStyle(foregroundColor)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        }
        .shadow(color: isSelected && isEnabled ? AppTheme.red.opacity(0.25) : .clear, radius: 8, y: 4)
        .animation(.spring(response: 0.26, dampingFraction: 0.86), value: isSelected)
        .opacity(isEnabled ? 1 : 0.35)
        .disabled(!isEnabled)
    }

    private var foregroundColor: Color {
        if !isEnabled { return AppTheme.secondaryText }
        return isSelected ? .white : AppTheme.red
    }

    private var backgroundColor: Color {
        if !isEnabled { return AppTheme.surface }
        return isSelected ? AppTheme.red : AppTheme.surface
    }

    private var borderColor: Color {
        if !isEnabled { return AppTheme.border }
        return isSelected ? AppTheme.red.opacity(0.2) : AppTheme.red.opacity(0.18)
    }
}

private struct AlertStatusCard: View {
    let upcomingCount: Int
    let leadMinutes: Int
    let alertCueMinutes: Int
    let isPaused: Bool
    let backendStatus: String
    let deviceStatus: String
    let retryAction: () -> Void

    private var hasFailed: Bool {
        backendStatus.localizedCaseInsensitiveContains("failed")
            || deviceStatus.localizedCaseInsensitiveContains("failed")
    }

    private var isReady: Bool {
        backendStatus == "Schedule synced" && deviceStatus == "Connected"
    }

    private var automaticUpdates: (systemImage: String, title: String, detail: String, tint: Color) {
        if isPaused {
            return ("pause.fill", "Automatic updates off", "Resume Live Activities to let UTime update while it's closed.", AppTheme.secondaryText)
        }
        if hasFailed {
            return ("exclamationmark.triangle.fill", "Automatic updates unavailable", "UTime couldn't reach the server. Check your connection and retry.", AppTheme.red)
        }
        if isReady {
            return ("checkmark", "Automatic updates ready", "Your schedule is synced, so class activities can start while UTime is closed. Delivery still depends on iOS and your connection.", AppTheme.blue)
        }
        let detail = deviceStatus == "Connected" ? "Syncing your schedule…" : "Waiting for this iPhone to register…"
        return ("arrow.triangle.2.circlepath", "Setting up automatic updates", detail, AppTheme.secondaryText)
    }

    var body: some View {
        ActionPanel(title: "Alert Status", subtitle: isPaused ? "Paused until you resume it" : "Ready for your saved classes") {
            VStack(spacing: 12) {
                VStack(spacing: 0) {
                    StatusRow(
                        systemImage: isPaused ? "pause.fill" : "dot.radiowaves.left.and.right",
                        title: isPaused ? "Live Activities paused" : "Live Activities active",
                        detail: isPaused ? "Your schedule is saved, but island updates are off." : "\(upcomingCount) upcoming class\(upcomingCount == 1 ? "" : "es") can trigger updates.",
                        tint: isPaused ? AppTheme.secondaryText : AppTheme.blue
                    )

                    ProfileRowDivider()

                    StatusRow(
                        systemImage: "exclamationmark",
                        title: "Red cue",
                        detail: "Turns red \(alertCueMinutes) min before class, after the \(leadMinutes) min island start.",
                        tint: AppTheme.red
                    )

                    ProfileRowDivider()

                    StatusRow(
                        systemImage: automaticUpdates.systemImage,
                        title: automaticUpdates.title,
                        detail: automaticUpdates.detail,
                        tint: automaticUpdates.tint
                    )
                }
                .padding(.horizontal, 14)
                .background(AppTheme.field, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                if !isPaused && !isReady {
                    SecondaryActionButton(
                        title: "Retry connection",
                        systemImage: "arrow.clockwise",
                        action: retryAction
                    )
                }
            }
        }
    }
}

private struct StatusRow: View {
    let systemImage: String
    let title: String
    let detail: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold, design: .default))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(OnboardingFont.semibold(14))
                    .foregroundStyle(AppTheme.primaryText)

                Text(detail)
                    .font(OnboardingFont.regular(13))
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 13)
    }
}

private struct ScheduleListCard: View {
    private static let visibleLimit = 12

    let events: [CourseEvent]
    let deleteAction: (CourseEvent) -> Void
    let clearAction: () -> Void

    @State private var isConfirmingClear = false

    var body: some View {
        ActionPanel(title: "Upcoming Classes", subtitle: subtitle) {
            if events.isEmpty {
                EmptyScheduleView()
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(groupedEvents, id: \.day) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            ScheduleDayHeader(date: group.day, classCount: group.events.count)

                            ForEach(group.events) { event in
                                SwipeToDeleteRow {
                                    ClassRow(event: event)
                                } deleteAction: {
                                    deleteAction(event)
                                }
                            }
                        }
                    }

                    if events.count > Self.visibleLimit {
                        Text("Showing the next \(Self.visibleLimit) of \(events.count) classes")
                            .font(OnboardingFont.medium(12))
                            .foregroundStyle(AppTheme.secondaryText)
                            .frame(maxWidth: .infinity)
                    }

                    DestructiveActionButton(
                        title: "Clear Schedule",
                        systemImage: "trash",
                        action: { isConfirmingClear = true }
                    )
                }
            }
        }
        .alert("Clear schedule?", isPresented: $isConfirmingClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Schedule", role: .destructive, action: clearAction)
        } message: {
            Text("This deletes every saved class from UTime on this device.")
        }
    }

    private var subtitle: String {
        events.isEmpty ? "Your classes will appear here" : "Swipe left on a class to delete it"
    }

    private var groupedEvents: [(day: Date, events: [CourseEvent])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: events.prefix(Self.visibleLimit)) { calendar.startOfDay(for: $0.startTime) }
        return groups.keys.sorted().map { day in
            (day, groups[day, default: []].sorted { $0.startTime < $1.startTime })
        }
    }
}

private struct ScheduleDayHeader: View {
    let date: Date
    let classCount: Int

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(OnboardingFont.semibold(12))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(isToday ? AppTheme.blue : AppTheme.navy)
                .lineLimit(1)

            Rectangle()
                .fill(AppTheme.border.opacity(0.7))
                .frame(height: 1)

            Text("\(classCount)")
                .font(OnboardingFont.semibold(11).monospacedDigit())
                .foregroundStyle(isToday ? AppTheme.blue : AppTheme.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(isToday ? AppTheme.blue.opacity(0.10) : AppTheme.field, in: Capsule())
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(classCount) class\(classCount == 1 ? "" : "es")")
        .accessibilityAddTraits(.isHeader)
    }

    private var isToday: Bool {
        Calendar.current.isDateInToday(date)
    }

    private var title: String {
        if isToday { return "Today" }
        if Calendar.current.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
}

private struct ProfileSummaryCard: View {
    @Environment(\.openURL) private var openURL

    let displayName: String
    let campus: String
    let major: String
    let year: String
    let importedCount: Int
    let editAction: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            ProfileHeroCard(name: trimmedName, campus: campus, year: year)

            ActionPanel(title: "Your details", subtitle: "Stored on this iPhone only") {
                VStack(spacing: 0) {
                    ProfileInfoRow(systemImage: "graduationcap.fill", title: "Program", value: major)
                    ProfileRowDivider()
                    ProfileInfoRow(systemImage: "building.columns.fill", title: "Campus", value: campus)
                    ProfileRowDivider()
                    ProfileInfoRow(systemImage: "person.text.rectangle.fill", title: "Year", value: year)
                    ProfileRowDivider()
                    ProfileInfoRow(systemImage: "calendar", title: "Scheduled", value: "\(importedCount) class\(importedCount == 1 ? "" : "es")")
                }
            }

            ReviewPromptRow(action: { openURL(appStoreReviewURL) })

            PrimaryActionButton(
                title: "Edit Profile",
                systemImage: "pencil",
                action: editAction
            )
        }
    }

    private var trimmedName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct ProfileHeroCard: View {
    let name: String
    let campus: String
    let year: String

    var body: some View {
        VStack(spacing: 14) {
            avatar

            VStack(spacing: 5) {
                Text(name.isEmpty ? "Your profile" : name)
                    .font(OnboardingFont.semibold(28))
                    .foregroundStyle(AppTheme.navy)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(OnboardingFont.medium(15))
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity)
        .background { HeroCardBackground() }
        .accessibilityElement(children: .combine)
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.10, green: 0.50, blue: 0.88), Color(red: 0.0, green: 0.26, blue: 0.56)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if let initial = name.first {
                Text(String(initial).uppercased())
                    .font(OnboardingFont.semibold(34))
                    .foregroundStyle(.white)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: 30, weight: .semibold, design: .default))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 78, height: 78)
        .overlay {
            Circle().stroke(AppTheme.highlight.opacity(0.9), lineWidth: 2)
        }
        .shadow(color: AppTheme.shadow.opacity(0.16), radius: 16, y: 8)
        .accessibilityHidden(true)
    }

    private var subtitle: String {
        [campus, year].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private struct ProfileRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(AppTheme.border.opacity(0.7))
            .frame(height: 1)
            .padding(.leading, 42)
    }
}

private struct ReviewPromptRow: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "star.fill")
                    .font(.system(size: 14, weight: .semibold, design: .default))
                    .foregroundStyle(AppTheme.blue)
                    .frame(width: 30, height: 30)
                    .background(AppTheme.blue.opacity(0.10), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text("Rate UTime")
                        .font(OnboardingFont.semibold(14))
                        .foregroundStyle(AppTheme.primaryText)

                    Text("Leave a quick App Store review")
                        .font(OnboardingFont.regular(12))
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 10)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold, design: .default))
                    .foregroundStyle(AppTheme.secondaryText.opacity(0.65))
            }
            .padding(.horizontal, 17)
            .frame(height: 62)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Rate UTime on the App Store")
    }
}

private struct ProfileInfoRow: View {
    let systemImage: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold, design: .default))
                .foregroundStyle(AppTheme.blue)
                .frame(width: 30, height: 30)
                .background(AppTheme.blue.opacity(0.10), in: Circle())

            Text(title)
                .font(OnboardingFont.medium(14))
                .foregroundStyle(AppTheme.secondaryText)

            Spacer(minLength: 12)

            Text(value.isEmpty ? "Not set" : value)
                .font(OnboardingFont.semibold(14))
                .foregroundStyle(AppTheme.primaryText)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .padding(.vertical, 10)
        .frame(minHeight: 52)
    }
}

private struct SwipeToDeleteRow<Content: View>: View {
    let content: Content
    let deleteAction: () -> Void

    @State private var offset: CGFloat = 0
    @State private var dragStartOffset: CGFloat = 0
    @State private var isTrackingHorizontalDrag = false

    private let deleteWidth: CGFloat = 82

    init(@ViewBuilder content: () -> Content, deleteAction: @escaping () -> Void) {
        self.content = content()
        self.deleteAction = deleteAction
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(role: .destructive) {
                withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.88, blendDuration: 0.08)) {
                    offset = 0
                }
                deleteAction()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 15, weight: .semibold, design: .default))
                    Text("Delete")
                        .font(OnboardingFont.semibold(11))
                }
                .foregroundStyle(.white)
                .frame(width: deleteWidth)
                .frame(maxHeight: .infinity)
                .background(AppTheme.red)
            }
            .buttonStyle(.plain)

            content
                .overlay {
                    HorizontalSwipeGestureView(
                        isTapEnabled: offset != 0,
                        onTap: close,
                        onBegan: {
                            isTrackingHorizontalDrag = true
                            dragStartOffset = offset
                        },
                        onChanged: { translation in
                            guard isTrackingHorizontalDrag else { return }

                            let nextOffset = dragStartOffset + translation
                            offset = min(0, max(-deleteWidth, nextOffset))
                        },
                        onEnded: { translation, velocity in
                            defer {
                                isTrackingHorizontalDrag = false
                                dragStartOffset = 0
                            }

                            guard isTrackingHorizontalDrag else { return }

                            let projectedOffset = dragStartOffset + translation + velocity * 0.12
                            let shouldOpen = projectedOffset < -deleteWidth * 0.52 || offset < -deleteWidth * 0.62

                            withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.08)) {
                                offset = shouldOpen ? -deleteWidth : 0
                            }
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .offset(x: offset)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.92, blendDuration: 0.06), value: offset)
    }

    private func close() {
        guard offset != 0 else { return }

        withAnimation(.interactiveSpring(response: 0.30, dampingFraction: 0.9, blendDuration: 0.06)) {
            offset = 0
        }
    }
}

private struct HorizontalSwipeGestureView: UIViewRepresentable {
    let isTapEnabled: Bool
    let onTap: () -> Void
    let onBegan: () -> Void
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear

        let panGesture = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        panGesture.cancelsTouchesInView = false
        panGesture.delegate = context.coordinator
        view.addGestureRecognizer(panGesture)

        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tapGesture.cancelsTouchesInView = false
        tapGesture.delegate = context.coordinator
        view.addGestureRecognizer(tapGesture)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: HorizontalSwipeGestureView

        init(parent: HorizontalSwipeGestureView) {
            self.parent = parent
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }

            switch recognizer.state {
            case .began:
                parent.onBegan()
            case .changed:
                parent.onChanged(recognizer.translation(in: view).x)
            case .ended, .cancelled, .failed:
                parent.onEnded(recognizer.translation(in: view).x, recognizer.velocity(in: view).x)
            default:
                break
            }
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, parent.isTapEnabled else { return }
            parent.onTap()
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer is UITapGestureRecognizer {
                return parent.isTapEnabled
            }

            guard let panGesture = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = gestureRecognizer.view else {
                return false
            }

            let velocity = panGesture.velocity(in: view)
            return abs(velocity.x) > 40 && abs(velocity.x) > abs(velocity.y) * 1.35
        }
    }
}

private struct EmptyScheduleView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 20, weight: .semibold, design: .default))
                .foregroundStyle(AppTheme.blue)
                .frame(width: 48, height: 48)
                .background(AppTheme.blue.opacity(0.10), in: Circle())

            VStack(spacing: 3) {
                Text("No classes yet")
                    .font(OnboardingFont.semibold(15))
                    .foregroundStyle(AppTheme.primaryText)

                Text("Add a course or upload your ACORN timetable to see your week here.")
                    .font(OnboardingFont.regular(13))
                    .foregroundStyle(AppTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 22)
        .background(AppTheme.field, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(AppTheme.border, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
    }
}

private struct ClassRow: View {
    let event: CourseEvent

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(event.startTime.formatted(date: .omitted, time: .shortened))
                    .font(OnboardingFont.semibold(14).monospacedDigit())
                    .foregroundStyle(AppTheme.navy)

                Text(event.endTime.formatted(date: .omitted, time: .shortened))
                    .font(OnboardingFont.regular(12).monospacedDigit())
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(width: 64, alignment: .leading)

            Capsule()
                .fill(accent)
                .frame(width: 4, height: 38)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(event.courseCode)
                        .font(OnboardingFont.semibold(16))
                        .foregroundStyle(AppTheme.navy)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    if !meetingTag.isEmpty {
                        Text(meetingTag)
                            .font(OnboardingFont.semibold(10))
                            .foregroundStyle(accent)
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(accent.opacity(0.12), in: Capsule())
                    }
                }

                Label(locationText, systemImage: locationIcon)
                    .labelStyle(CompactLabelStyle())
                    .font(OnboardingFont.medium(12))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(AppTheme.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var meetingTag: String {
        [event.meetingType, event.section]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private var accent: Color {
        let type = event.meetingType.lowercased()
        if type.hasPrefix("tut") { return AppTheme.teal }
        if type.hasPrefix("lab") || type.hasPrefix("pra") { return AppTheme.amber }
        if type.hasPrefix("sem") { return AppTheme.violet }
        return AppTheme.blue
    }

    private var locationText: String {
        let room = [event.building, event.roomNumber]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        if !room.isEmpty {
            return room
        }

        return event.deliveryMode.isEmpty ? "No room" : event.deliveryMode
    }

    private var locationIcon: String {
        switch event.deliveryMode.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "Asynchronous": return "clock.fill"
        case "Online": return "wifi"
        default: return "location.fill"
        }
    }
}

private struct FloatingStatusToast: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold, design: .default))
                .foregroundStyle(AppTheme.blue)
                .frame(width: 24, height: 24)
                .background(AppTheme.blue.opacity(0.10), in: Circle())

            Text(message)
                .font(OnboardingFont.medium(14))
                .foregroundStyle(AppTheme.primaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppTheme.card)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppTheme.blue.opacity(0.26), lineWidth: 1.2)
        }
        .overlay(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppTheme.blue.opacity(0.10), lineWidth: 8)
                .blur(radius: 10)
                .offset(x: -2, y: -2)
                .mask(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
        }
        .shadow(color: AppTheme.shadow.opacity(0.12), radius: 18, y: 12)
    }
}

private struct ActionPanel<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(OnboardingFont.semibold(18))
                    .foregroundStyle(AppTheme.navy)

                Text(subtitle)
                    .font(OnboardingFont.regular(13))
                    .foregroundStyle(AppTheme.secondaryText)
            }

            content
        }
        .padding(17)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        }
    }
}

private struct PrimaryActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(OnboardingFont.semibold(15))
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(AppTheme.blue, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct SecondaryActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(OnboardingFont.medium(15))
                .frame(maxWidth: .infinity)
                .frame(height: 46)
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppTheme.blue)
        .background(AppTheme.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct DestructiveActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            Label(title, systemImage: systemImage)
                .font(OnboardingFont.medium(15))
                .frame(maxWidth: .infinity)
                .frame(height: 46)
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppTheme.red)
        .background(AppTheme.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private extension Color {
    init(light: (Double, Double, Double), dark: (Double, Double, Double), darkAlpha: Double = 1) {
        self.init(uiColor: UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor(red: dark.0, green: dark.1, blue: dark.2, alpha: darkAlpha)
            }
            return UIColor(red: light.0, green: light.1, blue: light.2, alpha: 1)
        })
    }
}

private enum AppTheme {
    static let navy = Color(light: (0.0, 0.16, 0.36), dark: (0.80, 0.89, 1.0))
    static let deepNavy = Color(light: (0.0, 0.09, 0.20), dark: (0.88, 0.94, 1.0))
    static let blue = Color(light: (0.0, 0.42, 0.78), dark: (0.10, 0.50, 0.88))
    static let red = Color(light: (0.78, 0.16, 0.16), dark: (0.88, 0.28, 0.28))
    static let teal = Color(light: (0.0, 0.52, 0.55), dark: (0.28, 0.76, 0.78))
    static let amber = Color(light: (0.80, 0.48, 0.0), dark: (0.96, 0.68, 0.26))
    static let violet = Color(light: (0.38, 0.30, 0.78), dark: (0.64, 0.57, 0.96))
    static let islandRed = Color(red: 1.0, green: 0.36, blue: 0.34)
    static let brandGradient = LinearGradient(
        colors: [
            Color(light: (0.24, 0.60, 0.97), dark: (0.10, 0.50, 0.88)),
            Color(light: (0.06, 0.44, 0.87), dark: (0.0, 0.26, 0.56))
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let mutedBrandGradient = LinearGradient(
        colors: [
            Color(light: (0.24, 0.60, 0.97), dark: (0.06, 0.36, 0.66)),
            Color(light: (0.06, 0.44, 0.87), dark: (0.0, 0.20, 0.43))
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let cream = Color(light: (0.995, 0.985, 0.955), dark: (0.07, 0.09, 0.13))
    static let sky = Color(light: (0.84, 0.94, 0.99), dark: (0.08, 0.17, 0.28))
    static let background = Color(light: (0.975, 0.985, 0.995), dark: (0.04, 0.06, 0.10))
    static let surface = Color(light: (1.0, 1.0, 1.0), dark: (0.12, 0.15, 0.20))
    static let card = Color(light: (1.0, 1.0, 1.0), dark: (0.11, 0.14, 0.19))
    static let highlight = Color(light: (1.0, 1.0, 1.0), dark: (1.0, 1.0, 1.0), darkAlpha: 0.12)
    static let shadow = Color(light: (0.0, 0.16, 0.36), dark: (0.0, 0.0, 0.0))
    static let switchOff = Color(light: (0.70, 0.75, 0.78), dark: (0.30, 0.34, 0.40))
    static let field = Color(light: (0.955, 0.972, 0.99), dark: (0.10, 0.13, 0.18))
    static let border = Color(light: (0.84, 0.89, 0.945), dark: (0.20, 0.26, 0.34))
    static let primaryText = Color(light: (0.10, 0.13, 0.18), dark: (0.94, 0.96, 0.98))
    static let secondaryText = Color(light: (0.45, 0.50, 0.58), dark: (0.62, 0.68, 0.76))
}

#Preview {
    ContentView()
        .modelContainer(for: [Item.self, CourseEvent.self], inMemory: true)
}
