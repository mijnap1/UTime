//
//  ICSParser.swift
//  UofTimetable
//

import Foundation

enum ICSParser {
    nonisolated static func parse(_ text: String) -> [CourseEventDraft] {
        let lines = unfold(text)
        var events: [[String: String]] = []
        var currentEvent: [String: String]?

        for line in lines {
            if line == "BEGIN:VEVENT" {
                currentEvent = [:]
            } else if line == "END:VEVENT" {
                if let currentEvent {
                    events.append(currentEvent)
                }
                currentEvent = nil
            } else if currentEvent != nil {
                let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }

                let name = parts[0].split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
                currentEvent?[name.uppercased()] = unescape(String(parts[1]))
            }
        }

        return events.compactMap(makeDraft(from:))
            .sorted { $0.startTime < $1.startTime }
    }

    private nonisolated static func unfold(_ text: String) -> [String] {
        var result: [String] = []

        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix(" ") || line.hasPrefix("\t"), !result.isEmpty {
                result[result.count - 1] += String(line.dropFirst())
            } else {
                result.append(line)
            }
        }

        return result
    }

    private nonisolated static func makeDraft(from fields: [String: String]) -> CourseEventDraft? {
        guard
            let startRaw = fields["DTSTART"],
            let startTime = parseDate(startRaw)
        else { return nil }

        let endTime = fields["DTEND"].flatMap(parseDate) ?? startTime.addingTimeInterval(50 * 60)
        let title = fields["SUMMARY"] ?? "Class"
        let location = fields["LOCATION"] ?? ""
        let metadata = parseMetadata(title: title, location: location)
        let uid = fields["UID"] ?? "\(title)-\(startTime.timeIntervalSince1970)"

        return CourseEventDraft(
            uid: uid,
            courseCode: metadata.courseCode,
            title: title,
            building: metadata.building,
            roomNumber: metadata.roomNumber,
            location: location,
            meetingType: metadata.meetingType,
            section: metadata.section,
            deliveryMode: metadata.deliveryMode,
            startTime: startTime,
            endTime: endTime
        )
    }

    private nonisolated static func parseDate(_ rawValue: String) -> Date? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if value.hasSuffix("Z") {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            return formatter.date(from: value)
        }

        let dateTimeFormatter = DateFormatter()
        dateTimeFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateTimeFormatter.timeZone = .current
        dateTimeFormatter.dateFormat = "yyyyMMdd'T'HHmmss"
        if let date = dateTimeFormatter.date(from: value) {
            return date
        }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = .current
        dateFormatter.dateFormat = "yyyyMMdd"
        return dateFormatter.date(from: value)
    }

    private nonisolated static func parseMetadata(title: String, location: String) -> (
        courseCode: String,
        building: String,
        roomNumber: String,
        meetingType: String,
        section: String,
        deliveryMode: String
    ) {
        let titleParts = title
            .replacingOccurrences(of: "\\,", with: ",")
            .split(separator: " ")
            .map(String.init)

        let courseCode = titleParts.first(where: { $0.range(of: #"^[A-Z]{3}[A-Z0-9]{2,8}"#, options: .regularExpression) != nil }) ?? titleParts.first ?? "Class"
        let meetingType = titleParts.first(where: { ["LEC", "TUT", "PRA", "LAB", "SEM"].contains($0.uppercased()) }) ?? ""
        let section = titleParts.first(where: { $0.range(of: #"^\d{4}$"#, options: .regularExpression) != nil }) ?? ""

        let cleanLocation = location.trimmingCharacters(in: .whitespacesAndNewlines)
        let locationParts = cleanLocation.split(separator: " ").map(String.init)
        let building = locationParts.first ?? ""
        let roomNumber = locationParts.dropFirst().joined(separator: " ")

        let searchableText = "\(title) \(location)".lowercased()
        let deliveryMode: String
        if searchableText.contains("asynchronous") || searchableText.contains("async") || cleanLocation.isEmpty {
            deliveryMode = "Asynchronous"
        } else if searchableText.contains("online") || searchableText.contains("remote") {
            deliveryMode = "Online"
        } else {
            deliveryMode = "In Person"
        }

        return (courseCode, building, roomNumber, meetingType, section, deliveryMode)
    }

    private nonisolated static func unescape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
