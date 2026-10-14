import AVKit
import PhotosUI
import SwiftData
import SwiftUI

/// Photos and videos that capture how a day felt.
struct MoodMediaSection: View {
    let dayKey: String
    @Environment(\.modelContext) private var context
    @Query private var media: [MoodMedia]
    @State private var showingCamera = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var selected: MoodMedia?
    @State private var error: String?

    init(dayKey: String) {
        self.dayKey = dayKey
        _media = Query(filter: #Predicate<MoodMedia> { $0.dayKey == dayKey }, sort: \MoodMedia.createdAt)
    }

    var body: some View {
        Section {
            if !media.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(media) { item in
                            MediaThumbnail(media: item)
                                .frame(width: 90, height: 90)
                                .onTapGesture { selected = item }
                        }
                    }
                }
            }
            HStack {
                if CameraPicker.isAvailable {
                    Button("Camera", systemImage: "camera") { showingCamera = true }
                        .buttonStyle(.borderless)
                    Spacer()
                }
                PhotosPicker(selection: $pickerItems, maxSelectionCount: 5, matching: .any(of: [.images, .videos])) {
                    Label("Library", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.borderless)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Mood impressions")
        } footer: {
            Text("Photos and videos stay on this iPhone. You can choose to share one with your coach.")
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraPicker { result in save(result) }
                .ignoresSafeArea()
        }
        .sheet(item: $selected) { item in
            MediaViewer(media: item)
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await importItems(items) }
        }
    }

    private func save(_ result: CameraPicker.Result) {
        do {
            switch result {
            case let .photo(image):
                context.insert(MoodMedia(dayKey: dayKey, kind: .photo, fileName: try MediaStore.savePhoto(image)))
            case let .video(url):
                context.insert(MoodMedia(dayKey: dayKey, kind: .video, fileName: try MediaStore.saveVideo(from: url)))
            }
            try context.save()
        } catch {
            self.error = "Could not save: \(error.localizedDescription)"
        }
    }

    private func importItems(_ items: [PhotosPickerItem]) async {
        for item in items {
            if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                save(.video(movie.url))
                try? FileManager.default.removeItem(at: movie.url)
            } else if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                save(.photo(image))
            }
        }
        pickerItems = []
    }
}

struct MediaThumbnail: View {
    let media: MoodMedia
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
            }
            if media.kind == .video {
                Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.white).shadow(radius: 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .task(id: media.id) {
            let url = media.url
            let kind = media.kind
            image = await Task.detached { MediaStore.image(url: url, kind: kind) }.value
        }
        .accessibilityLabel(media.kind == .video ? "Mood video" : "Mood photo")
    }
}

struct MediaViewer: View {
    @Bindable var media: MoodMedia
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        NavigationStack {
            VStack {
                switch media.kind {
                case .photo:
                    if let image = UIImage(contentsOfFile: media.url.path) {
                        Image(uiImage: image).resizable().scaledToFit()
                    }
                case .video:
                    VideoPlayer(player: AVPlayer(url: media.url))
                }
                TextField("Caption", text: $media.caption, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .padding()
            }
            .navigationTitle(media.date.formatted(date: .abbreviated, time: .omitted))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        try? context.save()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Talk about this with my coach", systemImage: "bubble.left") {
                            try? context.save()
                            CoachAttachment.pending = media.id
                            router.tab = .coach
                            dismiss()
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            MediaStore.delete(media.fileName)
                            context.delete(media)
                            try? context.save()
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }
}

/// Media the user chose to bring into a coach conversation.
enum CoachAttachment {
    @MainActor static var pending: String?
}

/// All mood impressions, newest first.
struct MoodGalleryView: View {
    @Query(sort: \MoodMedia.createdAt, order: .reverse) private var media: [MoodMedia]
    @State private var selected: MoodMedia?

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 4)]

    var body: some View {
        ScrollView {
            if media.isEmpty {
                ContentUnavailableView("No impressions yet", systemImage: "camera",
                                       description: Text("Add photos or videos on the Today screen."))
            }
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(media) { item in
                    MediaThumbnail(media: item)
                        .aspectRatio(1, contentMode: .fill)
                        .overlay(alignment: .bottomLeading) {
                            Text(item.date.formatted(.dateTime.day().month()))
                                .font(.caption2.bold())
                                .padding(4)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(4)
                        }
                        .onTapGesture { selected = item }
                }
            }
            .padding(4)
        }
        .navigationTitle("Mood impressions")
        .sheet(item: $selected) { item in MediaViewer(media: item) }
    }
}
