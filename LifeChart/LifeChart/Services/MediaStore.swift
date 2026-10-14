import AVFoundation
import SwiftUI
import UIKit

/// Stores mood photos and videos in the app's own, file-protected folder.
enum MediaStore {
    static var directory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MoodMedia", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = false
            var mutable = url
            try? mutable.setResourceValues(values)
        }
        return url
    }

    static func url(for fileName: String) -> URL {
        directory.appendingPathComponent(fileName)
    }

    static func savePhoto(_ image: UIImage) throws -> String {
        let name = "\(UUID().uuidString).jpg"
        guard let data = image.jpegData(compressionQuality: 0.85) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url(for: name), options: [.atomic, .completeFileProtection])
        return name
    }

    static func saveVideo(from source: URL) throws -> String {
        let name = "\(UUID().uuidString).\(source.pathExtension.isEmpty ? "mov" : source.pathExtension)"
        let destination = url(for: name)
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
        return name
    }

    static func delete(_ fileName: String) {
        try? FileManager.default.removeItem(at: url(for: fileName))
    }

    /// The photo itself, or a frame from the start of a video.
    static func image(for media: MoodMedia) -> UIImage? {
        switch media.kind {
        case .photo:
            return UIImage(contentsOfFile: media.url.path)
        case .video:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: media.url))
            generator.appliesPreferredTrackTransform = true
            let time = CMTime(seconds: 0.5, preferredTimescale: 600)
            guard let frame = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
            return UIImage(cgImage: frame)
        }
    }

    /// A downsized JPEG, base64-encoded, for sharing with the coach.
    static func attachment(for media: MoodMedia) -> String? {
        guard let image = image(for: media) else { return nil }
        let maxSide: CGFloat = 1280
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: 0.75)?.base64EncodedString()
    }
}

/// The system camera for photos and short videos.
struct CameraPicker: UIViewControllerRepresentable {
    enum Result {
        case photo(UIImage)
        case video(URL)
    }

    var onCapture: (Result) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = ["public.image", "public.movie"]
        picker.videoMaximumDuration = 60
        picker.videoQuality = .typeHigh
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_: UIImagePickerController, context _: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(
            _: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let url = info[.mediaURL] as? URL {
                parent.onCapture(.video(url))
            } else if let image = info[.originalImage] as? UIImage {
                parent.onCapture(.photo(image))
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

/// A movie picked from the photo library, copied to a temporary file.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).\(received.file.pathExtension)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}
