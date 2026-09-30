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

    static let latestPushTokenDefaultsKey = "latestLiveActivityPushToken"
    static let latestActivityIDDefaultsKey = "latestLiveActivityID"

    private init() {}

    private var tokenListenerTasks: [String: Task<Void, Never>] = [:]

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

        if let existing = currentActivity, existing.content.state.courseCode == courseCode,
           existing.content.state.startTime == startTime, existing.content.state.endTime == endTime {
            observePushTokenUpdates(for: existing)
            return existing
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

        let content = ActivityContent(
            state: state,
            staleDate: staleDate(for: state)
        )

        let activity: Activity<ClassActivityAttributes>
        do {
            activity = try Activity<ClassActivityAttributes>.request(
                attributes: attributes,
                content: content,
                pushType: .token
            )
            observePushTokenUpdates(for: activity)
        } catch {
            print("Push-enabled Live Activity failed, falling back to local-only: \(error.localizedDescription)")
            activity = try Activity<ClassActivityAttributes>.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
        }

        return activity
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
        tokenListenerTasks.removeValue(forKey: activity.id)?.cancel()

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
        guard activity.content.state.endTime <= now else { return }

        await end(dismissalPolicy: .immediate)
    }

    private func staleDate(for state: ClassActivityAttributes.ContentState, now: Date = .now) -> Date {
        if now >= state.startTime {
            return state.endTime
        }

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

    func observePushTokenUpdates(for activity: Activity<ClassActivityAttributes>) {
        guard tokenListenerTasks[activity.id] == nil else { return }
        tokenListenerTasks[activity.id] = Task {
            defer { tokenListenerTasks[activity.id] = nil }
            for await tokenData in activity.pushTokenUpdates {
                let token = tokenData.map { String(format: "%02x", $0) }.joined()
                UserDefaults.standard.set(token, forKey: Self.latestPushTokenDefaultsKey)
                UserDefaults.standard.set(activity.id, forKey: Self.latestActivityIDDefaultsKey)

                await LiveActivityPushRegistrationClient.shared.register(
                    activityID: activity.id,
                    pushToken: token,
                    state: activity.content.state
                )
            }
        }
    }
}
