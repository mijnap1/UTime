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
        func recognize(_ image: CGImage) throws -> [Cell] {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-CA"]
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap { observation in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                return Cell(text: text, bounds: observation.boundingBox)
            }
        }
        var cells = try recognize(image)
        if let header = cells.first(where: { normalizedHeader($0.text) == "course" }),
           let bottom = tableBody(cells, header: header).map({ $0.bounds.minY }).min() {
            let top = min(1, header.bounds.maxY + header.bounds.height)
            let lower = max(0, bottom - header.bounds.height)
            let rect = CGRect(x: 0, y: (1 - top) * Double(image.height), width: Double(image.width), height: (top - lower) * Double(image.height)).integral
            if let cropped = image.cropping(to: rect) {
                let rescanned = try recognize(cropped).map { cell in
                    Cell(text: cell.text, bounds: CGRect(x: cell.bounds.minX,
                        y: 1 - rect.maxY / Double(image.height) + cell.bounds.minY * rect.height / Double(image.height),
                        width: cell.bounds.width, height: cell.bounds.height * rect.height / Double(image.height)))
                }
                if rescanned.contains(where: { normalizedHeader($0.text) == "course" }) {
                    cells = cells.filter { $0.bounds.minY > top } + rescanned
                }
            }
        }
        // Single-letter days can disappear in full-image OCR. Retry only empty day cells.
        if let course = cells.first(where: { normalizedHeader($0.text) == "course" }),
           let day = header("day", near: course, cells: cells),
           let time = header("time", near: course, cells: cells) {
            let anchors = tableBody(cells, header: course).filter {
                $0.bounds.minX < day.bounds.minX - 0.025 &&
                $0.text.range(of: #"[A-Z]{3}[0-9]{3}[HY][0-9]"#, options: .regularExpression) != nil
            }.sorted { $0.bounds.midY > $1.bounds.midY }
            for (index, anchor) in anchors.enumerated() {
                let existing = cells.filter {
                    $0.bounds.minX >= day.bounds.minX - 0.025 && $0.bounds.minX < time.bounds.minX - 0.025 &&
                    abs($0.bounds.midY - anchor.bounds.midY) < max(anchor.bounds.height * 0.65, 0.004)
                }
                guard existing.isEmpty else { continue }
                let upper = index == 0 ? course.bounds.minY : (anchors[index - 1].bounds.midY + anchor.bounds.midY) / 2
                let lower = index + 1 < anchors.count ? (anchor.bounds.midY + anchors[index + 1].bounds.midY) / 2 : anchor.bounds.minY - anchor.bounds.height / 2
                let left = max(0, day.bounds.minX - 0.015)
                let right = time.bounds.minX - 0.035
                let rect = CGRect(x: left * Double(image.width), y: (1 - upper) * Double(image.height),
                                  width: (right - left) * Double(image.width), height: (upper - lower) * Double(image.height)).integral
                guard let crop = image.cropping(to: rect), let recognized = try? recognize(crop) else { continue }
                let text = recognized.sorted { $0.bounds.minX < $1.bounds.minX }.map(\.text).joined(separator: " ")
                guard (try? weekdays(text)) != nil else { continue }
                cells.append(Cell(text: text, bounds: CGRect(x: day.bounds.minX, y: anchor.bounds.minY,
                    width: day.bounds.width, height: anchor.bounds.height)))
            }
        }
        return try parse(cells)
    }

    // Keep the contiguous table below its header; Safari's toolbar is separated by a large gap.
    private static func tableBody(_ cells: [Cell], header: Cell) -> [Cell] {
        var result: [Cell] = []
        var previousY = header.bounds.midY
        for cell in cells.filter({ $0.bounds.midY < header.bounds.minY }).sorted(by: { $0.bounds.midY > $1.bounds.midY }) {
            if previousY - cell.bounds.midY > max(header.bounds.height * 3, 0.025) { break }
            result.append(cell)
            previousY = cell.bounds.midY
        }
        return result
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
        let body = tableBody(cells, header: courseHeader)
        var rows: [Cell] = []
        for cell in body.sorted(by: { $0.bounds.midY > $1.bounds.midY }) {
            if !rows.contains(where: { abs($0.bounds.midY - cell.bounds.midY) < max($0.bounds.height * 0.65, 0.004) }) {
                rows.append(cell)
            }
        }
        guard !rows.isEmpty else { throw ManualCourse.ValidationError("No course rows were found. Try a clearer, uncropped PNG.") }
        var courses: [ManualCourse] = []
        var missingDays: [UUID: String] = [:]
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
            let codeRange = text.range(of: #"^[A-Z]{3}[0-9]{3}[HY][0-9]"#, options: .regularExpression)
            let typeRange = text.range(of: #"(LEC|TUT|PRA|LAB|SEM)\s*$"#, options: .regularExpression)
            let code = codeRange.map { String(text[$0]) } ?? ""
            let type = typeRange.map { String(text[$0]).trimmingCharacters(in: .whitespaces) } ?? ""
            var notes: [String] = []
            if code.isEmpty { notes.append("Enter the course code. Read from image: ‘\(text)’.") }
            if type.isEmpty { notes.append("Choose Lecture, Tutorial, Lab, or Seminar; the meeting type wasn't readable.") }
            let days: [Int]
            do { days = try weekdays(column(0)) }
            catch { days = [0]; notes.append("Select the missing or unreadable day: ‘\(column(0))’.") }
            let location = column(2).trimmingCharacters(in: .whitespacesAndNewlines)
            if location.isEmpty { notes.append("Location wasn't readable. Enter it or confirm it is unknown.") }
            let online = location.lowercased() == "online"
            // OCR sometimes joins a building code and room, e.g. MS2158.
            let spacedLocation = location.replacingOccurrences(of: #"^([A-Za-z]{2,3})([0-9])"#, with: "$1 $2", options: .regularExpression)
            let parts = spacedLocation.split(maxSplits: 1, whereSeparator: \.isWhitespace).map(String.init)
            let meetings = days.map { day -> ManualMeeting in
                var warnings = notes
                let hint = gridStartHour(cells, tableHeader: courseHeader, code: code, weekday: day, time: column(1))
                let times: (Int, Int)
                do { times = try timeRange(column(1), startHour: hint) }
                catch {
                    times = (9 * 60, 10 * 60)
                    warnings.append("Set start and end times, including AM/PM. Image text: ‘\(column(1))’. 9–10 AM is only a placeholder.")
                }
                if hint != nil { warnings.append("Time matched to the grid, assuming its first unmarked hour is morning. Confirm AM/PM against ACORN.") }
                return ManualMeeting(weekday: day, startMinute: times.0, endMinute: times.1,
                    type: ["LEC": "Lecture", "TUT": "Tutorial", "PRA": "Lab", "LAB": "Lab", "SEM": "Seminar"][type] ?? "Lecture",
                    building: online ? "" : (parts.first ?? ""), room: online ? "" : (parts.count > 1 ? parts[1] : ""), isOnline: online,
                    reviewNote: warnings.joined(separator: "\n"), scanConfirmed: warnings.isEmpty)
            }
            if days == [0] {
                for meeting in meetings { missingDays[meeting.id] = column(1) }
            }
            if let index = courses.firstIndex(where: { !code.isEmpty && $0.code == code }) {
                courses[index].meetings += meetings
            } else {
                courses.append(ManualCourse(code: code, meetings: meetings))
            }
        }
        // Resolve against all sibling rows, including rows appearing later in the table.
        // A grid block already assigned to a known meeting cannot fill another missing day.
        for courseIndex in courses.indices {
            let course = courses[courseIndex]
            var proposals: [(Int, Int, Int, Int)] = []
            for meetingIndex in course.meetings.indices {
                let meeting = course.meetings[meetingIndex]
                guard let time = missingDays[meeting.id] else { continue }
                let candidates = (1...7).compactMap { day -> (Int, Int, Int)? in
                    guard let hour = gridStartHour(cells, tableHeader: courseHeader, code: course.code, weekday: day, time: time),
                          let range = try? timeRange(time, startHour: hour),
                          !course.meetings.contains(where: { $0.weekday == day && $0.startMinute == range.0 }) else { return nil }
                    return (day, range.0, range.1)
                }
                if candidates.count == 1, let candidate = candidates.first {
                    proposals.append((meetingIndex, candidate.0, candidate.1, candidate.2))
                }
            }
            for proposal in proposals {
                guard proposals.filter({ $0.1 == proposal.1 && $0.2 == proposal.2 }).count == 1 else { continue }
                courses[courseIndex].meetings[proposal.0].weekday = proposal.1
                courses[courseIndex].meetings[proposal.0].startMinute = proposal.2
                courses[courseIndex].meetings[proposal.0].endMinute = proposal.3
                let otherNotes = courses[courseIndex].meetings[proposal.0].reviewNote.components(separatedBy: "\n").filter {
                    !$0.hasPrefix("Select the missing") && !$0.hasPrefix("Set start and end")
                }
                courses[courseIndex].meetings[proposal.0].reviewNote = (otherNotes + ["Day recovered from the matching grid block after checking the other meetings. Confirm the day and AM/PM against ACORN."]).joined(separator: "\n")
            }
        }
        return courses
    }

    /// Read the vertical hour sequence and match a course label in the correct weekday column.
    static func gridStartHour(_ cells: [Cell], tableHeader: Cell, code: String, weekday: Int, time: String) -> Int? {
        let grid = cells.filter { $0.bounds.minY > tableHeader.bounds.maxY }
        let dayNames = [2: "mon", 3: "tue", 4: "wed", 5: "thu", 6: "fri", 7: "sat", 1: "sun"]
        let dayHeaders = grid.filter { dayNames.values.contains(normalizedHeader($0.text)) }
        guard let dayHeader = dayHeaders.first(where: { normalizedHeader($0.text) == dayNames[weekday] }),
              let left = dayHeaders.map({ $0.bounds.minX }).min(),
              let rawHour = Int(time.trimmingCharacters(in: .whitespaces).prefix(while: { $0.isNumber })) else { return nil }
        let axis = grid.filter { $0.bounds.maxX < left && $0.bounds.midY < dayHeader.bounds.minY && $0.text.range(of: #"^[0-9]{1,2}:00$"#, options: .regularExpression) != nil }
            .sorted { $0.bounds.midY > $1.bounds.midY }
        guard axis.count >= 3 else { return nil }
        var timeline: [(Cell, Int)] = []
        for tick in axis {
            guard let hour = Int(tick.text.split(separator: ":")[0]), (1...23).contains(hour) else { return nil }
            var resolved = timeline.isEmpty || hour > 12 ? hour : hour % 12
            if let previous = timeline.last?.1 {
                while resolved <= previous { resolved += 12 }
                guard resolved - previous == 1 else { return nil }
            }
            guard resolved < 24 else { return nil }
            timeline.append((tick, resolved))
        }
        let labels = grid.filter { cell in
            !code.isEmpty && code.hasPrefix(cell.text.trimmingCharacters(in: .whitespaces)) &&
            cell.text.count >= 7 && dayHeaders.min(by: { abs($0.bounds.midX - cell.bounds.midX) < abs($1.bounds.midX - cell.bounds.midX) })?.text == dayHeader.text
        }
        let hours = labels.compactMap { label -> Int? in
            guard let nearest = timeline.min(by: { abs($0.0.bounds.midY - label.bounds.midY) < abs($1.0.bounds.midY - label.bounds.midY) }),
                  nearest.1 % 12 == rawHour % 12 else { return nil }
            return nearest.1
        }
        return hours.count == 1 ? hours[0] : nil
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

    static func timeRange(_ text: String, startHour: Int? = nil) throws -> (Int, Int) {
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
        let hour: Int
        if let startHour, startHour % 12 == numbers[0] % 12 {
            hour = startHour
        } else if numbers[0] > 12 {
            hour = numbers[0]
        } else {
            throw ManualCourse.ValidationError("Confirm AM/PM for ‘\(text)’; the grid did not resolve it.")
        }
        let start = hour * 60 + numbers[1]
        var end = numbers[2] > 12 ? numbers[2] * 60 + numbers[3] : (numbers[2] % 12) * 60 + numbers[3]
        if numbers[2] <= 12 {
            while end <= start { end += 12 * 60 }
        }
        guard end > start, end < 1440, end - start < 12 * 60 else {
            throw ManualCourse.ValidationError("Confirm the time range ‘\(text)’.")
        }
        return (start, end)
    }
}
