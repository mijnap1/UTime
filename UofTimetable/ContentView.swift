//
//  ContentView.swift
//  UofTimetable
//

import ActivityKit
import PhotosUI
import SwiftData
import SwiftUI
import UIKit

private let appStoreReviewURL = URL(string: "https://apps.apple.com/app/id6801203216?action=write-review")!
private let privacyPolicyURL = URL(string: "https://jamieryu.com/UTime/privacy/index.html")!

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
    @State private var toast: StatusToast?
    @State private var toastTask: Task<Void, Never>?
    @State private var islandTask: Task<Void, Never>?
    @State private var selectedHomeSection = HomeSection.today
    @State private var selectedDay = Calendar.current.startOfDay(for: .now)
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
                homeTabs
                    .overlay(alignment: .top) {
                        if let toast {
                            FloatingStatusToast(toast: toast)
                                .padding(.horizontal, 24)
                                .padding(.top, 6)
                                .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.9, anchor: .top)))
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

    @ViewBuilder
    private var homeTabs: some View {
        if #available(iOS 26.0, *) {
            // System tab bar: iOS draws the Liquid Glass bar and the lens that refracts content as you drag between tabs.
            TabView(selection: $selectedHomeSection) {
                ForEach(HomeSection.allCases) { section in
                    Tab(section.title, systemImage: section.systemImage, value: section) {
                        sectionPage(section)
                    }
                }
            }
            .tint(AppTheme.blue)
        } else {
            NavigationStack {
                sectionPage(selectedHomeSection)
                    .toolbar(.hidden, for: .navigationBar)
                    .safeAreaInset(edge: .bottom) {
                        HomeBottomNavigation(selectedSection: $selectedHomeSection)
                            .padding(.horizontal, 18)
                            .padding(.top, 10)
                            .padding(.bottom, 8)
                            .background {
                                // Soft fade only, so content still scrolls visibly behind the glass bar.
                                LinearGradient(
                                    colors: [
                                        AppTheme.background.opacity(0),
                                        AppTheme.background.opacity(0.35),
                                        AppTheme.background.opacity(0.7)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                                .ignoresSafeArea()
                            }
                    }
            }
        }
    }

    private func sectionPage(_ section: HomeSection) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                sectionContent(section)
            }
            .padding(.horizontal, 18)
            .padding(.top, 24)
            .padding(.bottom, 22)
        }
        .background { AppBackground() }
        .overlay(alignment: .top) {
            // Soft fade under the status bar so scrolled content doesn't collide with the clock.
            GeometryReader { proxy in
                LinearGradient(
                    colors: [AppTheme.background, AppTheme.background.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: proxy.safeAreaInsets.top + 18)
                .ignoresSafeArea(edges: .top)
            }
            .allowsHitTesting(false)
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

    @ViewBuilder
    private func sectionContent(_ section: HomeSection) -> some View {
        switch section {
        case .today:
            HomeHeaderView(
                profileName: studentDisplayName,
                alertsAction: { selectedHomeSection = .alerts },
                profileAction: { selectedHomeSection = .profile }
            )
            .padding(.bottom, 10)

            if courseEvents.isEmpty {
                EmptyNextClassCard(
                    importAction: { isAddingCourse = true },
                    imageAction: { isImportingImage = true }
                )
            } else {
                if let nextEvent = upcomingEvents.first {
                    FocusClassCard(event: nextEvent, action: { selectedHomeSection = .schedule })
                        .padding(.bottom, 8)
                }

                WeekStrip(
                    selectedDay: $selectedDay,
                    classDays: Set(courseEvents.map { Calendar.current.startOfDay(for: $0.startTime) })
                )

                DayTimeline(
                    day: selectedDay,
                    events: courseEvents.filter { Calendar.current.isDate($0.startTime, inSameDayAs: selectedDay) }
                )
                .padding(.top, 8)
            }
        case .schedule:
            ScheduleSection(
                events: courseEvents,
                addAction: { isAddingCourse = true },
                imageAction: { isImportingImage = true },
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
            ? "Schedule updated"
            : "\(drafts.count) class\(drafts.count == 1 ? "" : "es") added")
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
        showToast("Schedule cleared", kind: .removed)
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
                showToast("\(deletedCourseCode) removed", kind: .removed)
            }
        }
    }

    private func applyReminderSettings() {
        clampAlertCueMinutes()

        if isLiveActivityPaused {
            pauseLiveActivities()
            showToast("Class alerts paused", kind: .paused)
        } else {
            restartIslandScheduler()
            syncSchedule()
            showToast("Alert settings saved")
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
            showToast("\(event.courseCode) is on your Lock Screen", kind: .live)
        } catch {
            showToast("Couldn't show your class. Try again.", kind: .error)
        }
    }

    private func showToast(_ message: String, kind: StatusToast.Kind = .done) {
        toastTask?.cancel()

        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            toast = StatusToast(message: message, kind: kind)
        }

        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            guard !Task.isCancelled else { return }

            withAnimation(.spring(response: 0.34, dampingFraction: 0.92)) {
                toast = nil
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

    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var selectionNamespace

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer {
                tabs
                    .glassEffect(.regular.interactive(), in: Capsule())
            }
            .shadow(color: AppTheme.shadow.opacity(isDark ? 0.35 : 0.10), radius: 22, y: 10)
        } else {
            tabs
                .background(.ultraThinMaterial, in: Capsule())
                .background(AppTheme.surface.opacity(isDark ? 0.35 : 0.45), in: Capsule())
                .overlay { GlassRimHighlight(isDark: isDark) }
                .shadow(color: AppTheme.shadow.opacity(isDark ? 0.35 : 0.10), radius: 22, y: 10)
        }
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(HomeSection.allCases) { section in
                tabButton(for: section)
            }
        }
        .padding(6)
        .sensoryFeedback(.selection, trigger: selectedSection)
    }

    private func tabButton(for section: HomeSection) -> some View {
        let isSelected = selectedSection == section

        return Button {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
                selectedSection = section
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 17, weight: .semibold, design: .default))
                    .frame(height: 19)
                    .symbolEffect(.bounce, value: isSelected)

                Text(section.title)
                    .font(AppFont.semibold(11))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .foregroundStyle(isSelected ? AppTheme.blue : AppTheme.primaryText.opacity(isDark ? 0.72 : 0.62))
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background {
                if isSelected {
                    SelectionLens(isDark: isDark)
                        .matchedGeometryEffect(id: "selection", in: selectionNamespace)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The lighter "lens" that sits under the selected tab and slides between tabs.
private struct SelectionLens: View {
    let isDark: Bool

    var body: some View {
        Capsule()
            .fill(AppTheme.blue.opacity(isDark ? 0.22 : 0.12))
            .background(Color.white.opacity(isDark ? 0.06 : 0.55), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isDark ? 0.28 : 0.9),
                                Color.white.opacity(isDark ? 0.04 : 0.25)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.8
                    )
            }
            .shadow(color: AppTheme.blue.opacity(isDark ? 0.25 : 0.12), radius: 8, y: 2)
    }
}

/// Specular edge used by the pre-iOS 26 material fallback to imitate a glass rim.
private struct GlassRimHighlight: View {
    let isDark: Bool

    var body: some View {
        Capsule()
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(isDark ? 0.30 : 0.95),
                        Color.white.opacity(isDark ? 0.06 : 0.35),
                        Color.white.opacity(isDark ? 0.14 : 0.6)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )
    }
}

private struct HomeHeaderView: View {
    let profileName: String
    let alertsAction: () -> Void
    let profileAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            HStack(spacing: 10) {
                Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased())
                    .font(AppFont.semibold(12))
                    .tracking(1.2)
                    .foregroundStyle(AppTheme.secondaryText)

                Spacer(minLength: 0)

                CircleIconButton(systemImage: "bell", accessibilityLabel: "Alerts", action: alertsAction)
                ProfileAvatarButton(name: profileName, action: profileAction)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(greeting)
                    .font(AppFont.regular(32))
                    .foregroundStyle(AppTheme.secondaryText)

                Text(firstName.isEmpty ? "Here's your day" : firstName)
                    .font(AppFont.medium(32))
                    .foregroundStyle(AppTheme.navy)
            }
            .tracking(-0.6)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, 2)
    }

    private var firstName: String {
        profileName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .first
            .map(String.init) ?? ""
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: return "Good morning,"
        case 12..<17: return "Good afternoon,"
        default: return "Good evening,"
        }
    }
}

/// Plain 42pt circle button used in the home header.
private struct CircleIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium, design: .default))
                .foregroundStyle(AppTheme.navy)
                .frame(width: 42, height: 42)
                .background { CardSurface(cornerRadius: 21) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Solid blue card for the class happening now or next. Flat colour, no gradient.
private struct FocusClassCard: View {
    let event: CourseEvent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                content(now: context.date)
            }
        }
        .buttonStyle(.plain)
    }

    private func content(now: Date) -> some View {
        let isLive = event.startTime <= now

        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.white)
                        .frame(width: 6, height: 6)
                    Text(isLive ? "Now" : "Up next")
                }
                .font(AppFont.semibold(12))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.white.opacity(0.18), in: Capsule())

                Spacer()

                Text(isLive ? event.timeLeft(from: now) : event.startsIn(from: now))
                    .font(AppFont.medium(13).monospacedDigit())
                    .opacity(0.85)
            }

            Text(event.courseCode)
                .font(AppFont.medium(32))
                .tracking(-0.5)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 22)

            Text(event.meetingLine)
                .font(AppFont.regular(14))
                .opacity(0.78)
                .lineLimit(1)
                .padding(.top, 1)

            if isLive {
                GeometryReader { proxy in
                    Capsule()
                        .fill(.white.opacity(0.22))
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(.white)
                                .frame(width: max(6, proxy.size.width * event.progress(at: now)))
                        }
                }
                .frame(height: 4)
                .padding(.top, 18)
            }

            HStack(spacing: 18) {
                Label(event.timeRangeText, systemImage: "clock")
                Label(event.roomText, systemImage: event.roomSymbol)
            }
            .labelStyle(CompactLabelStyle())
            .font(AppFont.medium(14).monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.top, 20)
        }
        .foregroundStyle(.white)
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.blue)
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: event.typeStyle.symbol)
                .font(.system(size: 112, weight: .semibold, design: .default))
                .foregroundStyle(.white.opacity(0.08))
                .offset(x: 22, y: 26)
                .accessibilityHidden(true)
        }
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous))
        .shadow(color: AppTheme.blue.opacity(0.25), radius: 22, y: 12)
        .accessibilityElement(children: .combine)
    }
}

/// Mon–Sun row for the current week; dots mark days with classes.
private struct WeekStrip: View {
    @Binding var selectedDay: Date
    let classDays: Set<Date>

    private var days: [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let start = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(days, id: \.self) { day in
                dayCell(day)
            }
        }
        .padding(6)
        .background { CardSurface() }
    }

    private func dayCell(_ day: Date) -> some View {
        let calendar = Calendar.current
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)
        let isToday = calendar.isDateInToday(day)

        return Button {
            withAnimation(.snappy(duration: 0.25)) { selectedDay = day }
        } label: {
            VStack(spacing: 5) {
                Text(day.formatted(.dateTime.weekday(.abbreviated)))
                    .font(AppFont.medium(11))
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : AppTheme.secondaryText)

                Text(day.formatted(.dateTime.day()))
                    .font(AppFont.semibold(17).monospacedDigit())
                    .foregroundStyle(isSelected ? .white : (isToday ? AppTheme.softAccent : AppTheme.navy))

                Circle()
                    .fill(isSelected ? Color.white : AppTheme.softAccent)
                    .frame(width: 4, height: 4)
                    .opacity(classDays.contains(day) ? 1 : 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(AppTheme.softAccent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The selected day's classes as a vertical timeline.
private struct DayTimeline: View {
    let day: Date
    let events: [CourseEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(AppFont.medium(20))
                    .tracking(-0.3)
                    .foregroundStyle(AppTheme.navy)

                Spacer()

                Text(events.count == 1 ? "1 class" : "\(events.count) classes")
                    .font(AppFont.medium(13))
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .padding(.horizontal, 2)

            if events.isEmpty {
                HStack(spacing: 14) {
                    Image(systemName: "sun.max")
                        .font(.system(size: 16, weight: .semibold, design: .default))
                        .foregroundStyle(AppTheme.blue)
                        .frame(width: 40, height: 40)
                        .background(AppTheme.skyTint, in: Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text("No classes")
                            .font(AppFont.semibold(15))
                            .foregroundStyle(AppTheme.navy)
                        Text("Enjoy the free time.")
                            .font(AppFont.regular(13))
                            .foregroundStyle(AppTheme.secondaryText)
                    }

                    Spacer(minLength: 0)
                }
                .padding(16)
                .background { CardSurface() }
            } else {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    VStack(spacing: 0) {
                        ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                            DayTimelineRow(event: event, now: context.date, isLast: index == events.count - 1)
                        }
                    }
                }
            }
        }
    }

    private var title: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide))
    }
}

private struct DayTimelineRow: View {
    let event: CourseEvent
    let now: Date
    let isLast: Bool

    private var isOngoing: Bool { event.startTime <= now && now < event.endTime }
    private var isDone: Bool { event.endTime <= now }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(event.startTime.formatted(date: .omitted, time: .shortened))
                    .font(AppFont.semibold(13).monospacedDigit())
                    .foregroundStyle(isOngoing ? AppTheme.softAccent : AppTheme.navy)

                Text(event.endTime.formatted(date: .omitted, time: .shortened))
                    .font(AppFont.regular(12).monospacedDigit())
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: 60, alignment: .trailing)
            .padding(.top, 15)
            .opacity(isDone ? 0.55 : 1)

            VStack(spacing: 4) {
                dot
                    .padding(.top, 19)

                Rectangle()
                    .fill(AppTheme.border)
                    .frame(width: 1.5)
                    .frame(maxHeight: .infinity)
                    .opacity(isLast ? 0 : 1)
            }
            .frame(width: 20)

            card
                .padding(.bottom, isLast ? 0 : 12)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var dot: some View {
        Circle()
            .fill(isOngoing ? AppTheme.softAccent : AppTheme.surface)
            .overlay {
                if !isOngoing {
                    Circle().strokeBorder(isDone ? AppTheme.border : event.typeStyle.tint, lineWidth: 2)
                }
            }
            .frame(width: 11, height: 11)
            .background {
                if isOngoing {
                    Circle()
                        .fill(AppTheme.softAccent.opacity(0.18))
                        .frame(width: 22, height: 22)
                }
            }
    }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(event.courseCode)
                    .font(AppFont.semibold(16))
                    .foregroundStyle(AppTheme.navy)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                HStack(spacing: 8) {
                    if !event.meetingTag.isEmpty {
                        Text(event.meetingTag)
                            .foregroundStyle(event.typeStyle.tint)
                    }

                    Label(event.roomText, systemImage: event.roomSymbol)
                        .labelStyle(CompactLabelStyle())
                        .foregroundStyle(AppTheme.secondaryText)
                }
                .font(AppFont.medium(12))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            }

            Spacer(minLength: 0)

            if isOngoing {
                NowPill(tint: AppTheme.softAccent)
            } else if isDone {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold, design: .default))
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background {
            CardSurface(cornerRadius: 18)
                .overlay {
                    if isOngoing {
                        shape.strokeBorder(AppTheme.softAccent.opacity(0.45), lineWidth: 1)
                    }
                }
        }
        .opacity(isDone ? 0.55 : 1)
        .accessibilityElement(children: .combine)
    }
}

/// Display helpers shared by the Today page components.
private extension CourseEvent {
    var typeStyle: (tint: Color, symbol: String) {
        let type = meetingType.lowercased()
        if type.hasPrefix("tut") { return (AppTheme.teal, "person.2.fill") }
        if type.hasPrefix("lab") || type.hasPrefix("pra") { return (AppTheme.amber, "flask.fill") }
        if type.hasPrefix("sem") { return (AppTheme.violet, "bubble.left.and.bubble.right.fill") }
        return (AppTheme.softAccent, "graduationcap.fill")
    }

    var meetingTag: String {
        [meetingType, section].filter { !$0.isEmpty }.joined(separator: " ")
    }

    var meetingLine: String {
        [meetingTag, deliveryMode].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var timeRangeText: String {
        "\(startTime.formatted(date: .omitted, time: .shortened)) – \(endTime.formatted(date: .omitted, time: .shortened))"
    }

    var roomText: String {
        let room = [building, roomNumber].filter { !$0.isEmpty }.joined(separator: " ")
        if !room.isEmpty { return room }
        return deliveryMode.isEmpty ? "No room" : deliveryMode
    }

    var roomSymbol: String {
        switch deliveryMode.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "Asynchronous": return "clock"
        case "Online": return "wifi"
        default: return "mappin"
        }
    }

    func progress(at now: Date) -> Double {
        let total = endTime.timeIntervalSince(startTime)
        guard total > 0 else { return 0 }
        return min(max(now.timeIntervalSince(startTime) / total, 0), 1)
    }

    func timeLeft(from now: Date) -> String {
        let minutes = max(1, Int(endTime.timeIntervalSince(now) / 60))
        if minutes < 60 { return "\(minutes) min left" }
        return minutes % 60 == 0 ? "\(minutes / 60)h left" : "\(minutes / 60)h \(minutes % 60)m left"
    }

    func startsIn(from now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(startTime) {
            let minutes = Int(startTime.timeIntervalSince(now) / 60) + 1
            if minutes < 60 { return "in \(minutes) min" }
            return minutes % 60 == 0 ? "in \(minutes / 60)h" : "in \(minutes / 60)h \(minutes % 60)m"
        }
        if calendar.isDateInTomorrow(startTime) { return "Tomorrow" }
        return startTime.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

/// Small avatar in the header (photo or initial); opens the Profile tab.
private struct ProfileAvatarButton: View {
    let name: String
    let action: () -> Void

    @AppStorage(profilePhotoKey) private var photoData = Data()

    var body: some View {
        Button(action: action) {
            ProfilePhotoCircle(
                name: name,
                photoData: photoData,
                initialSize: 16,
                placeholderSize: 15
            ) {
                Circle().fill(AppTheme.softAccent)
            }
            .frame(width: 42, height: 42)
            .shadow(color: AppTheme.softAccent.opacity(0.22), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Profile")
    }
}

/// Shared card sheet: solid surface, hairline edge and a soft two-layer shadow.
struct CardSurface: View {
    var cornerRadius: CGFloat = AppTheme.cardRadius

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(AppTheme.surface)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(AppTheme.border.opacity(0.75), lineWidth: 0.75)
            }
            .shadow(color: AppTheme.shadow.opacity(0.04), radius: 1.5, y: 1)
            .shadow(color: AppTheme.shadow.opacity(0.06), radius: 18, y: 10)
    }
}

/// Flat sky tint for highlighted elements (no gradient inside); adapts to dark mode.
private struct SkySurface<S: InsettableShape>: View {
    let shape: S

    var body: some View {
        shape
            .fill(AppTheme.skyTint)
            .overlay {
                shape.strokeBorder(AppTheme.border.opacity(0.8), lineWidth: 0.75)
            }
    }
}

/// Screen background with a faint brand glow at the top.
struct AppBackground: View {
    var body: some View {
        AppTheme.background
            .overlay(alignment: .top) {
                RadialGradient(
                    colors: [AppTheme.glow.opacity(0.07), .clear],
                    center: .top,
                    startRadius: 0,
                    endRadius: 420
                )
                .frame(height: 520)
            }
            .ignoresSafeArea()
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

/// Avenir Next, built into iOS, so nothing needs bundling.
enum AppFont {
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
            Spacer(minLength: 28)

            VStack(spacing: 0) {
                WelcomeLogoMark()

                Text("UTime")
                    .font(AppFont.medium(46))
                    .tracking(-1)
                    .foregroundStyle(AppTheme.navy)
                    .padding(.top, 34)

                Text("Your U of T timetable,\nready before class.")
                    .font(AppFont.regular(17))
                    .lineSpacing(2)
                    .foregroundStyle(AppTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }

            Spacer(minLength: 40)

            VStack(alignment: .leading, spacing: 22) {
                WelcomeFeatureRow(systemImage: "calendar", title: "Add your courses", detail: "Enter your weekly meetings and rooms.")
                WelcomeFeatureRow(systemImage: "location.fill", title: "Find the room", detail: "Course and room show on the Lock Screen.")
                WelcomeFeatureRow(systemImage: "timer", title: "Arrive on time", detail: "Live cues appear before class.")
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 36)

            VStack(spacing: 14) {
                WelcomeActionButton(action: onGetStarted)

                Text("No account needed.")
                    .font(AppFont.medium(13))
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 24)
    }
}

/// The shield logo on its own (no white tile), with a soft glow behind it.
private struct WelcomeLogoMark: View {
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        ZStack {
            Circle()
                .fill(AppTheme.blue.opacity(isDark ? 0.45 : 0.22))
                .frame(width: 140, height: 140)
                .blur(radius: 40)

            Image("UofTimetableMark")
                .resizable()
                .scaledToFit()
                .frame(width: 132, height: 132)
                // Thin light rim so the navy shield doesn't sink into the dark background.
                .shadow(color: .white.opacity(isDark ? 0.35 : 0), radius: 0.8)
                .shadow(color: AppTheme.shadow.opacity(0.22), radius: 18, y: 10)
        }
        .frame(height: 160)
        .accessibilityHidden(true)
    }
}

private struct WelcomeActionButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text("Get Started")
                    .font(AppFont.semibold(17))

                Image(systemName: "arrow.right")
                    .font(.system(size: 15, weight: .semibold, design: .default))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(AppTheme.blue, in: Capsule())
            .shadow(color: AppTheme.blue.opacity(0.25), radius: 16, y: 8)
        }
        .buttonStyle(PressableButtonStyle())
    }
}

struct PressableButtonStyle: ButtonStyle {
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
        HStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold, design: .default))
                .foregroundStyle(AppTheme.blue)
                .frame(width: 44, height: 44)
                .background { CardSurface(cornerRadius: 22) }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppFont.semibold(16))
                    .foregroundStyle(AppTheme.navy)

                Text(detail)
                    .font(AppFont.regular(14))
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
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

    private let campuses = ["St. George", "UTM", "UTSC"]
    private let years = ["1st year", "2nd year", "3rd year", "4th year", "Graduate"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Button(action: goBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold, design: .default))
                        .foregroundStyle(AppTheme.navy)
                        .frame(width: 42, height: 42)
                        .background { CardSurface(cornerRadius: 21) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")

                OnboardingProgressBar(currentStep: step, totalSteps: 4)

                Text("\(step + 1) of 4")
                    .font(AppFont.medium(13).monospacedDigit())
                    .foregroundStyle(AppTheme.secondaryText)
                    .contentTransition(.numericText())
            }
            .padding(.top, 14)

            VStack(alignment: .leading, spacing: 10) {
                Text(stepTitle)
                    .font(AppFont.medium(34))
                    .tracking(-0.6)
                    .foregroundStyle(AppTheme.navy)
                    .fixedSize(horizontal: false, vertical: true)

                Text(stepSubtitle)
                    .font(AppFont.regular(16))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 52)
            .id(step)
            .transition(.opacity.combined(with: .offset(y: 8)))

            stepContent
                .padding(.top, 30)

            Spacer(minLength: 24)

            OnboardingActionButton(
                title: step == 3 ? "Finish" : "Next",
                systemImage: step == 3 ? "checkmark" : "arrow.right",
                isEnabled: canAdvance,
                action: advance
            )
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 24)
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
                placeholder: "Your first name",
                text: $displayName,
                systemImage: "person.fill"
            )
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

        if step < 3 {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                step += 1
            }
        } else {
            onComplete()
        }
    }

    private func goBack() {
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
                    AppTheme.glow.opacity(0.00),
                    AppTheme.glow.opacity(0.15),
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

/// Thin flat segments, one per step. Each one sweeps in from the left with a spring,
/// and the current step sits slightly taller.
private struct OnboardingProgressBar: View {
    let currentStep: Int
    let totalSteps: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<totalSteps, id: \.self) { index in
                let isCurrent = index == currentStep

                GeometryReader { proxy in
                    Capsule()
                        .fill(AppTheme.navy.opacity(0.10))
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(AppTheme.blue)
                                .frame(width: index <= currentStep ? proxy.size.width : 0)
                        }
                }
                .frame(height: isCurrent ? 6 : 4)
            }
        }
        .frame(height: 6)
        .animation(.spring(response: 0.55, dampingFraction: 0.72), value: currentStep)
        .accessibilityElement()
        .accessibilityLabel("Step \(currentStep + 1) of \(totalSteps)")
    }
}

/// Same pill as the welcome screen's Get Started button.
private struct OnboardingActionButton: View {
    let title: String
    let systemImage: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(AppFont.semibold(17))

                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold, design: .default))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(AppTheme.blue, in: Capsule())
            .shadow(color: isEnabled ? AppTheme.blue.opacity(0.25) : .clear, radius: 16, y: 8)
        }
        .buttonStyle(PressableButtonStyle())
        .opacity(isEnabled ? 1 : 0.4)
        .disabled(!isEnabled)
    }
}

/// White field row shared by the setup steps.
struct OnboardingFieldSurface: View {
    var isActive = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        CardSurface(cornerRadius: 18)
            .overlay {
                if isActive {
                    shape.strokeBorder(AppTheme.blue, lineWidth: 1.5)
                }
            }
    }
}

private struct OnboardingTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let systemImage: String

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold, design: .default))
                .foregroundStyle(AppTheme.blue)
                .frame(width: 20)

            TextField(placeholder, text: $text)
                .font(AppFont.medium(18))
                .foregroundStyle(AppTheme.primaryText)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .focused($isFocused)
                .submitLabel(.next)
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
        .background { OnboardingFieldSurface(isActive: isFocused) }
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        .onAppear { isFocused = true }
        .accessibilityLabel(title)
        .animation(.smooth(duration: 0.2), value: isFocused)
    }
}

private struct ProgramPickerField: View {
    @Binding var selection: String
    let campus: String

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "graduationcap.fill")
                    .font(.system(size: 15, weight: .semibold, design: .default))
                    .foregroundStyle(AppTheme.blue)
                    .frame(width: 20)

                Text(selection.isEmpty ? "Select your program" : selection)
                    .font(AppFont.medium(17))
                    .foregroundStyle(selection.isEmpty ? AppTheme.secondaryText : AppTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                Spacer(minLength: 0)

                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold, design: .default))
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .padding(.horizontal, 18)
            .frame(height: 58)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { OnboardingFieldSurface(isActive: !selection.isEmpty) }
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Program")
        .accessibilityValue(selection.isEmpty ? "Not selected" : selection)
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
    @FocusState private var isSearching: Bool

    private var sections: [ProgramSection] {
        UofTPrograms.filtered(UofTPrograms.sections(for: campus), query: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your program")
                        .font(AppFont.medium(26))
                        .tracking(-0.4)
                        .foregroundStyle(AppTheme.navy)

                    Text(campus)
                        .font(AppFont.regular(14))
                        .foregroundStyle(AppTheme.secondaryText)
                }

                Spacer()

                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold, design: .default))
                        .foregroundStyle(AppTheme.navy)
                        .frame(width: 40, height: 40)
                        .background { CardSurface(cornerRadius: 20) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(.top, 28)

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .semibold, design: .default))
                    .foregroundStyle(AppTheme.secondaryText)

                TextField("Search programs", text: $query)
                    .font(AppFont.medium(16))
                    .foregroundStyle(AppTheme.primaryText)
                    .autocorrectionDisabled()
                    .focused($isSearching)
                    .submitLabel(.search)

                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(AppTheme.secondaryText.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background { OnboardingFieldSurface(isActive: isSearching) }
            .padding(.top, 20)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(sections) { section in
                        Text(section.title.uppercased())
                            .font(AppFont.semibold(12))
                            .tracking(1)
                            .foregroundStyle(AppTheme.secondaryText)
                            .padding(.top, 18)
                            .padding(.bottom, 2)
                            .padding(.horizontal, 4)

                        ForEach(section.programs, id: \.self) { program in
                            programRow(program)
                        }
                    }
                }
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .overlay {
                if sections.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 22)
        .background { AppBackground() }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
    }

    private func programRow(_ program: String) -> some View {
        let isSelected = selection == program

        return Button {
            selection = program
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Text(program)
                    .font(isSelected ? AppFont.semibold(16) : AppFont.medium(16))
                    .foregroundStyle(AppTheme.navy)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                RadioDot(isSelected: isSelected)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { OnboardingFieldSurface(isActive: isSelected) }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Round selection indicator used by the setup choice rows.
struct RadioDot: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(isSelected ? AppTheme.blue : AppTheme.border, lineWidth: 1.5)

            if isSelected {
                Circle()
                    .fill(AppTheme.blue)
                    .padding(5)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

/// Choices with a radio dot: campus as a single column, year as a 2-2-1 grid.
private struct OptionGrid: View {
    let options: [String]
    @Binding var selection: String

    var body: some View {
        VStack(spacing: 10) {
            if options.count == 5 {
                HStack(spacing: 10) {
                    optionRow(options[0])
                    optionRow(options[1])
                }

                HStack(spacing: 10) {
                    optionRow(options[2])
                    optionRow(options[3])
                }

                optionRow(options[4])
            } else {
                ForEach(options, id: \.self) { option in
                    optionRow(option)
                }
            }
        }
    }

    private func optionRow(_ option: String) -> some View {
        let isSelected = selection == option

        return Button {
            withAnimation(.smooth(duration: 0.2)) { selection = option }
        } label: {
            HStack(spacing: 12) {
                Text(option)
                    .font(isSelected ? AppFont.semibold(17) : AppFont.medium(17))
                    .foregroundStyle(AppTheme.navy)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 0)

                RadioDot(isSelected: isSelected)
            }
            .padding(.horizontal, 18)
            .frame(height: 56)
            .background { OnboardingFieldSurface(isActive: isSelected) }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct EmptyNextClassCard: View {
    let importAction: () -> Void
    let imageAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 20) {
                EmptyWeekPreview()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Your week starts here")
                        .font(AppFont.medium(22))
                        .tracking(-0.3)
                        .foregroundStyle(AppTheme.navy)

                    Text("Add your classes to see what's next and where to go.")
                        .font(AppFont.regular(14))
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { CardSurface() }

            AddScheduleCard(importAction: importAction, imageAction: imageAction)
        }
    }
}

/// Faint sample week shown before any classes are added, so the empty Today page has some shape.
private struct EmptyWeekPreview: View {
    private let days = ["Mon", "Tue", "Wed", "Thu", "Fri"]
    /// Each block is (top, height) as a fraction of the grid.
    private let blocks: [[(CGFloat, CGFloat)]] = [
        [(0.04, 0.30), (0.62, 0.26)],
        [(0.22, 0.36)],
        [(0.04, 0.26), (0.50, 0.32)],
        [(0.36, 0.28)],
        [(0.12, 0.38)]
    ]
    private let today = 1
    private let gridHeight: CGFloat = 124

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(days.indices, id: \.self) { day in
                    Text(days[day])
                        .font(day == today ? AppFont.semibold(12) : AppFont.medium(12))
                        .foregroundStyle(day == today ? Color.white : AppTheme.secondaryText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background {
                            if day == today {
                                Capsule().fill(AppTheme.blue)
                            }
                        }
                }
            }

            ZStack(alignment: .top) {
                ForEach(0..<4, id: \.self) { line in
                    Rectangle()
                        .fill(AppTheme.border.opacity(0.7))
                        .frame(height: 0.75)
                        .offset(y: (gridHeight - 0.75) * CGFloat(line) / 3)
                }

                HStack(spacing: 6) {
                    ForEach(days.indices, id: \.self) { day in
                        ZStack(alignment: .top) {
                            Color.clear
                            ForEach(blocks[day].indices, id: \.self) { index in
                                let block = blocks[day][index]
                                classBlock(isToday: day == today && index == 0)
                                    .frame(height: gridHeight * block.1)
                                    .offset(y: gridHeight * block.0)
                            }
                        }
                    }
                }
            }
            .frame(height: gridHeight)
        }
        .accessibilityHidden(true)
    }

    private func classBlock(isToday: Bool) -> some View {
        let tint = isToday ? AppTheme.blue : AppTheme.softAccent

        return HStack(spacing: 0) {
            Capsule()
                .fill(isToday ? Color.white.opacity(0.55) : tint.opacity(0.45))
                .frame(width: 3)
                .padding(.vertical, 6)

            VStack(alignment: .leading, spacing: 4) {
                Capsule().frame(width: 24, height: 4)
                Capsule().frame(width: 14, height: 4)
            }
            .foregroundStyle(isToday ? Color.white.opacity(0.7) : tint.opacity(0.28))
            .padding(.leading, 5)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.leading, 4)
        .background {
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            // Solid base so the hour lines don't show through the light blocks.
            shape.fill(AppTheme.surface)
            shape.fill(isToday ? tint : tint.opacity(0.10))
        }
        .shadow(color: isToday ? AppTheme.blue.opacity(0.25) : .clear, radius: 8, y: 4)
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

    @Environment(\.colorScheme) private var colorScheme

    /// Light mode fills the prominent tile with solid blue so it stands out; dark mode keeps the sky tint.
    private var isSolid: Bool { isProminent && colorScheme == .light }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 18, style: .continuous) }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold, design: .default))
                    .foregroundStyle(isSolid ? .white : AppTheme.blue)
                    .frame(width: 36, height: 36)
                    .background(
                        isSolid ? Color.white.opacity(0.18) : isProminent ? AppTheme.card.opacity(0.8) : AppTheme.blue.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(AppFont.semibold(15))
                        .foregroundStyle(isSolid ? .white : AppTheme.navy)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text(detail)
                        .font(AppFont.regular(12))
                        .foregroundStyle(isSolid ? .white.opacity(0.78) : AppTheme.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background {
                if isSolid {
                    shape
                        .fill(AppTheme.blue)
                        .shadow(color: AppTheme.blue.opacity(0.28), radius: 14, y: 8)
                } else if isProminent {
                    SkySurface(shape: shape)
                        .shadow(color: AppTheme.shadow.opacity(0.08), radius: 14, y: 8)
                } else {
                    shape
                        .fill(AppTheme.field)
                        .overlay { shape.strokeBorder(AppTheme.border.opacity(0.6), lineWidth: 0.75) }
                }
            }
            .contentShape(shape)
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
        VStack(alignment: .leading, spacing: 10) {
            SheetSectionLabel("Live Activities")
                .padding(.top, 6)

            VStack(spacing: 0) {
                liveActivityRow

                SheetDivider()

                VStack(spacing: 14) {
                    AlertValueHeader(title: "Island appears", detail: "Before class starts", value: leadMinutes, tint: AppTheme.blue)

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
                        Text("60 min")
                    }
                    .font(AppFont.medium(12))
                    .foregroundStyle(AppTheme.secondaryText)
                }
                .padding(16)

                SheetDivider()

                VStack(spacing: 14) {
                    AlertValueHeader(title: "Red cue", detail: "The timer turns red", value: alertCueMinutes, tint: AppTheme.red)

                    HStack(spacing: 6) {
                        ForEach(Self.alertOptions, id: \.self) { minutes in
                            cueChip(minutes)
                        }
                    }
                }
                .padding(16)
            }
            .background { CardSurface() }

            SheetFootnote("The red cue can't come before the island appears.")

            Button {
                if isPaused {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                        isPaused = false
                    }
                } else {
                    rescheduleAction()
                }
            } label: {
                Label(isPaused ? "Resume Live Activities" : "Update Live Activity", systemImage: isPaused ? "play.fill" : "arrow.clockwise")
                    .font(AppFont.semibold(15))
                    .foregroundStyle(AppTheme.softAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(AppTheme.softAccent.opacity(0.12), in: Capsule())
            }
            .buttonStyle(PressableButtonStyle())
            .padding(.top, 6)
        }
    }

    private var liveActivityRow: some View {
        HStack(spacing: 12) {
            Image(systemName: isPaused ? "pause.fill" : "sparkles")
                .font(.system(size: 14, weight: .semibold, design: .default))
                .foregroundStyle(isPaused ? AppTheme.secondaryText : AppTheme.blue)
                .frame(width: 36, height: 36)
                .background((isPaused ? AppTheme.secondaryText : AppTheme.blue).opacity(0.12), in: Circle())
                .contentTransition(.symbolEffect(.replace))

            VStack(alignment: .leading, spacing: 2) {
                Text("Live Activities")
                    .font(AppFont.semibold(15))
                    .foregroundStyle(AppTheme.primaryText)

                Text(isPaused ? "Paused. Your schedule stays saved." : "Your next class shows on the island.")
                    .font(AppFont.regular(13))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            Spacer(minLength: 0)

            Toggle("Live Activities", isOn: Binding(
                get: { !isPaused },
                set: { isOn in
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { isPaused = !isOn }
                }
            ))
            .labelsHidden()
            .tint(AppTheme.blue)
        }
        .padding(16)
    }

    private func cueChip(_ minutes: Int) -> some View {
        let isSelected = alertCueMinutes == minutes
        let isEnabled = minutes <= leadMinutes
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        return Button {
            alertCueMinutes = minutes
            rescheduleAction()
        } label: {
            Text("\(minutes)")
                .font((isSelected ? AppFont.semibold(15) : AppFont.medium(15)).monospacedDigit())
                .foregroundStyle(isSelected ? Color.white : AppTheme.primaryText)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background {
                    shape.fill(isSelected ? AppTheme.red : AppTheme.field)
                        .overlay {
                            if !isSelected {
                                shape.strokeBorder(AppTheme.border.opacity(0.8), lineWidth: 0.75)
                            }
                        }
                }
                .contentShape(shape)
        }
        .buttonStyle(PressableButtonStyle())
        .opacity(isEnabled ? 1 : 0.35)
        .disabled(!isEnabled)
        .animation(.smooth(duration: 0.2), value: isSelected)
        .accessibilityLabel("\(minutes) minutes")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Setting title on the left, big minute value on the right.
private struct AlertValueHeader: View {
    let title: String
    let detail: String
    let value: Int
    let tint: Color

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppFont.semibold(15))
                    .foregroundStyle(AppTheme.primaryText)

                Text(detail)
                    .font(AppFont.regular(13))
                    .foregroundStyle(AppTheme.secondaryText)
            }

            Spacer()

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(value)")
                    .font(AppFont.semibold(26).monospacedDigit())
                    .contentTransition(.numericText())

                Text("min")
                    .font(AppFont.medium(13))
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
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Alerts")
                    .font(AppFont.medium(30))
                    .tracking(-0.4)
                    .foregroundStyle(AppTheme.navy)

                Text(isPaused ? "Live Activities are paused" : "Lock Screen and Dynamic Island")
                    .font(AppFont.medium(14))
                    .foregroundStyle(AppTheme.secondaryText)
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 0) {
                HStack(spacing: 24) {
                    AlertRing(leadMinutes: leadMinutes, alertCueMinutes: alertCueMinutes)

                    VStack(alignment: .leading, spacing: 18) {
                        AlertStep(tint: AppTheme.blue, title: "Island appears", detail: "\(leadMinutes) min before class")
                        AlertStep(tint: AppTheme.red, title: "Timer turns red", detail: "\(alertCueMinutes) min before class")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .saturation(isPaused ? 0 : 1)
                .opacity(isPaused ? 0.45 : 1)
                .padding(20)

                SheetDivider(leading: 20)

                nextClassRow
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
            }
            .frame(maxWidth: .infinity)
            .background { CardSurface() }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: isPaused)
    }

    private var nextClassRow: some View {
        HStack(spacing: 8) {
            Text(isPaused ? "Paused" : "Next class")
                .font(AppFont.medium(14))
                .foregroundStyle(AppTheme.secondaryText)

            Spacer(minLength: 8)

            if isPaused {
                Text("Nothing will show")
                    .font(AppFont.medium(14))
                    .foregroundStyle(AppTheme.secondaryText)
            } else if let nextEvent {
                Text(nextEvent.courseCode)
                    .font(AppFont.semibold(14))
                    .foregroundStyle(AppTheme.primaryText)

                Text(nextEvent.startTime.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                    .font(AppFont.medium(14).monospacedDigit())
                    .foregroundStyle(AppTheme.secondaryText)
            } else {
                Text("None coming up")
                    .font(AppFont.medium(14))
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
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

/// The alert window as a countdown ring: blue while the island shows, red for the final minutes.
private struct AlertRing: View {
    let leadMinutes: Int
    let alertCueMinutes: Int

    private let lineWidth: CGFloat = 11
    // Half the space between the two arcs, as a fraction of the ring, so the round caps don't touch.
    private let halfGap: CGFloat = 0.03

    private var split: CGFloat {
        guard leadMinutes > 0 else { return 0 }
        let redFraction = CGFloat(min(alertCueMinutes, leadMinutes)) / CGFloat(leadMinutes)
        return min(max(1 - redFraction, 0), 1 - halfGap * 3)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(AppTheme.field, lineWidth: lineWidth)

            if split > halfGap * 3 {
                Circle()
                    .trim(from: halfGap, to: split - halfGap)
                    .stroke(AppTheme.blue, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }

            Circle()
                .trim(from: split > halfGap * 3 ? split + halfGap : halfGap, to: 1 - halfGap)
                .stroke(AppTheme.red, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))

            VStack(spacing: -2) {
                Text("\(leadMinutes)")
                    .font(AppFont.medium(32).monospacedDigit())
                    .tracking(-0.6)
                    .foregroundStyle(AppTheme.navy)
                    .contentTransition(.numericText())

                Text("min")
                    .font(AppFont.medium(13))
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
        .padding(lineWidth / 2)
        .frame(width: 120, height: 120)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: split)
        .animation(.snappy, value: leadMinutes)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Island appears \(leadMinutes) minutes before class. Timer turns red \(alertCueMinutes) minutes before class.")
    }
}

private struct AlertStep: View {
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(tint)
                .frame(width: 9, height: 9)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(AppFont.semibold(15))
                    .foregroundStyle(AppTheme.primaryText)

                Text(detail)
                    .font(AppFont.regular(13).monospacedDigit())
                    .foregroundStyle(AppTheme.secondaryText)
                    .contentTransition(.numericText())
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
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
            return ("checkmark", "Automatic updates ready", "Class activities can start while UTime is closed. Delivery still depends on iOS and your connection.", AppTheme.green)
        }
        let detail = deviceStatus == "Connected" ? "Syncing your schedule…" : "Waiting for this iPhone to register…"
        return ("arrow.triangle.2.circlepath", "Setting up automatic updates", detail, AppTheme.secondaryText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SheetSectionLabel("Status")
                .padding(.top, 6)

            VStack(spacing: 0) {
                StatusRow(
                    systemImage: isPaused ? "pause.fill" : "dot.radiowaves.left.and.right",
                    title: isPaused ? "Live Activities paused" : "Live Activities on",
                    detail: isPaused ? "Your schedule is saved, but island updates are off." : "\(upcomingCount) upcoming class\(upcomingCount == 1 ? "" : "es") can show on the island.",
                    tint: isPaused ? AppTheme.secondaryText : AppTheme.blue
                )

                SheetDivider(leading: 46)

                StatusRow(
                    systemImage: "exclamationmark",
                    title: "Red cue",
                    detail: "Turns red \(alertCueMinutes) min before class, after the island appears at \(leadMinutes) min.",
                    tint: AppTheme.red
                )

                SheetDivider(leading: 46)

                StatusRow(
                    systemImage: automaticUpdates.systemImage,
                    title: automaticUpdates.title,
                    detail: automaticUpdates.detail,
                    tint: automaticUpdates.tint
                )
            }
            .padding(.leading, 16)
            .background { CardSurface() }

            if !isPaused && !isReady {
                Button(action: retryAction) {
                    Label("Retry connection", systemImage: "arrow.clockwise")
                        .font(AppFont.semibold(15))
                        .foregroundStyle(AppTheme.softAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(AppTheme.softAccent.opacity(0.12), in: Capsule())
                }
                .buttonStyle(PressableButtonStyle())
                .padding(.top, 6)
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
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppFont.semibold(15))
                    .foregroundStyle(AppTheme.primaryText)

                Text(detail)
                    .font(AppFont.regular(13))
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
        .padding(.trailing, 16)
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
        VStack(alignment: .leading, spacing: 0) {
            Text("PROFILE")
                .font(AppFont.semibold(12))
                .tracking(1.2)
                .foregroundStyle(AppTheme.secondaryText)
                .frame(maxWidth: .infinity)
                .frame(height: 42)

            ProfileIdentity(name: trimmedName)
                .frame(maxWidth: .infinity)
                .padding(.top, 26)

            ProfileProgramCard(program: major)
                .padding(.top, 34)

            HStack(spacing: 10) {
                ProfileStatTile(systemImage: "building.columns.fill", value: campus, label: "Campus")
                ProfileStatTile(systemImage: "person.text.rectangle.fill", value: year, label: "Year")
                ProfileStatTile(systemImage: "calendar", value: "\(importedCount)", label: importedCount == 1 ? "Class" : "Classes")
            }
            .padding(.top, 10)

            VStack(spacing: 0) {
                ProfileActionRow(systemImage: "pencil", title: "Edit profile", subtitle: "Name, campus, program and year", action: editAction)

                Rectangle()
                    .fill(AppTheme.border.opacity(0.7))
                    .frame(height: 1)
                    .padding(.leading, 66)

                ProfileActionRow(systemImage: "star.fill", title: "Rate UTime", subtitle: "Leave a quick App Store review", action: { openURL(appStoreReviewURL) })

                Rectangle()
                    .fill(AppTheme.border.opacity(0.7))
                    .frame(height: 1)
                    .padding(.leading, 66)

                ProfileActionRow(systemImage: "hand.raised.fill", title: "Privacy Policy", subtitle: "What UTime keeps and how to delete it", action: { openURL(privacyPolicyURL) })
            }
            .background { CardSurface() }
            .padding(.top, 24)

            Label("Stored on this iPhone only", systemImage: "lock.fill")
                .labelStyle(CompactLabelStyle())
                .font(AppFont.medium(12))
                .foregroundStyle(AppTheme.secondaryText)
                .frame(maxWidth: .infinity)
                .padding(.top, 18)
        }
        .padding(.horizontal, 2)
    }

    private var trimmedName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Big avatar with the name, centred at the top of the page. Campus and year live in the tiles below.
/// Tapping the avatar lets you choose, change or remove a profile photo.
private struct ProfileIdentity: View {
    let name: String

    @AppStorage(profilePhotoKey) private var photoData = Data()
    @State private var pickerItem: PhotosPickerItem?
    @State private var isPickingPhoto = false

    var body: some View {
        VStack(spacing: 20) {
            Menu {
                Button {
                    isPickingPhoto = true
                } label: {
                    Label(photoData.isEmpty ? "Choose photo" : "Change photo", systemImage: "photo.on.rectangle")
                }

                if !photoData.isEmpty {
                    Button(role: .destructive) {
                        photoData = Data()
                    } label: {
                        Label("Remove photo", systemImage: "trash")
                    }
                }
            } label: {
                avatar
            }
            .buttonStyle(.plain)
            .accessibilityLabel(photoData.isEmpty ? "Add profile photo" : "Change profile photo")
            // Badge sits outside the menu label so the menu's lift animation doesn't clip it.
            .overlay(alignment: .bottomTrailing) {
                cameraBadge
                    .offset(x: 2, y: 2)
                    .allowsHitTesting(false)
            }
            .photosPicker(isPresented: $isPickingPhoto, selection: $pickerItem, matching: .images)
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let thumbnail = UIImage(data: data)?.profileThumbnailData() {
                        photoData = thumbnail
                    }
                    pickerItem = nil
                }
            }

            VStack(spacing: 4) {
                Text(name.isEmpty ? "Your profile" : name)
                    .font(AppFont.medium(32))
                    .tracking(-0.6)
                    .foregroundStyle(AppTheme.navy)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text("University of Toronto")
                    .font(AppFont.regular(16))
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var avatar: some View {
        ProfilePhotoCircle(name: name, photoData: photoData, initialSize: 32, placeholderSize: 28) {
            Circle().fill(AppTheme.softAccent)
        }
        .frame(width: 88, height: 88)
        .shadow(color: AppTheme.softAccent.opacity(0.28), radius: 18, y: 10)
        .contentShape(Circle())
    }

    private var cameraBadge: some View {
        Image(systemName: "camera.fill")
            .font(.system(size: 11, weight: .semibold, design: .default))
            .foregroundStyle(AppTheme.softAccent)
            .frame(width: 28, height: 28)
            .background(AppTheme.surface, in: Circle())
            .overlay { Circle().strokeBorder(AppTheme.border.opacity(0.8), lineWidth: 0.75) }
            .shadow(color: AppTheme.shadow.opacity(0.14), radius: 6, y: 2)
    }
}

/// UserDefaults key for the profile photo (a small square JPEG).
private let profilePhotoKey = "studentPhoto"

/// Circle showing the saved profile photo, or the first initial on `background` when there is none.
private struct ProfilePhotoCircle<Background: View>: View {
    let name: String
    let photoData: Data
    let initialSize: CGFloat
    let placeholderSize: CGFloat
    var initialColor: Color = .white
    @ViewBuilder let background: () -> Background

    var body: some View {
        // The initial always sits underneath; the photo fades over it, so swapping never shifts the layout.
        ZStack {
            background()

            if let initial = name.trimmingCharacters(in: .whitespaces).first {
                Text(String(initial).uppercased())
                    .font(AppFont.medium(initialSize))
                    .foregroundStyle(initialColor)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: placeholderSize, weight: .semibold, design: .default))
                    .foregroundStyle(initialColor)
            }

            if let image = UIImage(data: photoData) {
                Color.clear
                    .overlay {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                    .id(photoData)
                    .transition(.opacity)
            }
        }
        .clipShape(Circle())
        .animation(.easeInOut(duration: 0.35), value: photoData)
    }
}

private extension UIImage {
    /// Centre-crops to a square and scales down so the photo stays small in UserDefaults.
    func profileThumbnailData(side: CGFloat = 360) -> Data? {
        let shortest = min(size.width, size.height)
        guard shortest > 0 else { return nil }
        let scale = side / shortest
        let drawSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let square = renderer.image { _ in
            draw(in: CGRect(
                x: (side - drawSize.width) / 2,
                y: (side - drawSize.height) / 2,
                width: drawSize.width,
                height: drawSize.height
            ))
        }
        return square.jpegData(compressionQuality: 0.82)
    }
}

private struct ProfileProgramCard: View {
    let program: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Program")
                    .font(AppFont.medium(13))
                    .foregroundStyle(AppTheme.secondaryText)

                Text(program.isEmpty ? "Not set" : program)
                    .font(AppFont.medium(19))
                    .tracking(-0.2)
                    .foregroundStyle(AppTheme.navy)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Image(systemName: "graduationcap.fill")
                .font(.system(size: 15, weight: .semibold, design: .default))
                .foregroundStyle(AppTheme.blue)
                .frame(width: 40, height: 40)
                .background(AppTheme.blue.opacity(0.10), in: Circle())
                .accessibilityHidden(true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { CardSurface() }
        .accessibilityElement(children: .combine)
    }
}

private struct ProfileStatTile: View {
    let systemImage: String
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold, design: .default))
                .foregroundStyle(AppTheme.blue)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(value.isEmpty ? "—" : value)
                    .font(AppFont.medium(16).monospacedDigit())
                    .foregroundStyle(AppTheme.navy)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(label)
                    .font(AppFont.regular(12))
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { CardSurface(cornerRadius: 18) }
        .accessibilityElement(children: .combine)
    }
}

private struct ProfileActionRow: View {
    let systemImage: String
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold, design: .default))
                    .foregroundStyle(AppTheme.blue)
                    .frame(width: 36, height: 36)
                    .background(AppTheme.blue.opacity(0.10), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(AppFont.semibold(15))
                        .foregroundStyle(AppTheme.navy)

                    Text(subtitle)
                        .font(AppFont.regular(12))
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 10)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold, design: .default))
                    .foregroundStyle(AppTheme.secondaryText.opacity(0.65))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
    }
}

private struct SwipeToDeleteRow<Content: View>: View {
    let content: Content
    let deleteAction: () -> Void

    @State private var offset: CGFloat = 0
    @State private var dragStartOffset: CGFloat = 0
    @State private var isTrackingHorizontalDrag = false

    private let deleteWidth: CGFloat = 82
    private let cornerRadius: CGFloat

    init(cornerRadius: CGFloat = AppTheme.insetRadius, @ViewBuilder content: () -> Content, deleteAction: @escaping () -> Void) {
        self.cornerRadius = cornerRadius
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
                        .font(AppFont.semibold(11))
                }
                .foregroundStyle(.white)
                .frame(width: deleteWidth)
                .frame(maxHeight: .infinity)
                .background(AppTheme.red)
            }
            .buttonStyle(.plain)
            // Hidden at rest so its edge can't bleed past the row's rounded corners.
            .opacity(offset == 0 ? 0 : 1)
            .allowsHitTesting(offset != 0)

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
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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

private struct ScheduleSection: View {
    /// Every saved class, including ones that already ended, so past days still show what happened.
    let events: [CourseEvent]
    let addAction: () -> Void
    let imageAction: () -> Void
    let deleteAction: (CourseEvent) -> Void
    let clearAction: () -> Void

    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    @State private var isConfirmingClear = false

    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        return calendar
    }

    private var weekStart: Date {
        calendar.dateInterval(of: .weekOfYear, for: selectedDay)?.start ?? selectedDay
    }

    private var weekDays: [Date] {
        (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
    }

    private var dayEvents: [CourseEvent] {
        events
            .filter { calendar.isDate($0.startTime, inSameDayAs: selectedDay) }
            .sorted { $0.startTime < $1.startTime }
    }

    var body: some View {
        VStack(spacing: 16) {
            header

            weekStrip

            DayTimelineCard(
                day: selectedDay,
                events: dayEvents,
                hasAnyEvents: !events.isEmpty,
                deleteAction: deleteAction
            )

            AddScheduleCard(importAction: addAction, imageAction: imageAction)

            if !events.isEmpty {
                DestructiveActionButton(
                    title: "Clear Schedule",
                    systemImage: "trash",
                    action: { isConfirmingClear = true }
                )
            }
        }
        .sensoryFeedback(.selection, trigger: selectedDay)
        .alert("Clear schedule?", isPresented: $isConfirmingClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Schedule", role: .destructive, action: clearAction)
        } message: {
            Text("This deletes every saved class from UTime on this device.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Schedule")
                    .font(AppFont.medium(30))
                    .tracking(-0.4)
                    .foregroundStyle(AppTheme.navy)

                Text("Week of \(weekStart.formatted(.dateTime.month(.wide).day()))")
                    .font(AppFont.medium(14))
                    .foregroundStyle(AppTheme.secondaryText)
                    .contentTransition(.numericText())
            }

            Spacer(minLength: 0)

            if !calendar.isDateInToday(selectedDay) {
                Button {
                    select(calendar.startOfDay(for: Date()))
                } label: {
                    Text("Today")
                        .font(AppFont.semibold(13))
                        .foregroundStyle(AppTheme.blue)
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background { CardSurface(cornerRadius: 19) }
                }
                .buttonStyle(PressableButtonStyle())
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }

            circleButton("chevron.left", label: "Previous week") { shiftWeek(by: -1) }
            circleButton("chevron.right", label: "Next week") { shiftWeek(by: 1) }
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
    }

    private var weekStrip: some View {
        HStack(spacing: 7) {
            ForEach(weekDays, id: \.self) { day in
                Button {
                    select(day)
                } label: {
                    ScheduleDayTile(
                        date: day,
                        classCount: events.filter { calendar.isDate($0.startTime, inSameDayAs: day) }.count,
                        isSelected: calendar.isDate(day, inSameDayAs: selectedDay),
                        isToday: calendar.isDateInToday(day),
                        isWeekend: calendar.isDateInWeekend(day)
                    )
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
    }

    private func circleButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold, design: .default))
                .foregroundStyle(AppTheme.navy)
                .frame(width: 38, height: 38)
                .background { CardSurface(cornerRadius: 19) }
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
    }

    private func shiftWeek(by weeks: Int) {
        guard let day = calendar.date(byAdding: .weekOfYear, value: weeks, to: selectedDay) else { return }
        select(day)
    }

    private func select(_ day: Date) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            selectedDay = calendar.startOfDay(for: day)
        }
    }
}

/// Calendar-page style day: a coloured weekday band over the date, with dots for the day's classes.
private struct ScheduleDayTile: View {
    let date: Date
    let classCount: Int
    let isSelected: Bool
    let isToday: Bool
    let isWeekend: Bool

    private var tint: Color { isWeekend ? AppTheme.red : AppTheme.blue }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }

    var body: some View {
        VStack(spacing: 7) {
            VStack(spacing: 0) {
                Text(date.formatted(.dateTime.weekday(.abbreviated)))
                    .font(AppFont.semibold(11))
                    .foregroundStyle(isSelected ? .white : tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(isSelected ? tint : tint.opacity(0.12))

                Text(date.formatted(.dateTime.day()))
                    .font(AppFont.semibold(19).monospacedDigit())
                    .foregroundStyle(isSelected || isWeekend ? tint : AppTheme.primaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
            }
            .background(isSelected ? tint.opacity(0.12) : AppTheme.surface)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(
                    isSelected || isToday ? tint.opacity(0.45) : AppTheme.border.opacity(0.7),
                    lineWidth: isSelected || isToday ? 1.2 : 0.75
                )
            }
            .shadow(color: isSelected ? tint.opacity(0.22) : AppTheme.shadow.opacity(0.06), radius: isSelected ? 10 : 6, y: 4)
            .scaleEffect(isSelected ? 1.05 : 1)

            HStack(spacing: 3) {
                ForEach(0..<min(classCount, 3), id: \.self) { _ in
                    Circle()
                        .fill(tint.opacity(isSelected ? 0.9 : 0.5))
                        .frame(width: 4, height: 4)
                }
            }
            .frame(height: 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(date.formatted(.dateTime.weekday(.wide).month().day())), \(classCount) class\(classCount == 1 ? "" : "es")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct DayTimelineCard: View {
    let day: Date
    let events: [CourseEvent]
    let hasAnyEvents: Bool
    let deleteAction: (CourseEvent) -> Void

    private var calendar: Calendar { .current }
    private var isToday: Bool { calendar.isDateInToday(day) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(AppFont.semibold(20))
                        .foregroundStyle(AppTheme.navy)

                    subtitle(now: context.date)
                        .font(AppFont.regular(13))
                        .foregroundStyle(AppTheme.secondaryText)
                }

                if !hasAnyEvents {
                    EmptyScheduleView()
                } else if events.isEmpty {
                    freeDay
                } else {
                    timeline(now: context.date)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { CardSurface() }
        }
    }

    private func timeline(now: Date) -> some View {
        VStack(spacing: 0) {
            ForEach(events) { event in
                if isToday, showsNowMarker(before: event, now: now) {
                    nowMarker
                }

                TimelineClassRow(
                    event: event,
                    now: now,
                    isLast: event === events.last,
                    deleteAction: { deleteAction(event) }
                )
            }
        }
    }

    /// The "Now" marker sits in the gap between classes; during a class the row itself shows it.
    private func showsNowMarker(before event: CourseEvent, now: Date) -> Bool {
        guard now < event.startTime else { return false }
        guard let index = events.firstIndex(where: { $0 === event }) else { return false }
        return index == 0 || events[index - 1].endTime <= now
    }

    private var nowMarker: some View {
        HStack(spacing: 10) {
            NowPill()
                .frame(width: 56)

            Capsule()
                .fill(AppTheme.blue.opacity(0.35))
                .frame(height: 1.5)
        }
        .padding(.bottom, 12)
    }

    private var freeDay: some View {
        HStack(spacing: 12) {
            Image(systemName: isWeekendDay ? "sun.max.fill" : "cup.and.saucer.fill")
                .font(.system(size: 17, weight: .semibold, design: .default))
                .foregroundStyle(AppTheme.amber)
                .frame(width: 42, height: 42)
                .background(AppTheme.amber.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("No classes")
                    .font(AppFont.semibold(15))
                    .foregroundStyle(AppTheme.primaryText)

                Text("Enjoy the free time.")
                    .font(AppFont.regular(13))
                    .foregroundStyle(AppTheme.secondaryText)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(AppTheme.field, in: RoundedRectangle(cornerRadius: AppTheme.insetRadius, style: .continuous))
    }

    private var isWeekendDay: Bool { calendar.isDateInWeekend(day) }

    private var title: String {
        if isToday { return "Today" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private func subtitle(now: Date) -> Text {
        let total = events.count
        if total == 0 {
            return Text("Nothing scheduled")
        }

        let noun = "class\(total == 1 ? "" : "es")"
        if isToday {
            let finished = events.filter { $0.endTime <= now }.count
            return Text("You've finished ")
                + Text("\(finished)").font(AppFont.semibold(13)).foregroundColor(AppTheme.blue)
                + Text("/\(total)").font(AppFont.semibold(13)).foregroundColor(AppTheme.navy)
                + Text(" \(noun) today")
        }

        return Text("\(total)").font(AppFont.semibold(13)).foregroundColor(AppTheme.blue)
            + Text(" \(noun) scheduled")
    }
}

private struct TimelineClassRow: View {
    let event: CourseEvent
    let now: Date
    let isLast: Bool
    let deleteAction: () -> Void

    private var isOngoing: Bool { event.startTime <= now && now < event.endTime }
    private var isDone: Bool { event.endTime <= now }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 6) {
                if isOngoing {
                    NowPill()
                } else {
                    Text(event.startTime.formatted(.dateTime.hour().minute()))
                        .font(AppFont.semibold(11).monospacedDigit())
                        .foregroundStyle(isDone ? AppTheme.secondaryText.opacity(0.6) : AppTheme.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.vertical, 3)
                }

                Capsule()
                    .fill(isDone || isOngoing ? AppTheme.blue.opacity(0.35) : AppTheme.border)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 56)
            .padding(.top, 12)

            SwipeToDeleteRow {
                TimelineClassCard(event: event, now: now, isOngoing: isOngoing, isDone: isDone)
            } deleteAction: {
                deleteAction()
            }
            .padding(.bottom, isLast ? 0 : 10)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct TimelineClassCard: View {
    let event: CourseEvent
    let now: Date
    let isOngoing: Bool
    let isDone: Bool

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: AppTheme.insetRadius, style: .continuous)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(event.courseCode)
                        .font(AppFont.semibold(16))
                        .foregroundStyle(AppTheme.navy)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    if isDone {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold, design: .default))
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                }

                Text(timeText)
                    .font(AppFont.medium(13).monospacedDigit())
                    .foregroundStyle(isOngoing ? AppTheme.blue : AppTheme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                HStack(spacing: 6) {
                    if !meetingTag.isEmpty {
                        Text(meetingTag)
                            .font(AppFont.semibold(10))
                            .foregroundStyle(style.tint)
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(style.tint.opacity(0.12), in: Capsule())
                    }

                    Label(locationText, systemImage: locationIcon)
                        .labelStyle(CompactLabelStyle())
                        .font(AppFont.medium(12))
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: style.symbol)
                .font(.system(size: 13, weight: .semibold, design: .default))
                .foregroundStyle(style.tint)
                .frame(width: 32, height: 32)
                .background(style.tint.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
        }
        // Dim only the content: the card itself stays opaque so the swipe-to-delete action never shows through.
        .opacity(isDone ? 0.55 : 1)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            shape
                .fill(AppTheme.field)
                .overlay {
                    if isOngoing {
                        shape.strokeBorder(AppTheme.blue.opacity(0.35), lineWidth: 1)
                    }
                }
        }
        .accessibilityElement(children: .combine)
    }

    private var style: (tint: Color, symbol: String) {
        let type = event.meetingType.lowercased()
        if type.hasPrefix("tut") { return (AppTheme.teal, "person.2.fill") }
        if type.hasPrefix("lab") || type.hasPrefix("pra") { return (AppTheme.amber, "flask.fill") }
        if type.hasPrefix("sem") { return (AppTheme.violet, "bubble.left.and.bubble.right.fill") }
        return (AppTheme.blue, "graduationcap.fill")
    }

    private var timeText: String {
        if isOngoing {
            let minutes = max(1, Int(event.endTime.timeIntervalSince(now) / 60))
            if minutes < 60 { return "\(minutes) min remaining" }
            let remainder = minutes % 60
            return remainder == 0 ? "\(minutes / 60)h remaining" : "\(minutes / 60)h \(remainder)m remaining"
        }
        return "\(event.startTime.formatted(date: .omitted, time: .shortened)) – \(event.endTime.formatted(date: .omitted, time: .shortened))"
    }

    private var meetingTag: String {
        [event.meetingType, event.section]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
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

private struct NowPill: View {
    var tint: Color = AppTheme.blue

    var body: some View {
        Text("Now")
            .font(AppFont.semibold(11))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(tint, in: Capsule())
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
                    .font(AppFont.semibold(15))
                    .foregroundStyle(AppTheme.primaryText)

                Text("Add a course or upload your ACORN timetable to see your week here.")
                    .font(AppFont.regular(13))
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

private struct StatusToast {
    enum Kind {
        case done, removed, paused, live, error
    }

    let message: String
    let kind: Kind
}

private struct FloatingStatusToast: View {
    let toast: StatusToast

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 22, style: .continuous) }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold, design: .default))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, tint)

            Text(toast.message)
                .font(AppFont.semibold(14))
                .foregroundStyle(AppTheme.primaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 12)
        .padding(.trailing, 18)
        .padding(.vertical, 10)
        .background { toastBackground }
        .shadow(color: AppTheme.shadow.opacity(0.08), radius: 2, y: 1)
        .shadow(color: AppTheme.shadow.opacity(0.18), radius: 24, y: 12)
        .accessibilityElement(children: .combine)
    }

    /// Mostly opaque frosted surface: clear glass let busy content behind the toast hurt legibility.
    private var toastBackground: some View {
        shape
            .fill(.ultraThinMaterial)
            .overlay { shape.fill(AppTheme.surface.opacity(0.88)) }
            .overlay { shape.strokeBorder(AppTheme.border.opacity(0.6), lineWidth: 0.75) }
    }

    private var symbol: String {
        switch toast.kind {
        case .done, .live: return "checkmark.circle.fill"
        case .removed: return "trash.circle.fill"
        case .paused: return "pause.circle.fill"
        case .error: return "exclamationmark.circle.fill"
        }
    }

    /// Standard status colours (green ok, red removed/failed, amber paused) so the toast reads at a glance.
    private var tint: Color {
        switch toast.kind {
        case .done, .live: return AppTheme.green
        case .removed, .error: return AppTheme.red
        case .paused: return AppTheme.amber
        }
    }
}

private struct ActionPanel<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AppFont.medium(18))
                    .foregroundStyle(AppTheme.navy)

                Text(subtitle)
                    .font(AppFont.regular(13))
                    .foregroundStyle(AppTheme.secondaryText)
            }

            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { CardSurface() }
    }
}

private struct PrimaryActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: AppTheme.insetRadius, style: .continuous) }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(AppFont.semibold(15))
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppTheme.blue)
        .background {
            SkySurface(shape: shape)
                .shadow(color: AppTheme.shadow.opacity(0.08), radius: 12, y: 6)
        }
    }
}

private struct DestructiveActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            Label(title, systemImage: systemImage)
                .font(AppFont.medium(15))
                .frame(maxWidth: .infinity)
                .frame(height: 50)
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppTheme.red)
        .background(AppTheme.red.opacity(0.09), in: RoundedRectangle(cornerRadius: AppTheme.insetRadius, style: .continuous))
    }
}

extension Color {
    init(light: (Double, Double, Double), dark: (Double, Double, Double), darkAlpha: Double = 1) {
        self.init(uiColor: UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor(red: dark.0, green: dark.1, blue: dark.2, alpha: darkAlpha)
            }
            return UIColor(red: light.0, green: light.1, blue: light.2, alpha: 1)
        })
    }
}

enum AppTheme {
    static let cardRadius: CGFloat = 22
    static let insetRadius: CGFloat = 14

    static let navy = Color(light: (0.04, 0.12, 0.26), dark: (0.80, 0.89, 1.0))
    static let deepNavy = Color(light: (0.02, 0.07, 0.17), dark: (0.88, 0.94, 1.0))
    /// Accent. Light mode uses UofT navy (#1E3765); dark mode uses a lifted UofT navy so it still reads on the dark background.
    static let blue = Color(light: (0.118, 0.216, 0.396), dark: (0.24, 0.39, 0.66))
    /// Quieter slate-navy for avatars, the selected day and the Today timeline, so UofT navy isn't everywhere.
    static let softAccent = Color(light: (0.26, 0.36, 0.53), dark: (0.36, 0.50, 0.74))
    /// The original brand blue, kept only for the page background glows so they don't change.
    static let glow = Color(light: (0.05, 0.40, 0.86), dark: (0.10, 0.50, 0.88))
    static let red = Color(light: (0.78, 0.16, 0.16), dark: (0.88, 0.28, 0.28))
    static let teal = Color(light: (0.0, 0.52, 0.55), dark: (0.28, 0.76, 0.78))
    static let amber = Color(light: (0.80, 0.48, 0.0), dark: (0.96, 0.68, 0.26))
    static let green = Color(light: (0.13, 0.60, 0.33), dark: (0.30, 0.80, 0.48))
    static let violet = Color(light: (0.38, 0.30, 0.78), dark: (0.64, 0.57, 0.96))
    static let islandRed = Color(red: 1.0, green: 0.36, blue: 0.34)
    static let skyTint = Color(light: (0.91, 0.95, 1.0), dark: (0.10, 0.17, 0.27))
    static let cream = Color(light: (0.995, 0.985, 0.955), dark: (0.07, 0.09, 0.13))
    static let sky = Color(light: (0.84, 0.94, 0.99), dark: (0.08, 0.17, 0.28))
    static let background = Color(light: (0.955, 0.963, 0.976), dark: (0.04, 0.06, 0.10))
    static let surface = Color(light: (1.0, 1.0, 1.0), dark: (0.12, 0.15, 0.20))
    static let card = Color(light: (1.0, 1.0, 1.0), dark: (0.11, 0.14, 0.19))
    static let highlight = Color(light: (1.0, 1.0, 1.0), dark: (1.0, 1.0, 1.0), darkAlpha: 0.12)
    static let shadow = Color(light: (0.05, 0.11, 0.24), dark: (0.0, 0.0, 0.0))
    static let switchOff = Color(light: (0.70, 0.75, 0.78), dark: (0.30, 0.34, 0.40))
    static let field = Color(light: (0.958, 0.966, 0.978), dark: (0.10, 0.13, 0.18))
    static let border = Color(light: (0.885, 0.905, 0.935), dark: (0.20, 0.26, 0.34))
    static let primaryText = Color(light: (0.06, 0.09, 0.15), dark: (0.94, 0.96, 0.98))
    static let secondaryText = Color(light: (0.42, 0.46, 0.53), dark: (0.62, 0.68, 0.76))
}

#Preview {
    ContentView()
        .modelContainer(for: [Item.self, CourseEvent.self], inMemory: true)
}
