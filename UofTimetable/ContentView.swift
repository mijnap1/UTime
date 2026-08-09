//
//  ContentView.swift
//  UofTimetable
//

import ActivityKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

private let calendarFileType = UTType(filenameExtension: "ics") ?? .data

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CourseEvent.startTime) private var courseEvents: [CourseEvent]
    @AppStorage("reminderLeadMinutes") private var reminderLeadMinutes = 30
    @AppStorage("alertCueMinutes") private var alertCueMinutes = 5

    @State private var isImportingSchedule = false
    @State private var statusMessage = "Import your U of T calendar to get started."
    @State private var islandTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    AppHeaderView()

                    if let nextEvent = upcomingEvents.first {
                        NextClassCard(event: nextEvent)
                    }

                    ImportScheduleCard(
                        importedCount: courseEvents.count,
                        statusMessage: statusMessage,
                        importAction: { isImportingSchedule = true }
                    )

                    ReminderSettingsCard(
                        leadMinutes: $reminderLeadMinutes,
                        alertCueMinutes: $alertCueMinutes
                    ) {
                        applyReminderSettings()
                    }

                    ScheduleListCard(events: upcomingEvents, clearAction: clearSchedule)
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
            .background(AppTheme.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
        .fileImporter(
            isPresented: $isImportingSchedule,
            allowedContentTypes: [calendarFileType],
            allowsMultipleSelection: false,
            onCompletion: handleFileImport
        )
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
    }

    private var upcomingEvents: [CourseEvent] {
        courseEvents.filter { $0.endTime > Date() }
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

            statusMessage = drafts.isEmpty
                ? "No classes were found in that calendar."
                : "Imported \(drafts.count) classes from \(url.lastPathComponent)."
        } catch {
            statusMessage = "Could not import calendar: \(error.localizedDescription)"
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
        }
        statusMessage = "Schedule cleared."
    }

    private func applyReminderSettings() {
        clampAlertCueMinutes()
        restartIslandScheduler()
        statusMessage = "Live Activity timing updated."
    }

    private func restartIslandScheduler() {
        restartIslandScheduler(with: upcomingEvents.map(snapshot(from:)))
    }

    private func restartIslandScheduler(with snapshots: [CourseReminderSnapshot]) {
        islandTask?.cancel()
        let leadMinutes = reminderLeadMinutes

        islandTask = Task {
            await ClassLiveActivityManager.shared.endIfStartTimePassed()
            await runIslandScheduler(
                events: snapshots,
                leadMinutes: leadMinutes
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
            guard !Task.isCancelled, Date() < event.startTime else { continue }

            await startLiveActivity(for: event)
            await switchToCompactCountdownIfNeeded(for: event, leadMinutes: leadMinutes)

            let delayUntilStart = max(0, event.startTime.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(delayUntilStart * 1_000_000_000))
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
            statusMessage = "Dynamic Island is tracking \(event.courseCode)."
        } catch {
            statusMessage = "Could not start Dynamic Island: \(error.localizedDescription)"
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
}

private struct AppHeaderView: View {
    var body: some View {
        HStack(spacing: 12) {
            Image("UofTimetableLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 50, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: AppTheme.navy.opacity(0.10), radius: 12, y: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text("UTime")
                    .font(.system(size: 27, weight: .semibold, design: .default))
                    .foregroundStyle(AppTheme.navy)

                Text("UofT classes, rooms, and live alerts")
                    .font(.system(size: 14, weight: .medium, design: .default))
                    .foregroundStyle(AppTheme.secondaryText)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 2)
    }
}

private struct NextClassCard: View {
    let event: CourseEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Next class")
                    .font(.system(size: 13, weight: .semibold, design: .default))
                    .foregroundStyle(AppTheme.blue)

                Spacer()

                Text(event.startTime.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 15, weight: .semibold, design: .default).monospacedDigit())
                    .foregroundStyle(AppTheme.navy)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(event.courseCode)
                    .font(.system(size: 30, weight: .semibold, design: .default))
                    .foregroundStyle(AppTheme.navy)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Text(eventSubtitle)
                    .font(.system(size: 14, weight: .medium, design: .default))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            HStack(spacing: 10) {
                Label(locationLabel, systemImage: locationIcon)
                    .font(.system(size: 15, weight: .semibold, design: .default))
                    .foregroundStyle(AppTheme.navy)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(AppTheme.navy.opacity(0.07), in: Capsule())

                Spacer(minLength: 0)

                Text(event.startTime.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 13, weight: .medium, design: .default))
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
        [event.meetingType, event.section, event.deliveryMode]
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

private struct ImportScheduleCard: View {
    let importedCount: Int
    let statusMessage: String
    let importAction: () -> Void

    var body: some View {
        ActionPanel(title: "Import Schedule", subtitle: "Use the .ics file from your U of T timetable") {
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

                StatusCard(message: statusMessage)
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
                    .font(.system(size: 13, weight: .semibold, design: .default))
                    .foregroundStyle(AppTheme.primaryText)

                Text(text)
                    .font(.system(size: 13, weight: .regular, design: .default))
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
    let rescheduleAction: () -> Void

    var body: some View {
        ActionPanel(title: "Live Activity Settings", subtitle: "Choose when the lock screen and island appear") {
            VStack(spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Before class")
                        .font(.system(size: 15, weight: .medium, design: .default))
                        .foregroundStyle(AppTheme.primaryText)

                    Spacer()

                    Text("\(leadMinutes) min")
                        .font(.system(size: 20, weight: .semibold, design: .default).monospacedDigit())
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
                .font(.system(size: 12, weight: .medium, design: .default))
                .foregroundStyle(AppTheme.secondaryText)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Red alert cue")
                            .font(.system(size: 15, weight: .medium, design: .default))
                            .foregroundStyle(AppTheme.primaryText)

                        Spacer()

                        Text("\(alertCueMinutes) min")
                            .font(.system(size: 15, weight: .semibold, design: .default).monospacedDigit())
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
                        .font(.system(size: 12, weight: .regular, design: .default))
                        .foregroundStyle(AppTheme.secondaryText)
                }
                .padding(.top, 2)

                SecondaryActionButton(
                    title: "Update Live Activity",
                    systemImage: "timer",
                    action: rescheduleAction
                )
            }
        }
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
                .font(.system(size: 13, weight: .semibold, design: .default).monospacedDigit())
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

private struct ScheduleListCard: View {
    let events: [CourseEvent]
    let clearAction: () -> Void

    var body: some View {
        ActionPanel(title: "Upcoming Classes", subtitle: subtitle) {
            if events.isEmpty {
                EmptyScheduleView()
            } else {
                VStack(spacing: 10) {
                    ForEach(events.prefix(12)) { event in
                        ClassRow(event: event)
                    }

                    DestructiveActionButton(
                        title: "Clear Schedule",
                        systemImage: "trash",
                        action: clearAction
                    )
                    .padding(.top, 4)
                }
            }
        }
    }

    private var subtitle: String {
        events.isEmpty ? "Imported classes will appear here" : "\(events.count) future classes imported"
    }
}

private struct EmptyScheduleView: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 17, weight: .medium, design: .default))
                .foregroundStyle(AppTheme.blue)

            Text("No classes imported yet")
                .font(.system(size: 14, weight: .regular, design: .default))
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
                    .font(.system(size: 16, weight: .semibold, design: .default))
                    .foregroundStyle(AppTheme.navy)
                    .lineLimit(1)

                Text(eventSubtitle)
                    .font(.system(size: 13, weight: .regular, design: .default))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 5) {
                Text(event.startTime.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 13, weight: .medium, design: .default))
                    .foregroundStyle(AppTheme.primaryText)
                    .multilineTextAlignment(.trailing)

                if !eventLocation.isEmpty {
                    Text(eventLocation)
                        .font(.system(size: 13, weight: .medium, design: .default))
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
        [event.meetingType, event.section, event.deliveryMode]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private var eventLocation: String {
        [event.building, event.roomNumber]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

private struct StatusCard: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(AppTheme.blue)
                .frame(width: 7, height: 7)

            Text(message)
                .font(.system(size: 13, weight: .medium, design: .default))
                .foregroundStyle(AppTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(AppTheme.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                    .font(.system(size: 18, weight: .semibold, design: .default))
                    .foregroundStyle(AppTheme.navy)

                Text(subtitle)
                    .font(.system(size: 13, weight: .regular, design: .default))
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
                .font(.system(size: 15, weight: .semibold, design: .default))
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
                .font(.system(size: 15, weight: .medium, design: .default))
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
                .font(.system(size: 15, weight: .medium, design: .default))
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
    static let blue = Color(red: 0.0, green: 0.37, blue: 0.70)
    static let red = Color(red: 0.78, green: 0.16, blue: 0.16)
    static let background = Color(red: 0.965, green: 0.98, blue: 0.995)
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
