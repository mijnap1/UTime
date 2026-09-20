import Foundation

// Run: swiftc UofTimetable/CourseReminderSnapshot.swift UofTimetable/ManualCourse.swift tests/ManualCourseChecks.swift -o /tmp/manual-course-checks && /tmp/manual-course-checks
@main
struct ManualCourseChecks {
    static func main() throws {
        let calendar = ManualCourse.calendar
        func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day))!
        }
        var course = ManualCourse()
        course.code = " csc108h1 "
        course.meetings[0].building = " BA "
        course.meetings[0].room = " 1130 "
        let start = date(2026, 10, 26)
        let end = date(2026, 11, 9)
        let events = try course.occurrences(from: start, through: end)
        assert(events.count == 3, "Term boundaries must be inclusive")
        assert(events.allSatisfy { calendar.component(.hour, from: $0.startTime) == 9 }, "Keep 9 am across DST")
        assert(events[1].startTime.timeIntervalSince(events[0].startTime) == 169 * 3600)
        assert(events[0].courseCode == "CSC108H1" && events[0].location == "BA 1130")
        assert(Set(events.map(\.uid)).count == events.count)
        course.meetings.append(ManualMeeting(weekday: 4, type: "Lab", isOnline: true))
        let multiple = try course.occurrences(from: start, through: end)
        assert(multiple.count == 5)
        assert(multiple.map(\.startTime) == multiple.map(\.startTime).sorted())
        assert(multiple.filter { $0.meetingType == "Lab" }.allSatisfy { $0.deliveryMode == "Online" && $0.location.isEmpty })
        func rejects(_ course: ManualCourse, _ from: Date, _ through: Date) {
            do {
                _ = try course.occurrences(from: from, through: through)
                fatalError("Invalid course was accepted")
            } catch is ManualCourse.ValidationError {} catch { fatalError("Unexpected error: \(error)") }
        }
        rejects(course, end, start)
        rejects(course, start, date(2028, 1, 1))
        rejects(course, date(2026, 10, 27), date(2026, 10, 27))
        course.meetings[0].endMinute = course.meetings[0].startMinute
        rejects(course, start, end)
        course.meetings = []
        rejects(course, start, end)
        course = ManualCourse()
        rejects(course, start, end)
        print("Manual course checks passed: recurrence, DST, metadata, IDs, and validation.")
    }
}
