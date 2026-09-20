import SwiftUI

struct ManualCourseView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("manualTermStart") private var termStart = Date().timeIntervalSince1970
    @AppStorage("manualTermEnd") private var termEnd = Date().addingTimeInterval(90 * 86400).timeIntervalSince1970
    @State private var courses: [ManualCourse]
    @State private var hasReviewedImage = false
    let isImageImport: Bool
    let sourceImageData: Data?
    @State private var review: [CourseEventDraft] = []
    @State private var isReviewing = false
    @State private var errorMessage: String?
    @State private var isConfirmingDiscard = false
    let save: ([CourseEventDraft]) throws -> Void

    init(courses: [ManualCourse] = [ManualCourse()], isImageImport: Bool = false, sourceImageData: Data? = nil, save: @escaping ([CourseEventDraft]) throws -> Void) {
        _courses = State(initialValue: courses)
        self.isImageImport = isImageImport
        self.sourceImageData = sourceImageData
        self.save = save
    }

    var body: some View {
        NavigationStack {
            Form {
                if let sourceImageData, let image = UIImage(data: sourceImageData) {
                    Section {
                        DisclosureGroup("Compare with original PNG") {
                            Image(uiImage: image).resizable().scaledToFit()
                                .accessibilityLabel("Original ACORN timetable")
                        }
                    }
                }
                Section {
                    DatePicker("First day", selection: termDate($termStart), displayedComponents: .date)
                    DatePicker("Last day", selection: termDate($termEnd), displayedComponents: .date)
                } header: { Text("Term dates") } footer: {
                    Text("Meetings repeat weekly within these dates. Dates are shared with the next course you add. All times are Toronto time.")
                }

                ForEach($courses) { $course in
                Section {
                    TextField("Course code or name, e.g. CSC108H1", text: $course.code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("Course title (optional)", text: $course.title)
                } header: { Text("Course") }

                ForEach($course.meetings) { $meeting in
                    Section {
                        Picker("Type", selection: $meeting.type) {
                            ForEach(["Lecture", "Tutorial", "Lab", "Seminar"], id: \.self) { Text($0) }
                        }
                        Picker("Day", selection: $meeting.weekday) {
                            ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                                Text(ManualCourse.calendar.weekdaySymbols[day - 1]).tag(day)
                            }
                        }
                        DatePicker("Starts", selection: clockTime($meeting.startMinute), displayedComponents: .hourAndMinute)
                        DatePicker("Ends", selection: clockTime($meeting.endMinute), displayedComponents: .hourAndMinute)
                        Toggle("Online meeting", isOn: $meeting.isOnline)
                        if !meeting.isOnline {
                            TextField("Building (optional), e.g. Bahen", text: $meeting.building)
                            TextField("Room (optional), e.g. 1130", text: $meeting.room)
                        }
                        if course.meetings.count > 1 {
                            Button("Remove meeting", role: .destructive) {
                                course.meetings.removeAll { $0.id == meeting.id }
                            }
                        }
                    } header: { Text("Weekly meeting") }
                }
                Section {
                    Button {
                        course.meetings.append(ManualMeeting())
                    } label: {
                        Label("Add another meeting", systemImage: "plus.circle")
                    }
                } footer: {
                    Text("Add a meeting for each day, tutorial, or lab. Review individual dates before saving to remove holidays or reading week.")
                }
                    if isImageImport {
                        Button("Remove \(course.code)", role: .destructive) {
                            courses.removeAll { $0.id == course.id }
                        }
                    }
                }
                if isImageImport {
                    Section {
                        Text("Check your meetings and term dates before continuing.")
                    } header: { Text("Confirm the scan") } footer: {
                        Text("Compare every meeting with your PNG. AM/PM is inferred: 1–7 are treated as afternoon. Exact term dates, holidays, and winter meetings for year-long courses aren't in this image. Enter the correct dates above and remove holidays in the next step.")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    if isImageImport {
                        Toggle("I checked all meetings and term dates", isOn: $hasReviewedImage)
                            .font(.subheadline)
                    }
                    Button {
                        do {
                            review = try courses.flatMap { try $0.occurrences(from: Date(timeIntervalSince1970: termStart), through: Date(timeIntervalSince1970: termEnd)) }.sorted { $0.startTime < $1.startTime }
                            isReviewing = true
                        } catch { errorMessage = error.localizedDescription }
                    } label: {
                        Text("Review dates")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(courses.isEmpty || (isImageImport && !hasReviewedImage))
                }
                .padding()
                .background(.regularMaterial)
            }
            .navigationTitle(isImageImport ? "Check scanned courses" : "Add a course")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isConfirmingDiscard = true }
                }
            }
            .navigationDestination(isPresented: $isReviewing) {
                List {
                    Section {
                        Text("\(courses.count) course(s)").font(.headline)
                        Text("\(review.count) classes · Toronto time")
                        Text("Go back to edit details. Swipe left to exclude holidays or cancelled classes. Existing courses will stay in your schedule.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Section("Class dates") {
                        ForEach(review, id: \.uid) { event in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(event.courseCode).font(.headline)
                                Text(event.startTime.formatted(Date.FormatStyle(date: .complete, time: .omitted, timeZone: ManualCourse.calendar.timeZone)))
                                    .font(.headline)
                                Text("\(event.startTime.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: ManualCourse.calendar.timeZone))) – \(event.endTime.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: ManualCourse.calendar.timeZone))) · \(event.meetingType)")
                                Text(event.deliveryMode == "Online" ? "Online" : (event.location.isEmpty ? "Location not entered" : event.location))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .onDelete { review.remove(atOffsets: $0) }
                    }
                }
                .navigationTitle("Review class dates")
                .safeAreaInset(edge: .bottom) {
                    Button {
                        do {
                            try save(review)
                            dismiss()
                        } catch { errorMessage = error.localizedDescription }
                    } label: {
                        Text(isImageImport ? "Import schedule" : "Save course")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(review.isEmpty)
                    .padding()
                    .background(.regularMaterial)
                }
            }
        }
        .environment(\.timeZone, ManualCourse.calendar.timeZone)
        .interactiveDismissDisabled()
        .confirmationDialog("Discard these changes?", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { dismiss() }
        }
        .alert("Couldn't add course", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func termDate(_ value: Binding<Double>) -> Binding<Date> {
        Binding(get: { Date(timeIntervalSince1970: value.wrappedValue) }, set: { value.wrappedValue = $0.timeIntervalSince1970 })
    }

    private func clockTime(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(get: {
            ManualCourse.calendar.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: Date())!
        }, set: {
            let parts = ManualCourse.calendar.dateComponents([.hour, .minute], from: $0)
            minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        })
    }
}

#Preview {
    ManualCourseView { _ in }
}
