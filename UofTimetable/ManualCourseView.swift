import SwiftUI

struct ManualCourseView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("manualTermStart") private var termStart = Date().timeIntervalSince1970
    @AppStorage("manualTermEnd") private var termEnd = Date().addingTimeInterval(90 * 86400).timeIntervalSince1970
    @State private var courses: [ManualCourse]
    @State private var hasReviewedImage = false
    @State private var isSaving = false
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

    private var saveTitle: String { isSaving ? "Saving…" : (isImageImport ? "Upload timetable" : "Save course") }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SheetHeader(
                    title: isImageImport ? "Check scanned courses" : "Add a course",
                    subtitle: isImageImport ? "Make sure everything matches ACORN" : "Meetings repeat every week"
                ) { isConfirmingDiscard = true }
                .padding(.horizontal, 22)

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let sourceImageData, let image = UIImage(data: sourceImageData) {
                            OriginalImageCard(image: image)
                        }

                        termSection

                        ForEach($courses) { $course in
                            courseSection($course)
                        }

                        if isImageImport {
                            SheetSectionLabel("Confirm the scan")
                                .padding(.top, 14)
                            SheetFootnote("Check every flagged meeting against ACORN, especially AM and PM. Missing section numbers are fine. Winter meetings for year-long courses aren't in a fall screenshot.")
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                    .animation(.smooth(duration: 0.3), value: courses.map(\.meetings.count))
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
            }
            .sheetBottomBar {
                if isImageImport {
                    checkedRow
                }
                SheetPrimaryButton(title: saveTitle, isEnabled: !isSaving, isLoading: isSaving) {
                    do { saveDates(try preparedDates()) }
                    catch { errorMessage = error.localizedDescription }
                }
                Button {
                    do {
                        review = try preparedDates()
                        isReviewing = true
                    } catch { errorMessage = error.localizedDescription }
                } label: {
                    Text("Preview class dates first")
                        .font(AppFont.semibold(15))
                        .foregroundStyle(AppTheme.softAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(isSaving)
            }
            .background { AppBackground() }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $isReviewing) {
                reviewPage
            }
        }
        .tint(AppTheme.blue)
        .environment(\.timeZone, ManualCourse.calendar.timeZone)
        .interactiveDismissDisabled()
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
        .confirmationDialog("Discard these changes?", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { dismiss() }
        }
        .alert(isImageImport ? "Couldn't upload timetable" : "Couldn't save course", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    // MARK: Sections

    private var termSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SheetSectionLabel("Term dates")

            VStack(spacing: 0) {
                dateRow("First day", selection: termDate($termStart))
                SheetDivider()
                dateRow("Last day", selection: termDate($termEnd))
            }
            .background { CardSurface(cornerRadius: 20) }

            SheetFootnote("Saved for the next course you add. All times are Toronto time.")
        }
    }

    private func courseSection(_ course: Binding<ManualCourse>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SheetSectionLabel("Course")
                Spacer()
                if isImageImport {
                    Button(role: .destructive) {
                        withAnimation(.smooth(duration: 0.3)) {
                            courses.removeAll { $0.id == course.wrappedValue.id }
                        }
                    } label: {
                        Text("Remove course")
                            .font(AppFont.semibold(13))
                            .foregroundStyle(AppTheme.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 14)

            VStack(spacing: 0) {
                SheetTextFieldRow(placeholder: "Course code, e.g. CSC108H1", text: course.code, systemImage: "number", capitalization: .characters)
                SheetDivider(leading: 48)
                SheetTextFieldRow(placeholder: "Course title (optional)", text: course.title, systemImage: "text.alignleft")
            }
            .background { CardSurface(cornerRadius: 20) }

            ForEach(Array(course.meetings.enumerated()), id: \.element.id) { index, meeting in
                MeetingCard(
                    meeting: meeting,
                    number: index + 1,
                    canRemove: course.wrappedValue.meetings.count > 1,
                    clockTime: clockTime
                ) {
                    withAnimation(.smooth(duration: 0.3)) {
                        course.wrappedValue.meetings.removeAll { $0.id == meeting.wrappedValue.id }
                    }
                }
                .padding(.top, 4)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }

            Button {
                withAnimation(.smooth(duration: 0.3)) {
                    course.wrappedValue.meetings.append(ManualMeeting())
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold, design: .default))
                    Text("Add another meeting")
                        .font(AppFont.semibold(15))
                }
                .foregroundStyle(AppTheme.softAccent)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(AppTheme.softAccent.opacity(0.35), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .padding(.top, 4)

            SheetFootnote("Add one for each lecture, tutorial or lab. Preview class dates to skip holidays or reading week.")
        }
    }

    private var checkedRow: some View {
        Button {
            withAnimation(.smooth(duration: 0.2)) { hasReviewedImage.toggle() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: hasReviewedImage ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24, weight: .regular, design: .default))
                    .foregroundStyle(hasReviewedImage ? AppTheme.blue : AppTheme.secondaryText.opacity(0.6))
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 1) {
                    Text("I checked all meetings and term dates")
                        .font(AppFont.semibold(15))
                        .foregroundStyle(AppTheme.primaryText)
                    Text(hasReviewedImage ? "Ready to upload" : "Tap to confirm before uploading")
                        .font(AppFont.regular(13))
                        .foregroundStyle(AppTheme.secondaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background { OnboardingFieldSurface(isActive: hasReviewedImage) }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityAddTraits(hasReviewedImage ? .isSelected : [])
    }

    private func dateRow(_ title: String, selection: Binding<Date>) -> some View {
        HStack {
            Text(title)
                .font(AppFont.medium(16))
                .foregroundStyle(AppTheme.primaryText)
            Spacer()
            DatePicker(title, selection: selection, displayedComponents: .date)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    // MARK: Review

    private var reviewPage: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: "Class dates",
                subtitle: "\(review.count) classes · \(courses.count == 1 ? "1 course" : "\(courses.count) courses") · Toronto time",
                showsBack: true
            ) { isReviewing = false }
            .padding(.horizontal, 22)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    SheetFootnote("Remove holidays or cancelled classes. Your other courses stay in your schedule.")
                        .padding(.bottom, 4)

                    ForEach(review, id: \.uid) { event in
                        reviewRow(event)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 12)
                .padding(.bottom, 24)
                .animation(.smooth(duration: 0.3), value: review.map(\.uid))
            }
            .scrollIndicators(.hidden)
        }
        .sheetBottomBar {
            SheetPrimaryButton(title: saveTitle, isEnabled: !review.isEmpty && !isSaving, isLoading: isSaving) {
                saveDates(review)
            }
        }
        .background { AppBackground() }
        .toolbar(.hidden, for: .navigationBar)
    }

    private func reviewRow(_ event: CourseEventDraft) -> some View {
        let zone = ManualCourse.calendar.timeZone
        let day = event.startTime.formatted(Date.FormatStyle(date: .omitted, time: .omitted, timeZone: zone).weekday(.abbreviated).month(.abbreviated).day())
        let start = event.startTime.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone))
        let end = event.endTime.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone))
        let place = event.deliveryMode == "Online" ? "Online" : (event.location.isEmpty ? "No location" : event.location)

        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(event.courseCode)
                        .font(AppFont.semibold(15))
                        .foregroundStyle(AppTheme.primaryText)
                    Text(event.meetingType)
                        .font(AppFont.medium(12))
                        .foregroundStyle(AppTheme.softAccent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(AppTheme.softAccent.opacity(0.12), in: Capsule())
                }
                Text(day)
                    .font(AppFont.medium(14))
                    .foregroundStyle(AppTheme.primaryText)
                Text("\(start) – \(end) · \(place)")
                    .font(AppFont.regular(13))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button {
                review.removeAll { $0.uid == event.uid }
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 13, weight: .bold, design: .default))
                    .foregroundStyle(AppTheme.red)
                    .frame(width: 32, height: 32)
                    .background(AppTheme.red.opacity(0.1), in: Circle())
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Remove this class")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { CardSurface(cornerRadius: 18) }
    }

    private func preparedDates() throws -> [CourseEventDraft] {
        guard !courses.isEmpty else { throw ManualCourse.ValidationError("Add at least one course before saving.") }
        guard !isImageImport || hasReviewedImage else {
            throw ManualCourse.ValidationError("Check your courses, AM/PM, and term dates, then turn on ‘I checked all meetings and term dates’ above the button.")
        }
        return try courses.flatMap {
            try $0.occurrences(from: Date(timeIntervalSince1970: termStart), through: Date(timeIntervalSince1970: termEnd), reviewedScan: isImageImport && hasReviewedImage)
        }.sorted { $0.startTime < $1.startTime }
    }

    private func saveDates(_ dates: [CourseEventDraft]) {
        guard !isSaving else { return }
        guard !dates.isEmpty else { errorMessage = "There are no class dates to save."; return }
        isSaving = true
        do {
            try save(dates)
            dismiss()
        } catch {
            isSaving = false
            errorMessage = error.localizedDescription
        }
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

/// One weekly meeting: type, day, time and place.
private struct MeetingCard: View {
    @Binding var meeting: ManualMeeting
    let number: Int
    let canRemove: Bool
    let clockTime: (Binding<Int>) -> Binding<Date>
    let onRemove: () -> Void

    private static let types = ["Lecture", "Tutorial", "Lab", "Seminar"]
    private static let weekdays = [2, 3, 4, 5, 6, 7, 1]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Meeting \(number)")
                    .font(AppFont.semibold(16))
                    .foregroundStyle(AppTheme.primaryText)
                Spacer()
                if canRemove {
                    Button(action: onRemove) {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .semibold, design: .default))
                            .foregroundStyle(AppTheme.red)
                            .frame(width: 32, height: 32)
                            .background(AppTheme.red.opacity(0.1), in: Circle())
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityLabel("Remove meeting")
                }
            }

            if !meeting.reviewNote.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .semibold, design: .default))
                        .foregroundStyle(AppTheme.amber)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Check this meeting")
                            .font(AppFont.semibold(14))
                            .foregroundStyle(AppTheme.primaryText)
                        Text(meeting.reviewNote)
                            .font(AppFont.regular(13))
                            .foregroundStyle(AppTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(AppTheme.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            field("Type") {
                HStack(spacing: 6) {
                    ForEach(Self.types, id: \.self) { type in
                        SheetChip(title: type, isSelected: meeting.type == type) { meeting.type = type }
                    }
                }
            }

            field("Day") {
                HStack(spacing: 5) {
                    ForEach(Self.weekdays, id: \.self) { day in
                        SheetChip(
                            title: ManualCourse.calendar.shortWeekdaySymbols[day - 1],
                            isSelected: meeting.weekday == day,
                            height: 40
                        ) { meeting.weekday = day }
                    }
                }
            }

            field("Time") {
                HStack(spacing: 8) {
                    DatePicker("Starts", selection: clockTime($meeting.startMinute), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                    Text("to")
                        .font(AppFont.medium(14))
                        .foregroundStyle(AppTheme.secondaryText)
                    DatePicker("Ends", selection: clockTime($meeting.endMinute), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                    Spacer(minLength: 0)
                }
            }

            VStack(spacing: 10) {
                Toggle(isOn: $meeting.isOnline.animation(.smooth(duration: 0.25))) {
                    Text("Online meeting")
                        .font(AppFont.medium(15))
                        .foregroundStyle(AppTheme.primaryText)
                }
                .tint(AppTheme.blue)

                if !meeting.isOnline {
                    HStack(spacing: 8) {
                        inlineField("Building, e.g. Bahen", text: $meeting.building)
                        inlineField("Room", text: $meeting.room)
                            .frame(width: 104)
                    }
                    .transition(.opacity)
                }
            }
        }
        .padding(16)
        .background { CardSurface(cornerRadius: 20) }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(AppFont.medium(13))
                .foregroundStyle(AppTheme.secondaryText)
            content()
        }
    }

    private func inlineField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .font(AppFont.medium(15))
            .foregroundStyle(AppTheme.primaryText)
            .autocorrectionDisabled()
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppTheme.field)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(AppTheme.border.opacity(0.8), lineWidth: 0.75)
                    }
            }
    }
}

/// Collapsible copy of the uploaded screenshot for side-by-side checking.
private struct OriginalImageCard: View {
    let image: UIImage
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.smooth(duration: 0.3)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "photo")
                        .font(.system(size: 14, weight: .semibold, design: .default))
                        .foregroundStyle(AppTheme.blue)
                        .frame(width: 20)
                    Text("Compare with your screenshot")
                        .font(AppFont.medium(16))
                        .foregroundStyle(AppTheme.primaryText)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold, design: .default))
                        .foregroundStyle(AppTheme.secondaryText)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.horizontal, 16)
                .frame(height: 54)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding([.horizontal, .bottom], 8)
                    .transition(.opacity)
                    .accessibilityLabel("Original ACORN timetable")
            }
        }
        .background { CardSurface(cornerRadius: 20) }
    }
}

#Preview {
    ManualCourseView { _ in }
}
