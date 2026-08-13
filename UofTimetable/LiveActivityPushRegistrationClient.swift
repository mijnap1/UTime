//
//  LiveActivityPushRegistrationClient.swift
//  UofTimetable
//
//  Sends Live Activity push tokens to the backend so APNs can update/end them.
//

import Foundation

final class LiveActivityPushRegistrationClient {
    static let shared = LiveActivityPushRegistrationClient()

    private let liveActivityEndpoint = URL(string: "https://almwdqahpisubekxipbv.supabase.co/functions/v1/register-live-activity")!
    private let pushToStartEndpoint = URL(string: "https://almwdqahpisubekxipbv.supabase.co/functions/v1/register-push-to-start-token")!
    private let scheduleSyncEndpoint = URL(string: "https://almwdqahpisubekxipbv.supabase.co/functions/v1/sync-schedule")!
    private let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFsbXdkcWFocGlzdWJla3hpcGJ2Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODYyODgxNDIsImV4cCI6MjEwMTg2NDE0Mn0.HdUizyk9GInJ7zcWzCSfWB8dmJk7TLB4i_laZouRSxQ"
    private let installIDKey = "utimeInstallID"
    private let isoFormatter = ISO8601DateFormatter()

    private init() {}

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

            let (_, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                print("Live Activity registration failed with status \(httpResponse.statusCode).")
            }
        } catch {
            print("Live Activity registration failed: \(error.localizedDescription)")
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

            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? "No response body"
                print("Push-to-start token registration failed with status \(httpResponse.statusCode): \(body)")
            }
        } catch {
            print("Push-to-start token registration failed: \(error.localizedDescription)")
        }
    }

    func syncSchedule(
        events: [CourseReminderSnapshot],
        liveActivityLeadMinutes: Int,
        alertCueMinutes: Int
    ) async {
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

            let (_, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                print("Schedule sync failed with status \(httpResponse.statusCode).")
            }
        } catch {
            print("Schedule sync failed: \(error.localizedDescription)")
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
