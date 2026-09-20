import Foundation

nonisolated struct ManualMeeting: Identifiable, Sendable {
    var id = UUID()
    var weekday = 2
    var startMinute = 9 * 60
    var endMinute = 10 * 60
    var type = "Lecture"
    var building = ""
    var room = ""
    var isOnline = false
}

nonisolated struct ManualCourse: Identifiable, Sendable {
    var id = UUID()
    var code = ""
    var title = ""
    var meetings = [ManualMeeting()]

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        return calendar
    }

    func occurrences(from firstDate: Date, through lastDate: Date) throws -> [CourseEventDraft] {
        let calendar = Self.calendar
        let first = calendar.startOfDay(for: firstDate)
        let last = calendar.startOfDay(for: lastDate)
        let courseCode = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !courseCode.isEmpty else { throw ValidationError("Enter a course code or name.") }
        guard first <= last else { throw ValidationError("The term end must be on or after its start.") }
        guard let limit = calendar.date(byAdding: .year, value: 1, to: first), last <= limit else {
            throw ValidationError("Choose a term of one year or less.")
        }
        guard !meetings.isEmpty else { throw ValidationError("Add at least one meeting.") }
        var drafts: [CourseEventDraft] = []
        for meeting in meetings {
            guard (1...7).contains(meeting.weekday), (0..<1440).contains(meeting.startMinute),
                  (1..<1440).contains(meeting.endMinute), meeting.endMinute > meeting.startMinute else {
                throw ValidationError("Each meeting must end after it starts on the same day.")
            }
            let building = meeting.isOnline ? "" : meeting.building.trimmingCharacters(in: .whitespacesAndNewlines)
            let room = meeting.isOnline ? "" : meeting.room.trimmingCharacters(in: .whitespacesAndNewlines)
            var day = first
            while day <= last {
                if calendar.component(.weekday, from: day) == meeting.weekday,
                   let start = calendar.date(bySettingHour: meeting.startMinute / 60, minute: meeting.startMinute % 60, second: 0, of: day),
                   let end = calendar.date(bySettingHour: meeting.endMinute / 60, minute: meeting.endMinute % 60, second: 0, of: day) {
                    drafts.append(CourseEventDraft(
                        uid: "manual-\(meeting.id)-\(Int(start.timeIntervalSince1970))",
                        courseCode: courseCode, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                        building: building, roomNumber: room,
                        location: [building, room].filter { !$0.isEmpty }.joined(separator: " "),
                        meetingType: meeting.type, section: "", deliveryMode: meeting.isOnline ? "Online" : "In Person",
                        startTime: start, endTime: end
                    ))
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        guard !drafts.isEmpty else { throw ValidationError("No meetings fall within these term dates.") }
        return drafts.sorted { $0.startTime < $1.startTime }
    }

    struct ValidationError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
