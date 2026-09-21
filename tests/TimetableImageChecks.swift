import Foundation

@main
struct TimetableImageChecks {
    static func main() throws {
        let mw = try TimetableImageParser.weekdays("M W")
        assert(mw == [2, 4])
        let ttf = try TimetableImageParser.weekdays("Tu Th F")
        assert(ttf == [3, 5, 6])
        let afternoon = try TimetableImageParser.timeRange("1:00 - 3:00")
        assert(afternoon.0 == 780 && afternoon.1 == 900)
        let noon = try TimetableImageParser.timeRange("11:00 – 1:00")
        assert(noon.0 == 660 && noon.1 == 780)
        for text in ["9:00 - 11:00t", "9:00 - 11:00†", "9:00 - 11:00ł", "9:00 - 11:00!", "9:00 - 11:00|", "9:00 - 11:00t’."] {
            let range = try TimetableImageParser.timeRange(text)
            assert(range.0 == 540 && range.1 == 660, "Phone OCR trailing marks: \(text)")
        }
        func rejects(_ work: () throws -> Void) {
            do { try work(); fatalError("Invalid scan was accepted") }
            catch is ManualCourse.ValidationError {} catch { fatalError("Unexpected error: \(error)") }
        }
        rejects { _ = try TimetableImageParser.parse([]) }
        rejects { _ = try TimetableImageParser.weekdays("T") }
        rejects { _ = try TimetableImageParser.timeRange("9:80 - 11:00") }
        rejects { _ = try TimetableImageParser.timeRange("9:00 - 9:00") }
        rejects { _ = try TimetableImageParser.timeRange("unreadable") }
        for text in ["9:00 - 11:001", "9:00 - 11:00 12:00", "9:00 - 11:00 PM", "9:00 - 11:00 Tuesday", "9:80 - 11:00t"] {
            rejects { _ = try TimetableImageParser.timeRange(text) }
        }
        // A partial row must fail rather than silently importing an incomplete schedule.
        let headers = ["Course", "Day", "Time", "Location"].enumerated().map { index, text in
            TimetableImageParser.Cell(text: text, bounds: CGRect(x: Double(index) * 0.24, y: 0.5, width: 0.1, height: 0.02))
        }
        rejects {
            _ = try TimetableImageParser.parse(headers + [.init(text: "CSC148H1 F LEC", bounds: CGRect(x: 0, y: 0.45, width: 0.2, height: 0.02))])
        }
        let phoneRow = [
            TimetableImageParser.Cell(text: "CSC148H1 F LEC", bounds: CGRect(x: 0, y: 0.45, width: 0.2, height: 0.02)),
            .init(text: "W", bounds: CGRect(x: 0.24, y: 0.45, width: 0.1, height: 0.02)),
            .init(text: "9:00 - 11:00t", bounds: CGRect(x: 0.48, y: 0.45, width: 0.2, height: 0.02)),
            .init(text: "MP 103", bounds: CGRect(x: 0.72, y: 0.45, width: 0.1, height: 0.02))
        ]
        let phoneCourses = try TimetableImageParser.parse(headers + phoneRow)
        assert(phoneCourses.count == 1 && phoneCourses[0].meetings.count == 1)
        assert(phoneCourses[0].meetings[0].startMinute == 540 && phoneCourses[0].meetings[0].endMinute == 660)
        assert(phoneCourses[0].meetings[0].room == "103")
        if let path = CommandLine.arguments.dropFirst().first {
            let courses = try TimetableImageParser.scan(Data(contentsOf: URL(fileURLWithPath: path)))
            assert(courses.map(\.code) == ["AFR280Y1", "CSC148H1", "ESS205H1", "MAT135H1"])
            assert(courses.map { $0.meetings.count } == [2, 3, 1, 3])
            assert(courses[0].meetings.allSatisfy { $0.isOnline && $0.startMinute == 780 && $0.endMinute == 900 })
            let expected: [(String, [(Int, Int, Int, String, String, String)])] = [
                ("CSC148H1", [(4, 540, 660, "MP", "103", "Lecture"), (2, 600, 660, "MS", "2158", "Lecture"), (5, 540, 660, "BA", "3185", "Tutorial")]),
                ("ESS205H1", [(5, 660, 780, "MY", "150", "Lecture")]),
                ("MAT135H1", [(6, 660, 720, "FE", "324", "Tutorial"), (3, 780, 900, "MP", "102", "Lecture"), (5, 780, 840, "MP", "203", "Lecture")])
            ]
            for (code, meetings) in expected {
                let found = courses.first { $0.code == code }!.meetings
                for (actual, desired) in zip(found, meetings) {
                    assert(actual.weekday == desired.0 && actual.startMinute == desired.1 && actual.endMinute == desired.2)
                    assert(actual.building == desired.3 && actual.room == desired.4 && actual.type == desired.5)
                }
            }
            print("Actual sample PNG passed: all 4 courses, 9 weekly meetings, times, types, and locations match.")
        }
        print("Image parser validation checks passed.")
    }
}
