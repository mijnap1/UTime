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

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Use the full ACORN timetable PNG, including the Course, Day, Time, and Location table below the grid.")
                    Text("Text recognition happens on your device. You'll check the extracted meetings and set term dates before anything is saved.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label("Choose from Photos", systemImage: "photo")
                    }
                    Button { isChoosingFile = true } label: {
                        Label("Choose PNG from Files", systemImage: "folder")
                    }
                }
                .disabled(isScanning || isLoadingPhoto)
                if let errorMessage {
                    Section("Couldn't read timetable") {
                        Text(errorMessage).foregroundStyle(.red)
                        if imageData != nil {
                            Button("Retry reading this image") { beginScan() }
                        }
                        Text("Choose a clearer image with the full table, or close this screen and use manual entry.")
                    }
                }
                if let imageData, let image = UIImage(data: imageData) {
                    Section("Your timetable") {
                        Image(uiImage: image).resizable().scaledToFit()
                            .accessibilityLabel("Selected timetable screenshot")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    if isLoadingPhoto {
                        ProgressView("Loading photo…")
                    } else if isScanning {
                        ProgressView("Reading timetable…")
                    } else if !courses.isEmpty {
                        Text("\(courses.count) courses · \(courses.reduce(0) { $0 + $1.meetings.count }) weekly meetings")
                            .font(.subheadline)
                    }
                    Button { isReviewing = true } label: {
                        Text("Review & import")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isScanning || isLoadingPhoto || courses.isEmpty)
                    if imageData == nil {
                        Text("Choose your timetable image to continue.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding()
                .background(.regularMaterial)
            }
            .navigationTitle("Upload timetable")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
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
    }
    private func beginScan() {
        courses = []
        errorMessage = nil
        isScanning = true
        scanID = UUID()
    }

}
