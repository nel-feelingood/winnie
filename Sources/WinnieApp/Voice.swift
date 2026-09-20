import AVFoundation
import Speech

/// Speech-to-text with the recognizer built into macOS: free, and on Apple silicon it
/// runs on the device, so nothing spoken leaves the Mac.
@MainActor
final class SpeechListener {
    enum Failure: LocalizedError {
        case notAuthorized, unavailable, engine(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                "Нужен доступ к микрофону и распознаванию речи: Системные настройки → Конфиденциальность и безопасность."
            case .unavailable: "Распознавание русской речи сейчас недоступно."
            case .engine(let message): "Микрофон не запустился: \(message)"
            }
        }
    }

    var onTranscript: (String) -> Void = { _ in }
    /// Called once, with the final text, when the speaker has gone quiet.
    var onFinished: (String) -> Void = { _ in }
    var onFailure: (Failure) -> Void = { _ in }

    private(set) var isListening = false

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var transcript = ""

    /// How long a pause has to be before the question is considered finished.
    private static let silence: TimeInterval = 1.6
    /// Grace period to start talking before giving up on an empty recording.
    private static let initialSilence: TimeInterval = 6

    func start() {
        guard !isListening else { return }
        Task {
            guard await Self.requestPermissions() else { return onFailure(.notAuthorized) }
            begin()
        }
    }

    /// Ends the recording and delivers what was heard.
    func finish() { end(deliver: true) }

    func cancel() { end(deliver: false) }

    private static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    private func begin() {
        guard let recognizer, recognizer.isAvailable else { return onFailure(.unavailable) }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        transcript = ""

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        // The tap runs on the audio thread; it touches nothing but the request.
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [request] buffer, _ in
            request.append(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return onFailure(.engine(error.localizedDescription))
        }

        isListening = true
        restartSilenceTimer(Self.initialSilence)
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let failed = error != nil
            Task { @MainActor in
                guard let self, self.isListening else { return }
                if let text, text != self.transcript {
                    self.transcript = text
                    self.onTranscript(text)
                    self.restartSilenceTimer(Self.silence)
                }
                if failed { self.end(deliver: true) }
            }
        }
    }

    private func restartSilenceTimer(_ interval: TimeInterval) {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.end(deliver: true) }
        }
    }

    private func end(deliver: Bool) {
        guard isListening else { return }
        isListening = false
        silenceTimer?.invalidate()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        onFinished(deliver ? transcript : "")
    }
}

/// Reads answers aloud with a system voice. Which voice, how high and how fast are the
/// user's to tune in Settings: the 1969 cartoon got its Winnie by speeding the actor's
/// tape up by about a third, and raising pitch and pace imitates that on a good voice,
/// but on a basic one it only adds distortion.
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    var onFinished: () -> Void = {}

    private let settings: AppSettings
    private let synthesizer = AVSpeechSynthesizer()
    private var voice: AVSpeechSynthesisVoice?
    private var queued = 0

    var isSpeaking: Bool { queued > 0 }

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ sentence: String) {
        // Looked up per answer, so a voice downloaded in System Settings is picked up without a restart.
        if queued == 0 { voice = Self.voice(for: settings.voiceIdentifier) }
        let utterance = AVSpeechUtterance(string: sentence)
        utterance.voice = voice
        utterance.pitchMultiplier = Float(settings.voicePitch)
        utterance.rate = Float(settings.voiceRate)
        utterance.postUtteranceDelay = 0.04
        queued += 1
        synthesizer.speak(utterance)
    }

    func stop() {
        guard isSpeaking else { return }
        queued = 0
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// Installed Russian voices, best quality first.
    static func russianVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("ru") }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
    }

    static func label(for voice: AVSpeechSynthesisVoice) -> String {
        let quality = switch voice.quality {
        case .premium: "премиум"
        case .enhanced: "улучшенный"
        default: "базовый"
        }
        return "\(voice.name) — \(quality)"
    }

    private static func voice(for identifier: String) -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice(identifier: identifier) ?? russianVoices().first ?? AVSpeechSynthesisVoice(language: "ru-RU")
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard queued > 0 else { return }
            queued -= 1
            if queued == 0 { onFinished() }
        }
    }
}
