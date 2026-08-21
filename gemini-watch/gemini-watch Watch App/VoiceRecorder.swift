import Foundation
import AVFoundation
import Combine

/// Records a spoken question and stops on its own when you stop talking.
///
/// The auto-stop is the whole point. Apple's Dictate Text action gives you
/// endpointing for free, but its transcription is weak for some languages and
/// hopeless when you code-switch mid-sentence. Sending raw audio to Gemini
/// fixes the recognition — but then *we* have to decide when the question
/// ended, or the user needs a "Stop" button, which would break the zero-tap
/// Action-button flow. So this class watches the input meter and ends the take
/// after a beat of silence.
@MainActor
final class VoiceRecorder: NSObject, ObservableObject {

    enum State: Equatable {
        case idle
        /// Mic is live but the user hasn't started talking yet.
        case listening
        /// Speech detected — recording in earnest.
        case capturing
        case finished(URL)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// Normalised 0…1 input level, for the on-screen meter.
    @Published private(set) var level: Double = 0

    // MARK: - Tuning

    /// Above this (dBFS) counts as speech rather than room noise.
    private let speechThresholdDB: Float = -32
    /// How long a pause ends the take once the user has started talking.
    private let trailingSilence: TimeInterval = 1.1
    /// Give up if nobody says anything at all.
    private let noSpeechTimeout: TimeInterval = 6
    /// Hard ceiling, so a pocket-press can't record forever.
    private let maxDuration: TimeInterval = 30
    private let pollInterval: TimeInterval = 0.08

    // MARK: - State

    private var recorder: AVAudioRecorder?
    private var monitorTask: Task<Void, Never>?
    private var startedAt: Date?
    private var lastSpeechAt: Date?
    private var fileURL: URL?

    /// 16 kHz mono 16-bit PCM — a format Gemini accepts directly, and small
    /// enough that a 30-second ceiling still fits comfortably inline.
    private var recorderSettings: [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
    }

    static let mimeType = "audio/wav"

    // MARK: - Lifecycle

    func start() async {
        guard await requestPermission() else {
            state = .failed("Microphone access denied. Enable it in Settings.")
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("quick-ask-\(UUID().uuidString).wav")
            let recorder = try AVAudioRecorder(url: url, settings: recorderSettings)
            recorder.isMeteringEnabled = true

            guard recorder.record() else {
                state = .failed("Couldn't start recording.")
                return
            }

            self.recorder = recorder
            self.fileURL = url
            self.startedAt = Date()
            self.lastSpeechAt = nil
            self.state = .listening

            startMonitoring()
        } catch {
            state = .failed("Mic unavailable. \(error.localizedDescription)")
        }
    }

    /// Ends the take immediately. Only needed for explicit cancellation — the
    /// normal path finishes itself.
    func cancel() {
        monitorTask?.cancel()
        monitorTask = nil
        recorder?.stop()
        recorder = nil
        deactivateSession()
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        fileURL = nil
        state = .idle
        level = 0
    }

    /// Removes the captured file once it has been uploaded. Audio is never
    /// persisted with the conversation — only the transcript Gemini returns.
    func discardRecording() {
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        fileURL = nil
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(0.08 * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        guard let recorder, recorder.isRecording, let startedAt else { return }

        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)
        level = Self.normalisedLevel(fromDB: power)

        let now = Date()
        let elapsed = now.timeIntervalSince(startedAt)

        if power > speechThresholdDB {
            lastSpeechAt = now
            if state == .listening {
                state = .capturing
            }
        }

        if elapsed >= maxDuration {
            finish()
            return
        }

        if let lastSpeechAt {
            // Heard something already — end the take on a trailing pause.
            if now.timeIntervalSince(lastSpeechAt) >= trailingSilence {
                finish()
            }
        } else if elapsed >= noSpeechTimeout {
            // Never heard anything at all.
            abort(reason: "Didn't catch that. Try again.")
        }
    }

    private func finish() {
        monitorTask?.cancel()
        monitorTask = nil
        recorder?.stop()
        recorder = nil
        deactivateSession()
        level = 0

        guard let fileURL,
              let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int,
              size > 1_024 else {
            abort(reason: "Didn't catch that. Try again.")
            return
        }

        state = .finished(fileURL)
    }

    private func abort(reason: String) {
        monitorTask?.cancel()
        monitorTask = nil
        recorder?.stop()
        recorder = nil
        deactivateSession()
        discardRecording()
        level = 0
        state = .failed(reason)
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Maps dBFS onto 0…1 with a floor, so the meter reads sensibly rather than
    /// hugging zero the way a linear conversion would.
    private static func normalisedLevel(fromDB db: Float) -> Double {
        let floor: Float = -50
        guard db > floor else { return 0 }
        return Double((db - floor) / -floor)
    }
}
