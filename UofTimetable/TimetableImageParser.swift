import Foundation
import Vision
import ImageIO

/// Reads the Course / Day / Time / Location table in ACORN timetable PNG exports.
nonisolated enum TimetableImageParser {
    static func scan(_ data: Data) throws -> [ManualCourse] {
        guard data.count <= 20 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2600
              ] as CFDictionary) else {
            throw ManualCourse.ValidationError("Choose a readable timetable image smaller than 20 MB.")
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-CA"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        let cells = (request.results ?? []).compactMap { observation -> Cell? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return Cell(text: text, bounds: observation.boundingBox)
        }
        return try parse(cells)
    }

    struct Cell {
        let text: String
        let bounds: CGRect
    }

    static func parse(_ cells: [Cell]) throws -> [ManualCourse] {
        guard let courseHeader = cells.first(where: { normalizedHeader($0.text) == "course" }),
              let dayHeader = header("day", near: courseHeader, cells: cells),
              let timeHeader = header("time", near: courseHeader, cells: cells),
              let locationHeader = header("location", near: courseHeader, cells: cells),
              courseHeader.bounds.minX < dayHeader.bounds.minX,
              dayHeader.bounds.minX < timeHeader.bounds.minX,
              timeHeader.bounds.minX < locationHeader.bounds.minX else {
            throw ManualCourse.ValidationError("Include the full Course, Day, Time, and Location table below the timetable. A grid-only screenshot isn't supported yet.")
        }
        let columns = [dayHeader, timeHeader, locationHeader].map { $0.bounds.minX - 0.025 }
        let body = cells.filter { $0.bounds.midY < courseHeader.bounds.minY }
        var rows: [Cell] = []
        for cell in body.filter({ $0.bounds.minX < columns[0] }).sorted(by: { $0.bounds.midY > $1.bounds.midY }) {
            if !rows.contains(where: { abs($0.bounds.midY - cell.bounds.midY) < max($0.bounds.height * 0.65, 0.004) }) {
                rows.append(cell)
            }
        }
        // Missing course text must not silently drop an otherwise visible meeting row.
        guard body.filter({ $0.bounds.minX >= columns[0] }).allSatisfy({ cell in
            rows.contains { abs($0.bounds.midY - cell.bounds.midY) < max($0.bounds.height * 0.65, 0.004) }
        }) else {
            throw ManualCourse.ValidationError("Some table rows couldn't be matched to a course. Include a clear, complete table or enter the schedule manually.")
        }
        guard !rows.isEmpty else { throw ManualCourse.ValidationError("No course rows were found. Try a clearer, uncropped PNG.") }
        var courses: [ManualCourse] = []
        for row in rows {
            let tolerance = max(row.bounds.height * 0.65, 0.004)
            let neighbors = cells.filter { abs($0.bounds.midY - row.bounds.midY) < tolerance }
            func column(_ index: Int) -> String {
                neighbors.filter { $0.bounds.minX >= columns[index] && (index == 2 || $0.bounds.minX < columns[index + 1]) }
                    .sorted { $0.bounds.minX < $1.bounds.minX }.map(\.text).joined(separator: " ")
            }
            let text = neighbors.filter { $0.bounds.minX < columns[0] }
                .sorted { $0.bounds.minX < $1.bounds.minX }.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard let codeRange = text.range(of: #"^[A-Z]{3}[0-9]{3}[HY][0-9]"#, options: .regularExpression),
                  let typeRange = text.range(of: #"(LEC|TUT|PRA|LAB|SEM)\s*$"#, options: .regularExpression) else {
                throw ManualCourse.ValidationError("Couldn't read the course row ‘\(row.text)’. Try a clearer image or enter it manually.")
            }
            let code = String(text[codeRange])
            let type = String(text[typeRange]).trimmingCharacters(in: .whitespaces)
            let days = try weekdays(column(0))
            let times = try timeRange(column(1))
            let location = column(2).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !location.isEmpty else { throw ManualCourse.ValidationError("Couldn't read the location for \(code). Include the full table.") }
            let online = location.lowercased() == "online"
            let parts = location.split(maxSplits: 1, whereSeparator: \.isWhitespace).map(String.init)
            let meetings = days.map { day in
                ManualMeeting(weekday: day, startMinute: times.0, endMinute: times.1,
                              type: ["LEC": "Lecture", "TUT": "Tutorial", "PRA": "Lab", "LAB": "Lab", "SEM": "Seminar"][type]!,
                              building: online ? "" : parts[0], room: online ? "" : (parts.count > 1 ? parts[1] : ""), isOnline: online)
            }
            if let index = courses.firstIndex(where: { $0.code == code }) {
                courses[index].meetings += meetings
            } else {
                courses.append(ManualCourse(code: code, meetings: meetings))
            }
        }
        return courses
    }

    private static func normalizedHeader(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
    }

    private static func header(_ text: String, near row: Cell, cells: [Cell]) -> Cell? {
        cells.first { normalizedHeader($0.text) == text && abs($0.bounds.midY - row.bounds.midY) < row.bounds.height }
    }

    static func weekdays(_ text: String) throws -> [Int] {
        var remaining = text.lowercased().filter { !$0.isWhitespace && $0 != "," && $0 != "/" }
        var days: [Int] = []
        let names = [("monday", 2), ("tuesday", 3), ("wednesday", 4), ("thursday", 5), ("friday", 6), ("saturday", 7), ("sunday", 1), ("mon", 2), ("tue", 3), ("wed", 4), ("thu", 5), ("fri", 6), ("sat", 7), ("sun", 1), ("th", 5), ("tu", 3), ("sa", 7), ("su", 1), ("m", 2), ("w", 4), ("f", 6)]
        while !remaining.isEmpty {
            guard let match = names.first(where: { remaining.hasPrefix($0.0) }) else {
                throw ManualCourse.ValidationError("Couldn't read day ‘\(text)’. Try a clearer image.")
            }
            guard !days.contains(match.1) else { throw ManualCourse.ValidationError("Repeated day ‘\(text)’. Check the timetable image.") }
            days.append(match.1)
            remaining.removeFirst(match.0.count)
        }
        guard !days.isEmpty else { throw ManualCourse.ValidationError("A meeting day is missing.") }
        return days
    }

    static func timeRange(_ text: String) throws -> (Int, Int) {
        // Vision on iPhone can append a border/footnote glyph (for example 11:00t).
        // Allow only trailing marks and one lookalike glyph; keep all digits and AM/PM intact.
        let normalized = text.precomposedStringWithCompatibilityMapping
        let pattern = #"^\s*([0-9]{1,2})\s*:\s*([0-9]{2})\s*[-–—−]\s*([0-9]{1,2})\s*:\s*([0-9]{2})[\s!|†‡'’‘".]*[tIlł]?[\s!|†‡'’‘".]*$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let value = normalized as NSString
        guard let match = regex.firstMatch(in: normalized, range: NSRange(location: 0, length: value.length)) else {
            throw ManualCourse.ValidationError("Couldn't read time ‘\(text)’. Try a clearer image.")
        }
        let numbers = (1...4).map { Int(value.substring(with: match.range(at: $0)))! }
        guard (1...23).contains(numbers[0]), (1...23).contains(numbers[2]), numbers[1] < 60, numbers[3] < 60 else {
            throw ManualCourse.ValidationError("Invalid time ‘\(text)’.")
        }
        // ACORN omits AM/PM. Draft 1–7 as afternoon; the editor requires explicit review.
        func minutes(_ hour: Int, _ minute: Int) -> Int { (hour < 8 ? hour + 12 : hour) * 60 + minute }
        let start = minutes(numbers[0], numbers[1])
        let end = minutes(numbers[2], numbers[3])
        guard end > start else { throw ManualCourse.ValidationError("Ambiguous time ‘\(text)’. Enter this schedule manually with AM/PM.") }
        return (start, end)
    }
}
