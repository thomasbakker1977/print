import AVFoundation
import Foundation
import Speech

enum SpeechLanguage: String, CaseIterable, Identifiable {
    case dutch = "nl-NL"
    case english = "en-US"

    var id: String { rawValue }
    var title: String { self == .dutch ? "Nederlands" : "English" }

    static var preferred: SpeechLanguage {
        let stored = UserDefaults.standard.string(forKey: "speechLanguage")
        if let stored, let language = SpeechLanguage(rawValue: stored) { return language }
        return Locale.current.language.languageCode?.identifier == "nl" ? .dutch : .english
    }
}

/// Turns speech into text, on the device whenever the language supports it.
@MainActor
final class SpeechRecognizer: ObservableObject {
    @Published private(set) var transcript = ""
    @Published private(set) var isRecording = false
    @Published var errorMessage: String?

    /// Called once with the final text when recording stops on its own after silence.
    var onSilence: ((String) -> Void)?

    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var lastChange = Date.now

    static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    /// - Parameter silenceTimeout: stop automatically after this long without new words.
    func start(silenceTimeout: TimeInterval? = nil) async {
        guard !isRecording else { return }
        errorMessage = nil
        guard await Self.authorize() else {
            errorMessage = "Allow microphone and speech recognition for LifeChart in Settings."
            return
        }
        let language = SpeechLanguage.preferred
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language.rawValue)),
              recognizer.isAvailable
        else {
            errorMessage = "Speech recognition for \(language.title) is not available right now."
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let engine = AVAudioEngine()
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            // Keep what the user says on the phone when the language allows it.
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()

            transcript = ""
            lastChange = .now
            self.engine = engine
            self.request = request
            isRecording = true

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                let failed = error != nil
                Task { @MainActor in
                    guard let self else { return }
                    if let text, text != self.transcript {
                        self.transcript = text
                        self.lastChange = .now
                    }
                    if isFinal || (failed && self.isRecording) { self.stop() }
                }
            }

            if let silenceTimeout {
                silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.isRecording, !self.transcript.isEmpty,
                              Date.now.timeIntervalSince(self.lastChange) > silenceTimeout
                        else { return }
                        let text = self.transcript
                        self.stop()
                        self.onSilence?(text)
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            stop()
        }
    }

    func stop() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        request?.endAudio()
        task?.finish()
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        request = nil
        task = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Reads replies aloud.
@MainActor
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    private var onFinish: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, onFinish: (() -> Void)? = nil) {
        stop()
        let clean = Self.plain(text)
        guard !clean.isEmpty else {
            onFinish?()
            return
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: clean)
        utterance.voice = AVSpeechSynthesisVoice(language: SpeechLanguage.preferred.rawValue)
        self.onFinish = onFinish
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        onFinish = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        isSpeaking = false
    }

    /// Strips markdown and the "✓ Logged ..." footer so speech sounds natural.
    static func plain(_ text: String) -> String {
        text
            .components(separatedBy: "\n")
            .filter { !$0.hasPrefix("✓") }
            .joined(separator: "\n")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "* ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didFinish _: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            let callback = self.onFinish
            self.onFinish = nil
            callback?()
        }
    }
}
