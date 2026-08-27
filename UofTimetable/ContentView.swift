//
//  ContentView.swift
//  UofTimetable
//

import ActivityKit
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private let calendarFileType = UTType(filenameExtension: "ics") ?? .data

struct ContentView: View {
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

    @State private var isImportingSchedule = false
    @State private var isShowingProfileSetup = false
    @State private var toastMessage: String?
    @State private var toastTask: Task<Void, Never>?
    @State private var islandTask: Task<Void, Never>?
    @State private var selectedHomeSection = HomeSection.today

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
                .fileImporter(
                    isPresented: $isImportingSchedule,
                    allowedContentTypes: [calendarFileType],
                    allowsMultipleSelection: false,
                    onCompletion: handleFileImport
                )
            }
        }
        .onAppear {
            clampAlertCueMinutes()
            restartIslandScheduler()
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
                EmptyNextClassCard(importAction: { isImportingSchedule = true })
            }

            DaySnapshotCard(
                todayCount: todayEvents.count,
                upcomingCount: upcomingEvents.count,
                leadMinutes: reminderLeadMinutes,
                isPaused: isLiveActivityPaused
            )
        case .schedule:
            ImportScheduleCard(
                importedCount: courseEvents.count,
                importAction: { isImportingSchedule = true }
            )

            ScheduleListCard(
                events: upcomingEvents,
                deleteAction: deleteEvent,
                clearAction: clearSchedule
            )
        case .alerts:
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
                isPaused: isLiveActivityPaused
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

    private func handleFileImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let calendarText = try String(contentsOf: url, encoding: .utf8)
            let drafts = ICSParser.parse(calendarText)
            replaceSchedule(with: drafts)
            let snapshots = drafts.map(CourseReminderSnapshot.init)

            restartIslandScheduler(with: snapshots)
            syncSchedule(with: snapshots)

            showToast(
                drafts.isEmpty
                    ? "No classes were found in that calendar."
                    : "Imported \(drafts.count) classes from \(url.lastPathComponent)."
            )
        } catch {
            showToast("Could not import calendar: \(error.localizedDescription)")
        }
    }

    private func replaceSchedule(with drafts: [CourseEventDraft]) {
        for event in courseEvents {
            modelContext.delete(event)
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

        try? modelContext.save()
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

    private func restartIslandScheduler(with snapshots: [CourseReminderSnapshot]) {
        islandTask?.cancel()
        guard !isLiveActivityPaused else { return }

        let leadMinutes = reminderLeadMinutes

        islandTask = Task {
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
            isImportingSchedule = true
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
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
        .shadow(color: AppTheme.navy.opacity(0.08), radius: 18, y: 10)
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
                    .shadow(color: AppTheme.navy.opacity(0.14), radius: 18, y: 10)

                Text("UTime")
                    .font(OnboardingFont.semibold(35))
                    .foregroundStyle(AppTheme.navy)

                Text("U of T classes, rooms, and live alerts.")
                    .font(OnboardingFont.medium(16))
                    .foregroundStyle(AppTheme.secondaryText)
                    .multilineTextAlignment(.center)
            }

            Text(headerCopy)
                .font(OnboardingFont.regular(14))
                .foregroundStyle(AppTheme.secondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.horizontal, 8)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            .white,
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
                            colors: [.white.opacity(0.82), .white.opacity(0.18), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppTheme.border.opacity(0.8), lineWidth: 1)
        }
    }

    private var headerCopy: String {
        let trimmedName = profileName.trimmingCharacters(in: .whitespacesAndNewlines)

        if hasSchedule, !trimmedName.isEmpty {
            return "Ready for your next class, \(trimmedName). UTime keeps your timetable on your iPhone and uses limited Live Activity data for lock screen updates."
        }

        return "Import your timetable once. UTime keeps your classes ready and brings the next room to your Lock Screen."
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
                    .shadow(color: AppTheme.navy.opacity(0.16), radius: 28, y: 16)

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
                WelcomeFeatureRow(systemImage: "calendar", title: "Import once", detail: "Choose your .ics timetable file.")
                WelcomeFeatureRow(systemImage: "location.fill", title: "Find the room", detail: "Course and room show on the Lock Screen.")
                WelcomeFeatureRow(systemImage: "timer", title: "Arrive on time", detail: "Live cues appear before class.")
            }
            .padding(18)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.96),
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
                    .stroke(.white.opacity(0.86), lineWidth: 1)
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
            .shadow(color: AppTheme.navy.opacity(0.06), radius: 18, y: 12)

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
    private let programs = [
        "Accounting",
        "Architecture",
        "Art History",
        "Biochemistry",
        "Biology",
        "Business",
        "Chemistry",
        "Commerce",
        "Computer Science",
        "Criminology",
        "Economics",
        "Education",
        "Engineering",
        "English",
        "Environmental Science",
        "Finance",
        "Global Affairs",
        "History",
        "Life Sciences",
        "Linguistics",
        "Math & Statistics",
        "Media Studies",
        "Music",
        "Neuroscience",
        "Nursing",
        "Philosophy",
        "Physical Sciences",
        "Political Science",
        "Psychology",
        "Rotman Commerce",
        "Social Sciences",
        "Sociology",
        "Visual Studies",
        "Other"
    ]
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
                                .white.opacity(0.96),
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
                    .stroke(.white.opacity(0.86), lineWidth: 1)
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
            .shadow(color: AppTheme.navy.opacity(0.06), radius: 18, y: 12)
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

            if major.isEmpty {
                major = programs[0]
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
            OnboardingDropdownField(
                title: "Program",
                selection: $major,
                options: programs,
                systemImage: "graduationcap.fill"
            )
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
        case 2: return "Optional context for your local profile."
        default: return "Last one. You can import your timetable from the home screen."
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
                colors: [.white.opacity(0.78), .white.opacity(0.16), .white.opacity(0.0)],
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

private struct OnboardingDropdownField: View {
    let title: String
    @Binding var selection: String
    let options: [String]
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(OnboardingFont.medium(13))
                .foregroundStyle(AppTheme.secondaryText)

            Menu {
                ForEach(options, id: \.self) { option in
                    Button {
                        var transaction = Transaction()
                        transaction.animation = nil

                        withTransaction(transaction) {
                            selection = option
                        }
                    } label: {
                        if selection == option {
                            Label(option, systemImage: "checkmark")
                        } else {
                            Text(option)
                        }
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold, design: .default))
                        .foregroundStyle(AppTheme.blue)
                        .frame(width: 20)

                    Text(selection)
                        .font(OnboardingFont.regular(17))
                        .foregroundStyle(AppTheme.primaryText)
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
            .transaction { transaction in
                transaction.animation = nil
            }
        }
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

    var body: some View {
        ActionPanel(title: "Next Class", subtitle: "Nothing upcoming yet") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "calendar.badge.plus")
                        .font(.system(size: 18, weight: .semibold, design: .default))
                        .foregroundStyle(AppTheme.blue)
                        .frame(width: 36, height: 36)
                        .background(AppTheme.blue.opacity(0.10), in: Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Import your timetable")
                            .font(OnboardingFont.semibold(15))
                            .foregroundStyle(AppTheme.primaryText)

                        Text("Your next room appears here.")
                            .font(OnboardingFont.regular(13))
                            .foregroundStyle(AppTheme.secondaryText)
                    }

                    Spacer(minLength: 0)
                }

                PrimaryActionButton(
                    title: "Import .ics File",
                    systemImage: "square.and.arrow.down",
                    action: importAction
                )
            }
        }
    }
}

private struct DaySnapshotCard: View {
    let todayCount: Int
    let upcomingCount: Int
    let leadMinutes: Int
    let isPaused: Bool

    var body: some View {
        ActionPanel(title: "Day Snapshot", subtitle: snapshotSubtitle) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                SnapshotMetricPill(value: "\(todayCount)", label: "Today", systemImage: "sun.max.fill", tint: AppTheme.blue)
                SnapshotMetricPill(value: "\(upcomingCount)", label: "Upcoming", systemImage: "calendar", tint: AppTheme.navy)
                SnapshotMetricPill(value: "\(leadMinutes)", label: "Min before", systemImage: "timer", tint: AppTheme.blue)
                SnapshotMetricPill(value: isPaused ? "Off" : "On", label: "Island", systemImage: isPaused ? "pause.fill" : "sparkles", tint: isPaused ? AppTheme.secondaryText : AppTheme.red)
            }
        }
    }

    private var snapshotSubtitle: String {
        todayCount == 0 ? "A calmer view until your next class" : "\(todayCount) class\(todayCount == 1 ? "" : "es") left today"
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

private struct ImportScheduleCard: View {
    let importedCount: Int
    let importAction: () -> Void

    var body: some View {
        ActionPanel(title: "Import Schedule", subtitle: "Use the .ics file from your timetable") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 0) {
                    TutorialStep(systemImage: "arrow.down.doc", title: "Download", text: "Export your timetable as an .ics calendar file.")
                    Divider().padding(.leading, 30)
                    TutorialStep(systemImage: "folder", title: "Choose file", text: "Import the file into UTime.")
                    Divider().padding(.leading, 30)
                    TutorialStep(systemImage: "iphone.gen2", title: "Track next class", text: "Room and timing appear on your phone.")
                }
                .padding(.vertical, 2)

                PrimaryActionButton(
                    title: importedCount == 0 ? "Import .ics File" : "Replace .ics File",
                    systemImage: "square.and.arrow.down",
                    action: importAction
                )
            }
        }
    }
}

private struct TutorialStep: View {
    let systemImage: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold, design: .default))
                .foregroundStyle(AppTheme.blue)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(OnboardingFont.semibold(13))
                    .foregroundStyle(AppTheme.primaryText)

                Text(text)
                    .font(OnboardingFont.regular(13))
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }
}

private struct ReminderSettingsCard: View {
    static let alertOptions = [1, 5, 10, 15, 30, 60]

    @Binding var leadMinutes: Int
    @Binding var alertCueMinutes: Int
    @Binding var isPaused: Bool
    let rescheduleAction: () -> Void

    var body: some View {
        ActionPanel(title: "Live Activity Settings", subtitle: "Choose when the lock screen and island appear") {
            VStack(spacing: 14) {
                LiveActivityPauseControl(isPaused: $isPaused)

                HStack(alignment: .firstTextBaseline) {
                    Text("Before class")
                        .font(OnboardingFont.medium(15))
                        .foregroundStyle(AppTheme.primaryText)

                    Spacer()

                    Text("\(leadMinutes) min")
                        .font(OnboardingFont.semibold(20).monospacedDigit())
                        .foregroundStyle(AppTheme.navy)
                }

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

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Red alert cue")
                            .font(OnboardingFont.medium(15))
                            .foregroundStyle(AppTheme.primaryText)

                        Spacer()

                        Text("\(alertCueMinutes) min")
                            .font(OnboardingFont.semibold(15).monospacedDigit())
                            .foregroundStyle(AppTheme.red)
                    }

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
                .padding(.top, 2)

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
                    .background(.white.opacity(0.76), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(isPaused ? "Live Activities Paused" : "Live Activities On")
                        .font(OnboardingFont.semibold(14))
                        .foregroundStyle(AppTheme.primaryText)

                    Text(isPaused ? "Schedule stays imported. Island stays off." : "Next class can appear on the island.")
                        .font(OnboardingFont.regular(12))
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }

                Spacer(minLength: 0)

                Toggle("", isOn: $isPaused)
                    .labelsHidden()
                    .tint(AppTheme.blue)
                    .allowsHitTesting(false)
            }
            .padding(12)
            .background(
                LinearGradient(
                    colors: [
                        .white.opacity(0.92),
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

private struct AlertCueButton: View {
    let minutes: Int
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("\(minutes) min")
                .font(OnboardingFont.semibold(13).monospacedDigit())
                .frame(maxWidth: .infinity)
                .frame(height: 36)
        }
        .buttonStyle(.plain)
        .foregroundStyle(foregroundColor)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        }
        .opacity(isEnabled ? 1 : 0.35)
        .disabled(!isEnabled)
    }

    private var foregroundColor: Color {
        if !isEnabled { return AppTheme.secondaryText }
        return isSelected ? .white : AppTheme.red
    }

    private var backgroundColor: Color {
        if !isEnabled { return AppTheme.field }
        return isSelected ? AppTheme.red : AppTheme.red.opacity(0.08)
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

    var body: some View {
        ActionPanel(title: "Alert Status", subtitle: isPaused ? "Paused until you resume it" : "Ready for your imported classes") {
            VStack(spacing: 10) {
                StatusRow(
                    systemImage: isPaused ? "pause.circle.fill" : "checkmark.circle.fill",
                    title: isPaused ? "Live Activities paused" : "Live Activities active",
                    detail: isPaused ? "Your schedule is saved, but island updates are off." : "\(upcomingCount) upcoming class\(upcomingCount == 1 ? "" : "es") can trigger updates.",
                    tint: isPaused ? AppTheme.secondaryText : AppTheme.blue
                )

                StatusRow(
                    systemImage: "exclamationmark.circle.fill",
                    title: "Red cue",
                    detail: "Turns red \(alertCueMinutes) min before class, after the \(leadMinutes) min island start.",
                    tint: AppTheme.red
                )
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
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold, design: .default))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)

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
        .padding(12)
        .background(AppTheme.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ScheduleListCard: View {
    let events: [CourseEvent]
    let deleteAction: (CourseEvent) -> Void
    let clearAction: () -> Void

    @State private var isConfirmingClear = false

    var body: some View {
        ActionPanel(title: "Upcoming Classes", subtitle: subtitle) {
            if events.isEmpty {
                EmptyScheduleView()
            } else {
                VStack(spacing: 10) {
                    ForEach(events.prefix(12)) { event in
                        SwipeToDeleteRow {
                            ClassRow(event: event)
                        } deleteAction: {
                            deleteAction(event)
                        }
                    }

                    DestructiveActionButton(
                        title: "Clear Schedule",
                        systemImage: "trash",
                        action: { isConfirmingClear = true }
                    )
                    .padding(.top, 4)
                }
            }
        }
        .alert("Clear schedule?", isPresented: $isConfirmingClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Schedule", role: .destructive, action: clearAction)
        } message: {
            Text("This deletes every imported class from UTime on this device.")
        }
    }

    private var subtitle: String {
        events.isEmpty ? "Imported classes will appear here" : "\(events.count) future classes imported"
    }
}

private struct ProfileSummaryCard: View {
    let displayName: String
    let campus: String
    let major: String
    let year: String
    let importedCount: Int
    let editAction: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            ActionPanel(title: profileTitle, subtitle: "Your local UTime profile") {
                VStack(spacing: 10) {
                    ProfileInfoRow(systemImage: "building.columns.fill", title: "Campus", value: campus)
                    ProfileInfoRow(systemImage: "graduationcap.fill", title: "Program", value: major)
                    ProfileInfoRow(systemImage: "person.text.rectangle.fill", title: "Year", value: year)
                    ProfileInfoRow(systemImage: "calendar", title: "Imported", value: "\(importedCount) class\(importedCount == 1 ? "" : "es")")
                }
            }

            SecondaryActionButton(
                title: "Edit Profile",
                systemImage: "pencil",
                action: editAction
            )
        }
    }

    private var profileTitle: String {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? "Profile" : trimmedName
    }
}

private struct ProfileInfoRow: View {
    let systemImage: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold, design: .default))
                .foregroundStyle(AppTheme.blue)
                .frame(width: 28, height: 28)
                .background(AppTheme.blue.opacity(0.09), in: Circle())

            Text(title)
                .font(OnboardingFont.medium(13))
                .foregroundStyle(AppTheme.secondaryText)

            Spacer(minLength: 10)

            Text(value.isEmpty ? "Not set" : value)
                .font(OnboardingFont.semibold(13))
                .foregroundStyle(AppTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(AppTheme.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        HStack(spacing: 10) {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 17, weight: .medium, design: .default))
                .foregroundStyle(AppTheme.blue)

            Text("No classes imported yet")
                .font(OnboardingFont.regular(14))
                .foregroundStyle(AppTheme.secondaryText)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(AppTheme.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ClassRow: View {
    let event: CourseEvent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(event.courseCode)
                    .font(OnboardingFont.semibold(16))
                    .foregroundStyle(AppTheme.navy)
                    .lineLimit(1)

                Text(eventSubtitle)
                    .font(OnboardingFont.regular(13))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 5) {
                Text(event.startTime.formatted(date: .abbreviated, time: .shortened))
                    .font(OnboardingFont.medium(13))
                    .foregroundStyle(AppTheme.primaryText)
                    .multilineTextAlignment(.trailing)

                if !eventLocation.isEmpty {
                    Text(eventLocation)
                        .font(OnboardingFont.medium(13))
                        .foregroundStyle(AppTheme.blue)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(AppTheme.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var eventSubtitle: String {
        if event.deliveryMode == "Asynchronous" {
            return [event.meetingType, event.section]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        return [event.meetingType, event.section, event.deliveryMode]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private var eventLocation: String {
        [event.building, event.roomNumber]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
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
                .fill(.white)
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
        .shadow(color: AppTheme.navy.opacity(0.12), radius: 18, y: 12)
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

private enum AppTheme {
    static let navy = Color(red: 0.0, green: 0.16, blue: 0.36)
    static let deepNavy = Color(red: 0.0, green: 0.09, blue: 0.20)
    static let blue = Color(red: 0.0, green: 0.42, blue: 0.78)
    static let red = Color(red: 0.78, green: 0.16, blue: 0.16)
    static let cream = Color(red: 0.995, green: 0.985, blue: 0.955)
    static let sky = Color(red: 0.84, green: 0.94, blue: 0.99)
    static let background = Color(red: 0.975, green: 0.985, blue: 0.995)
    static let surface = Color.white
    static let field = Color(red: 0.955, green: 0.972, blue: 0.99)
    static let border = Color(red: 0.84, green: 0.89, blue: 0.945)
    static let primaryText = Color(red: 0.10, green: 0.13, blue: 0.18)
    static let secondaryText = Color(red: 0.45, green: 0.50, blue: 0.58)
}

#Preview {
    ContentView()
        .modelContainer(for: [Item.self, CourseEvent.self], inMemory: true)
}
