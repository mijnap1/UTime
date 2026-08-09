//
//  ClassActivityAttributes.swift
//  UofTimetable
//
//  Shared by the app target and the Live Activity widget extension.
//

import ActivityKit
import Foundation

struct ClassActivityAttributes: ActivityAttributes, Hashable {
    struct ContentState: Codable, Hashable {
        var courseCode: String
        var building: String
        var roomNumber: String
        var meetingType: String
        var section: String
        var deliveryMode: String
        var startTime: Date
        var endTime: Date
        var compactShowsCountdown: Bool
        var compactCueID: Int
        var compactCueMinutes: Int
        var compactCountdownUntil: Date?

        var physicalLocation: String {
            [building, roomNumber]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        var compactCourseCode: String {
            displayCourseCode
        }

        var displayCourseCode: String {
            let trimmedCode = courseCode.trimmingCharacters(in: .whitespacesAndNewlines)
            let characters = Array(trimmedCode)

            guard characters.count >= 6 else {
                return trimmedCode
            }

            let subject = characters.prefix(3)
            let number = characters.dropFirst(3).prefix(3)

            if subject.allSatisfy(\.isLetter) && number.allSatisfy(\.isNumber) {
                return String(characters.prefix(6))
            }

            return trimmedCode
        }

        func shouldShowCompactCountdown(now: Date = .now) -> Bool {
            if compactShowsCountdown {
                guard let compactCountdownUntil else { return true }
                return now < compactCountdownUntil
            }

            return now >= compactCueStart && now < compactCueEnd
        }

        var compactCueStart: Date {
            startTime.addingTimeInterval(TimeInterval(-compactCueMinutes * 60))
        }

        var compactCueEnd: Date {
            startTime
        }

        var isAsynchronous: Bool {
            deliveryMode.trimmingCharacters(in: .whitespacesAndNewlines) == "Asynchronous"
        }

        var isOnline: Bool {
            deliveryMode.trimmingCharacters(in: .whitespacesAndNewlines) == "Online"
        }

        var location: String {
            if !physicalLocation.isEmpty {
                return physicalLocation
            }

            let fallback = deliveryMode.trimmingCharacters(in: .whitespacesAndNewlines)
            return fallback.isEmpty ? "No room" : fallback
        }

        var compactLocation: String {
            if !physicalLocation.isEmpty {
                return physicalLocation
            }

            if isAsynchronous {
                return "Async"
            }

            if isOnline {
                return "Online"
            }

            return "No room"
        }

        var expandedLocationTitle: String {
            if !physicalLocation.isEmpty {
                return physicalLocation
            }

            if isAsynchronous {
                return "Async"
            }

            if isOnline {
                return "Online"
            }

            return "No room"
        }

        var expandedLocationSubtitle: String {
            if !physicalLocation.isEmpty {
                return deliveryLabel
            }

            if isAsynchronous {
                return ""
            }

            if isOnline {
                return "Remote"
            }

            return deliveryLabel
        }

        var expandedCourseSubtitle: String {
            isAsynchronous ? "" : meetingCode
        }

        var expandedFooterText: String {
            if isAsynchronous {
                return meetingCode
            }

            return classTimeRange
        }

        var meetingSummary: String {
            let meeting = [meetingType, section]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            if isAsynchronous {
                return meeting
            }

            return [meeting, deliveryMode.trimmingCharacters(in: .whitespacesAndNewlines)]
                .filter { !$0.isEmpty }
                .joined(separator: " • ")
        }

        var meetingCode: String {
            [meetingType, section]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        var deliveryLabel: String {
            deliveryMode.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var classTimeRange: String {
            "\(startTime.formatted(date: .omitted, time: .shortened)) - \(endTime.formatted(date: .omitted, time: .shortened))"
        }

        func countdownTarget(now: Date = .now) -> Date {
            startTime
        }

        func phaseLabel(now: Date = .now) -> String {
            "Starts in"
        }

        func timeSummary(now: Date = .now) -> String {
            "Starts \(startTime.formatted(date: .omitted, time: .shortened))"
        }
    }

    var courseCode: String
    var building: String
    var roomNumber: String
    var meetingType: String
    var section: String
    var deliveryMode: String
    var startTime: Date
    var endTime: Date
    var compactShowsCountdown: Bool
    var compactCueID: Int
    var compactCueMinutes: Int
    var compactCountdownUntil: Date?

    var initialState: ContentState {
        ContentState(
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
    }
}
