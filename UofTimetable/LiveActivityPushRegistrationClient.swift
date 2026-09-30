//
//  LiveActivityPushRegistrationClient.swift
//  UofTimetable
//
//  Sends Live Activity push tokens to the backend so APNs can update/end them.
//

import Foundation
import os

@MainActor
final class LiveActivityPushRegistrationClient {
    static let shared = LiveActivityPushRegistrationClient()

    private let liveActivityEndpoint = URL(string: "https://almwdqahpisubekxipbv.supabase.co/functions/v1/register-live-activity")!
    private let pushToStartEndpoint = URL(string: "https://almwdqahpisubekxipbv.supabase.co/functions/v1/register-push-to-start-token")!
    private let scheduleSyncEndpoint = URL(string: "https://almwdqahpisubekxipbv.supabase.co/functions/v1/sync-schedule")!
    private let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFsbXdkcWFocGlzdWJla3hpcGJ2Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODYyODgxNDIsImV4cCI6MjEwMTg2NDE0Mn0.HdUizyk9GInJ7zcWzCSfWB8dmJk7TLB4i_laZouRSxQ"
    private let installIDKey = "utimeInstallID"
    private let isoFormatter = ISO8601DateFormatter()

    private let logger = Logger(subsystem: "com.jamie.UTime", category: "BackendSync")
    private var scheduleTask: Task<Void, Never>?
    private init() {}

    private func send(_ request: URLRequest) async throws {
        var request = request
        request.timeoutInterval = 15
        for attempt in 0..<3 {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                if (200...299).contains(http.statusCode) { return }
                let error = NSError(domain: "UTime.Backend", code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "Server returned HTTP \(http.statusCode)"])
                if http.statusCode != 429 && http.statusCode < 500 { throw error }
                if attempt == 2 { throw error }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if attempt == 2 || (error as NSError).domain == "UTime.Backend" { throw error }
            }
            try await Task.sleep(for: .seconds(attempt == 0 ? 2 : 4))
        }
    }

    func register(
        activityID: String,
        pushToken: String,
        state: ClassActivityAttributes.ContentState
    ) async {
        do {
            var request = URLRequest(url: liveActivityEndpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload(
                activityID: activityID,
                pushToken: pushToken,
                state: state
            ))

            try await send(request)
            UserDefaults.standard.set("Connected", forKey: "liveActivityTokenSyncStatus")
        } catch {
            logger.error("Live Activity registration failed: \(error.localizedDescription)")
            UserDefaults.standard.set("Connection failed — reopen the app to retry", forKey: "liveActivityTokenSyncStatus")
        }
    }

    func registerPushToStartToken(_ token: String) async {
        do {
            var request = URLRequest(url: pushToStartEndpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "install_id": installID,
                "push_to_start_token": token
            ])

            try await send(request)
            UserDefaults.standard.set("Connected", forKey: "pushStartSyncStatus")
        } catch {
            logger.error("Push-to-start registration failed: \(error.localizedDescription)")
            UserDefaults.standard.set("Connection failed — reopen the app to retry", forKey: "pushStartSyncStatus")
        }
    }

    func syncSchedule(
        events: [CourseReminderSnapshot],
        liveActivityLeadMinutes: Int,
        alertCueMinutes: Int
    ) async {
        let previous = scheduleTask
        let task = Task {
            await previous?.value
            await uploadSchedule(events: events, liveActivityLeadMinutes: liveActivityLeadMinutes, alertCueMinutes: alertCueMinutes)
        }
        scheduleTask = task
        await task.value
    }

    private func uploadSchedule(events: [CourseReminderSnapshot], liveActivityLeadMinutes: Int, alertCueMinutes: Int) async {
        UserDefaults.standard.set("Syncing schedule…", forKey: "backendSyncStatus")
        do {
            var request = URLRequest(url: scheduleSyncEndpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "install_id": installID,
                "live_activity_lead_minutes": min(max(liveActivityLeadMinutes, 1), 60),
                "alert_cue_minutes": min(max(alertCueMinutes, 1), 60),
                "events": events.map(schedulePayload(for:))
            ])

            try await send(request)
            UserDefaults.standard.set("Schedule synced", forKey: "backendSyncStatus")
        } catch {
            logger.error("Schedule sync failed: \(error.localizedDescription)")
            UserDefaults.standard.set("Sync failed — reopen the app to retry", forKey: "backendSyncStatus")
        }
    }

    private func payload(
        activityID: String,
        pushToken: String,
        state: ClassActivityAttributes.ContentState
    ) -> [String: Any] {
        [
            "install_id": installID,
            "activity_id": activityID,
            "activity_token": pushToken,
            "course_code": state.courseCode,
            "building": state.building,
            "room_number": state.roomNumber,
            "meeting_type": state.meetingType,
            "section": state.section,
            "delivery_mode": state.deliveryMode,
            "start_time": isoFormatter.string(from: state.startTime),
            "end_time": isoFormatter.string(from: state.endTime),
            "alert_cue_minutes": state.compactCueMinutes
        ]
    }

    private func schedulePayload(for event: CourseReminderSnapshot) -> [String: Any] {
        [
            "event_uid": event.uid,
            "course_code": event.courseCode,
            "building": event.building,
            "room_number": event.roomNumber,
            "meeting_type": event.meetingType,
            "section": event.section,
            "delivery_mode": event.deliveryMode,
            "start_time": isoFormatter.string(from: event.startTime),
            "end_time": isoFormatter.string(from: event.endTime)
        ]
    }

    private var installID: String {
        if let existingID = UserDefaults.standard.string(forKey: installIDKey) {
            return existingID
        }

        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: installIDKey)
        return newID
    }
}
