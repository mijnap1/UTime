//
//  PushToStartTokenManager.swift
//  UofTimetable
//
//  Registers ActivityKit push-to-start tokens for server-started Live Activities.
//

import ActivityKit
import Foundation

@MainActor
final class PushToStartTokenManager {
    static let shared = PushToStartTokenManager()

    static let latestTokenDefaultsKey = "latestPushToStartToken"

    private var listenerTask: Task<Void, Never>?
    private var activityUpdatesTask: Task<Void, Never>?
    private var observedActivityIDs = Set<String>()

    private init() {}

    func startListening() {
        startPushToStartTokenListener()
        startActivityUpdatesListener()
    }

    private func startPushToStartTokenListener() {
        guard listenerTask == nil else { return }

        listenerTask = Task {
            for await tokenData in Activity<ClassActivityAttributes>.pushToStartTokenUpdates {
                let token = tokenData.map { String(format: "%02x", $0) }.joined()
                UserDefaults.standard.set(token, forKey: Self.latestTokenDefaultsKey)
                print("Push-to-start token updated: \(token)")

                await LiveActivityPushRegistrationClient.shared.registerPushToStartToken(token)
            }
        }
    }

    private func startActivityUpdatesListener() {
        guard activityUpdatesTask == nil else { return }

        for activity in Activity<ClassActivityAttributes>.activities {
            observeActivityIfNeeded(activity)
        }

        activityUpdatesTask = Task {
            for await activity in Activity<ClassActivityAttributes>.activityUpdates {
                self.observeActivityIfNeeded(activity)
            }
        }
    }

    private func observeActivityIfNeeded(_ activity: Activity<ClassActivityAttributes>) {
        guard observedActivityIDs.insert(activity.id).inserted else { return }
        ClassLiveActivityManager.shared.observePushTokenUpdates(for: activity)
    }
}
