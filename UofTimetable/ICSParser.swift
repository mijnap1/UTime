//
//  ICSParser.swift
//  UofTimetable
//

import Foundation

enum ICSParser {
    nonisolated static func parse(_ text: String) -> [CourseEventDraft] {
        let lines = unfold(text)
        var events: [EventFields] = []
        var currentEvent: EventFields?

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
                var event = currentEvent ?? [:]
                event[name.uppercased(), default: []].append(unescape(String(parts[1])))
                currentEvent = event
            }
        }

        return events.flatMap(makeDrafts(from:))
            .sorted { $0.startTime < $1.startTime }
    }

    private typealias EventFields = [String: [String]]

    private struct ParsedICalDate {
        let date: Date
        let isDateOnly: Bool
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

    private nonisolated static func makeDrafts(from fields: EventFields) -> [CourseEventDraft] {
        guard
            let startRaw = fields.firstValue(for: "DTSTART"),
            let startTime = parseDate(startRaw)
        else { return [] }

        let endTime = fields.firstValue(for: "DTEND").flatMap(parseDate) ?? startTime.addingTimeInterval(50 * 60)
        let duration = max(endTime.timeIntervalSince(startTime), 0)
        let title = fields.firstValue(for: "SUMMARY") ?? "Class"
        let location = fields.firstValue(for: "LOCATION") ?? ""
        let metadata = parseMetadata(title: title, location: location)
        let uid = fields.firstValue(for: "UID") ?? "\(title)-\(startTime.timeIntervalSince1970)"
        let startTimes = expandedStartTimes(from: fields, startTime: startTime)
        let needsOccurrenceUID = fields.firstValue(for: "RRULE") != nil || !fields.values(for: "RDATE").isEmpty || startTimes.count > 1

        return startTimes.map { occurrenceStart in
            CourseEventDraft(
                uid: needsOccurrenceUID ? "\(uid)-\(Int(occurrenceStart.timeIntervalSince1970))" : uid,
                courseCode: metadata.courseCode,
                title: title,
                building: metadata.building,
                roomNumber: metadata.roomNumber,
                location: location,
                meetingType: metadata.meetingType,
                section: metadata.section,
                deliveryMode: metadata.deliveryMode,
                startTime: occurrenceStart,
                endTime: occurrenceStart.addingTimeInterval(duration)
            )
        }
    }

    private nonisolated static func expandedStartTimes(from fields: EventFields, startTime: Date) -> [Date] {
        let rrule = fields.firstValue(for: "RRULE").map(parseRecurrenceRule)
        var startTimes: [Date]

        if rrule?["FREQ"] == "WEEKLY" {
            startTimes = expandWeeklyRecurrence(rule: rrule ?? [:], startTime: startTime)
        } else {
            startTimes = [startTime]
        }

        let rdates = fields.values(for: "RDATE")
            .flatMap(parseDateList)
            .compactMap { dateOnOriginalTime($0, originalStart: startTime) }
        startTimes.append(contentsOf: rdates)

        let exdates = fields.values(for: "EXDATE").flatMap(parseDateList)
        return uniqueSorted(startTimes)
            .filter { !isExcluded($0, by: exdates) }
    }

    private nonisolated static func expandWeeklyRecurrence(rule: [String: String], startTime: Date) -> [Date] {
        let calendar = Calendar.current
        let interval = max(Int(rule["INTERVAL"] ?? "") ?? 1, 1)
        let count = Int(rule["COUNT"] ?? "")
        let until = rule["UNTIL"].flatMap(parseICalDate)
        let weekdays = parseWeekdays(rule["BYDAY"]) ?? [calendar.component(.weekday, from: startTime)]
        let startTimeParts = calendar.dateComponents([.hour, .minute, .second], from: startTime)
        let baseWeekStart = calendar.dateInterval(of: .weekOfYear, for: startTime)?.start ?? startTime
        let fallbackUntil = calendar.date(byAdding: .year, value: 1, to: startTime) ?? startTime
        var occurrences: [Date] = []
        var weekOffset = 0

        while occurrences.count < (count ?? 500) {
            guard
                let weekStart = calendar.date(byAdding: .weekOfYear, value: weekOffset, to: baseWeekStart),
                until != nil || weekStart <= fallbackUntil
            else { break }

            var generatedPastUntil = false

            for weekday in weekdays.sorted() {
                var components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: weekStart)
                components.weekday = weekday
                components.hour = startTimeParts.hour
                components.minute = startTimeParts.minute
                components.second = startTimeParts.second

                guard let occurrence = calendar.date(from: components), occurrence >= startTime else { continue }
                if let until, isAfter(occurrence, limit: until) {
                    generatedPastUntil = true
                    continue
                }

                occurrences.append(occurrence)
                if let count, occurrences.count >= count {
                    return uniqueSorted(occurrences)
                }
            }

            if generatedPastUntil {
                break
            }

            weekOffset += interval
        }

        return uniqueSorted(occurrences)
    }

    private nonisolated static func parseDate(_ rawValue: String) -> Date? {
        parseICalDate(rawValue)?.date
    }

    private nonisolated static func parseICalDate(_ rawValue: String) -> ParsedICalDate? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if value.hasSuffix("Z") {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            return formatter.date(from: value).map { ParsedICalDate(date: $0, isDateOnly: false) }
        }

        let dateTimeFormatter = DateFormatter()
        dateTimeFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateTimeFormatter.timeZone = .current
        dateTimeFormatter.dateFormat = "yyyyMMdd'T'HHmmss"
        if let date = dateTimeFormatter.date(from: value) {
            return ParsedICalDate(date: date, isDateOnly: false)
        }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = .current
        dateFormatter.dateFormat = "yyyyMMdd"
        return dateFormatter.date(from: value).map { ParsedICalDate(date: $0, isDateOnly: true) }
    }

    private nonisolated static func parseDateList(_ rawValue: String) -> [ParsedICalDate] {
        rawValue
            .split(separator: ",")
            .compactMap { parseICalDate(String($0)) }
    }

    private nonisolated static func parseRecurrenceRule(_ rawValue: String) -> [String: String] {
        rawValue.split(separator: ";").reduce(into: [:]) { result, part in
            let pieces = part.split(separator: "=", maxSplits: 1)
            guard pieces.count == 2 else { return }
            result[String(pieces[0]).uppercased()] = String(pieces[1]).uppercased()
        }
    }

    private nonisolated static func parseWeekdays(_ rawValue: String?) -> [Int]? {
        guard let rawValue else { return nil }

        let weekdaysByToken = [
            "SU": 1,
            "MO": 2,
            "TU": 3,
            "WE": 4,
            "TH": 5,
            "FR": 6,
            "SA": 7
        ]
        let weekdays = rawValue
            .split(separator: ",")
            .compactMap { weekdaysByToken[String($0.suffix(2)).uppercased()] }

        return weekdays.isEmpty ? nil : weekdays
    }

    private nonisolated static func dateOnOriginalTime(_ parsedDate: ParsedICalDate, originalStart: Date) -> Date? {
        guard parsedDate.isDateOnly else { return parsedDate.date }

        let calendar = Calendar.current
        let dateParts = calendar.dateComponents([.year, .month, .day], from: parsedDate.date)
        let timeParts = calendar.dateComponents([.hour, .minute, .second], from: originalStart)
        return calendar.date(from: DateComponents(
            year: dateParts.year,
            month: dateParts.month,
            day: dateParts.day,
            hour: timeParts.hour,
            minute: timeParts.minute,
            second: timeParts.second
        ))
    }

    private nonisolated static func uniqueSorted(_ dates: [Date]) -> [Date] {
        var seen = Set<Int>()

        return dates
            .sorted()
            .filter { date in
                seen.insert(Int(date.timeIntervalSince1970)).inserted
            }
    }

    private nonisolated static func isExcluded(_ date: Date, by exclusions: [ParsedICalDate]) -> Bool {
        exclusions.contains { exclusion in
            if exclusion.isDateOnly {
                Calendar.current.isDate(date, inSameDayAs: exclusion.date)
            } else {
                abs(date.timeIntervalSince(exclusion.date)) < 1
            }
        }
    }

    private nonisolated static func isAfter(_ date: Date, limit: ParsedICalDate) -> Bool {
        if limit.isDateOnly {
            !Calendar.current.isDate(date, inSameDayAs: limit.date) && date > limit.date
        } else {
            date > limit.date
        }
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
        if searchableText.contains("asynchronous") || searchableText.contains("async") {
            deliveryMode = "Asynchronous"
        } else if searchableText.contains("synchronous") || searchableText.contains("sync") {
            deliveryMode = "Online"
        } else if searchableText.contains("online") || searchableText.contains("remote") {
            deliveryMode = "Online"
        } else if cleanLocation.isEmpty {
            deliveryMode = "Asynchronous"
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

private extension Dictionary where Key == String, Value == [String] {
    nonisolated func firstValue(for key: String) -> String? {
        self[key]?.first
    }

    nonisolated func values(for key: String) -> [String] {
        self[key] ?? []
    }
}
