import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct TimetableImageImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var scanID = UUID()
    @State private var isLoadingPhoto = false
    @State private var photo: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var courses: [ManualCourse] = []
    @State private var isChoosingFile = false
    @State private var isReviewing = false
    @State private var isScanning = false
    @State private var errorMessage: String?
    let save: ([CourseEventDraft]) throws -> Void

    private var isBusy: Bool { isScanning || isLoadingPhoto }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Upload timetable", subtitle: "From your ACORN screenshot") { dismiss() }
                .padding(.horizontal, 22)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(spacing: 10) {
                        PhotosPicker(selection: $photo, matching: .images) {
                            sourceRow(systemImage: "photo.on.rectangle", title: "Choose from Photos", detail: "A screenshot of your ACORN timetable")
                        }
                        .buttonStyle(PressableButtonStyle())

                        Button { isChoosingFile = true } label: {
                            sourceRow(systemImage: "folder", title: "Choose a PNG from Files", detail: "Saved from ACORN on any device")
                        }
                        .buttonStyle(PressableButtonStyle())
                    }
                    .disabled(isBusy)
                    .opacity(isBusy ? 0.5 : 1)

                    if let errorMessage {
                        errorCard(errorMessage)
                            .padding(.top, 10)
                    }

                    if let imageData, let image = UIImage(data: imageData) {
                        SheetSectionLabel("Your timetable")
                            .padding(.top, 14)

                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .padding(8)
                            .frame(maxWidth: .infinity)
                            .background { CardSurface(cornerRadius: 20) }
                            .accessibilityLabel("Selected timetable screenshot")
                    }

                    SheetSectionLabel("Before you upload")
                        .padding(.top, 14)

                    VStack(spacing: 0) {
                        tipRow(systemImage: "viewfinder", text: "Include the whole grid, the hour labels and the Course, Day, Time and Location table. Safari bars are fine.")
                        SheetDivider(leading: 52)
                        tipRow(systemImage: "lock", text: "Text is read on your device. You'll check every meeting and the term dates before anything is saved.")
                        SheetDivider(leading: 52)
                        tipRow(systemImage: "arrow.triangle.2.circlepath", text: "Uploading replaces your current schedule.", isEmphasized: true)
                    }
                    .background { CardSurface(cornerRadius: 20) }
                }
                .padding(.horizontal, 22)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
        .sheetBottomBar {
            status
            SheetPrimaryButton(title: "Review & import", systemImage: "arrow.right", isEnabled: !isBusy && !courses.isEmpty) {
                isReviewing = true
            }
        }
        .customSheetPresentation()
        .animation(.smooth(duration: 0.3), value: imageData)
        .animation(.smooth(duration: 0.3), value: errorMessage)
        .fileImporter(isPresented: $isChoosingFile, allowedContentTypes: [.png]) { result in
            do {
                let url = try result.get()
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 20 * 1024 * 1024 else {
                    throw ManualCourse.ValidationError("Choose an image smaller than 20 MB.")
                }
                imageData = try Data(contentsOf: url)
                beginScan()
            } catch {
                if (error as NSError).code != NSUserCancelledError {
                    courses = []
                    errorMessage = error.localizedDescription
                }
            }
        }
        .sheet(isPresented: $isReviewing) {
            ManualCourseView(courses: courses, isImageImport: true, sourceImageData: imageData, save: save)
        }
        .task(id: photo) {
            guard let photo else { return }
            isLoadingPhoto = true
            courses = []
            errorMessage = nil
            defer { isLoadingPhoto = false }
            do {
                guard let data = try await photo.loadTransferable(type: Data.self) else {
                    throw ManualCourse.ValidationError("Couldn't load this photo. Try choosing the PNG from Files.")
                }
                guard data.count <= 20 * 1024 * 1024 else {
                    throw ManualCourse.ValidationError("Choose an image smaller than 20 MB.")
                }
                try Task.checkCancellation()
                imageData = data
                beginScan()
            } catch is CancellationError {} catch {
                courses = []
                errorMessage = error.localizedDescription
            }
        }
        .task(id: scanID) {
            guard let imageData else { return }
            courses = []
            errorMessage = nil
            isScanning = true
            // Vision is synchronous CPU work; keep it off the UI thread.
            let scan = Task.detached(priority: .userInitiated) { try TimetableImageParser.scan(imageData) }
            do {
                let result = try await scan.value
                try Task.checkCancellation()
                courses = result
                isScanning = false
            } catch is CancellationError {} catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                isScanning = false
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if isLoadingPhoto || isScanning {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(AppTheme.secondaryText)
                Text(isLoadingPhoto ? "Loading photo…" : "Reading timetable…")
            }
            .font(AppFont.medium(14))
            .foregroundStyle(AppTheme.secondaryText)
        } else if !courses.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppTheme.green)
                Text("\(courses.count) courses · \(courses.reduce(0) { $0 + $1.meetings.count }) weekly meetings")
            }
            .font(AppFont.medium(14))
            .foregroundStyle(AppTheme.primaryText)
        } else if imageData == nil {
            Text("Choose your timetable image to continue.")
                .font(AppFont.regular(13))
                .foregroundStyle(AppTheme.secondaryText)
        }
    }

    private func sourceRow(systemImage: String, title: String, detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold, design: .default))
                .foregroundStyle(AppTheme.blue)
                .frame(width: 44, height: 44)
                .background(AppTheme.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppFont.semibold(16))
                    .foregroundStyle(AppTheme.primaryText)
                Text(detail)
                    .font(AppFont.regular(13))
                    .foregroundStyle(AppTheme.secondaryText)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold, design: .default))
                .foregroundStyle(AppTheme.secondaryText.opacity(0.7))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { CardSurface(cornerRadius: 20) }
        .contentShape(Rectangle())
    }

    private func tipRow(systemImage: String, text: String, isEmphasized: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold, design: .default))
                .foregroundStyle(AppTheme.softAccent)
                .frame(width: 22)

            Text(text)
                .font(isEmphasized ? AppFont.semibold(14) : AppFont.regular(14))
                .foregroundStyle(isEmphasized ? AppTheme.primaryText : AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(AppTheme.red)
                Text("Couldn't read timetable")
                    .font(AppFont.semibold(15))
                    .foregroundStyle(AppTheme.primaryText)
            }

            Text(message)
                .font(AppFont.regular(14))
                .foregroundStyle(AppTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            Text("Try a clearer image with the full table, or close this and add courses by hand.")
                .font(AppFont.regular(13))
                .foregroundStyle(AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if imageData != nil {
                Button { beginScan() } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                        .font(AppFont.semibold(14))
                        .foregroundStyle(AppTheme.blue)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .background(AppTheme.blue.opacity(0.1), in: Capsule())
                }
                .buttonStyle(PressableButtonStyle())
                .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { CardSurface(cornerRadius: 20) }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(AppTheme.red.opacity(0.35), lineWidth: 1)
        }
    }

    private func beginScan() {
        courses = []
        errorMessage = nil
        isScanning = true
        scanID = UUID()
    }
}
