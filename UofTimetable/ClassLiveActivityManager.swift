//
//  ClassLiveActivityManager.swift
//  UofTimetable
//
//  Starts, updates, and terminates the current class Live Activity.
//

import ActivityKit
import Foundation

enum ClassLiveActivityError: Error {
    case liveActivitiesDisabled
}

@MainActor
final class ClassLiveActivityManager {
    static let shared = ClassLiveActivityManager()

    private init() {}

    private var currentActivity: Activity<ClassActivityAttributes>? {
        Activity<ClassActivityAttributes>.activities.first
    }

    @discardableResult
    func start(
        courseCode: String,
        building: String,
        roomNumber: String,
        meetingType: String = "",
        section: String = "",
        deliveryMode: String = "",
        startTime: Date = Date(),
        endTime: Date,
        compactShowsCountdown: Bool = false,
        compactCueID: Int = 0,
        compactCueMinutes: Int = 5,
        compactCountdownUntil: Date? = nil
    ) async throws -> Activity<ClassActivityAttributes> {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            throw ClassLiveActivityError.liveActivitiesDisabled
        }

        await end(dismissalPolicy: .immediate)

        let attributes = ClassActivityAttributes(
            courseCode: courseCode,
            building: building,
            roomNumber: roomNumber,
            meetingType: meetingType,
            section: section,
            deliveryMode: deliveryMode,
            startTime: startTime,
            endTime: endTime,
            compactShowsCountdown: compactShowsCountdown,
            compactCueID: compactCueID,
            compactCueMinutes: compactCueMinutes,
            compactCountdownUntil: compactCountdownUntil
        )

        let state = attributes.initialState

        return try Activity<ClassActivityAttributes>.request(
            attributes: attributes,
            content: ActivityContent(
                state: state,
                staleDate: staleDate(for: state)
            ),
            pushType: nil
        )
    }

    func update(
        courseCode: String,
        building: String,
        roomNumber: String,
        meetingType: String = "",
        section: String = "",
        deliveryMode: String = "",
        startTime: Date = Date(),
        endTime: Date,
        compactShowsCountdown: Bool = false,
        compactCueID: Int = 0,
        compactCueMinutes: Int = 5,
        compactCountdownUntil: Date? = nil
    ) async {
        guard let activity = currentActivity else { return }

        let state = ClassActivityAttributes.ContentState(
            courseCode: courseCode,
            building: building,
            roomNumber: roomNumber,
            meetingType: meetingType,
            section: section,
            deliveryMode: deliveryMode,
            startTime: startTime,
            endTime: endTime,
            compactShowsCountdown: compactShowsCountdown,
            compactCueID: compactCueID,
            compactCueMinutes: compactCueMinutes,
            compactCountdownUntil: compactCountdownUntil
        )

        await activity.update(
            ActivityContent(
                state: state,
                staleDate: staleDate(for: state)
            )
        )
    }

    func end(dismissalPolicy: ActivityUIDismissalPolicy = .default) async {
        guard let activity = currentActivity else { return }

        await activity.end(
            ActivityContent(
                state: activity.content.state,
                staleDate: Date()
            ),
            dismissalPolicy: dismissalPolicy
        )
    }

    func endIfStartTimePassed(now: Date = .now) async {
        guard let activity = currentActivity else { return }
        guard activity.content.state.startTime <= now else { return }

        await end(dismissalPolicy: .immediate)
    }

    private func staleDate(for state: ClassActivityAttributes.ContentState, now: Date = .now) -> Date {
        if state.compactShowsCountdown {
            return state.compactCountdownUntil ?? state.startTime
        }

        if now < state.compactCueStart {
            return state.compactCueStart
        }

        if state.shouldShowCompactCountdown(now: now) {
            return state.compactCueEnd
        }

        return state.startTime
    }
}
