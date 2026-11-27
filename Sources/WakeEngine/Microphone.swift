import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import CSherpa

private func microphonePermission() throws {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return
    case .notDetermined:
        // The published contract is synchronous. AVFoundation delivers this completion on an
        // arbitrary queue; waiting here keeps start's permission error synchronous as promised.
        let result = PermissionResult()
        AVCaptureDevice.requestAccess(for: .audio) { granted in result.finish(granted) }
        result.semaphore.wait()
        guard result.granted else { throw WakeEngineError.microphoneDenied }
    default: throw WakeEngineError.microphoneDenied
    }
}
private final class PermissionResult: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    var granted = false // publication synchronized by semaphore
    func finish(_ value: Bool) { granted = value; semaphore.signal() }
}

/// One microphone capture on one device, by Core Audio UID (`AudioInputs.choose`), through AVCaptureSession.
///
/// Not AVAudioEngine: on macOS its input and output nodes share one I/O unit, bound to an aggregate of the default
/// input and output. Pointing that unit at a chosen microphone fails (-10851, kAudioUnitErr_InvalidPropertyValue)
/// or leaves the input with no channels, so the tap never receives audio. AVCaptureSession opens exactly the chosen
/// device and converts to 16 kHz mono Float32 itself. Only copied Float samples escape the capture queue; bounded
/// admission keeps inference backlog from growing.
final class Capture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    /// The device's UID; nil means no allowed input exists, and start fails.
    let input: String?
    private let output = AVCaptureAudioDataOutput()
    private let lifecycle = NSRecursiveLock()
    private var stopped = false
    private let lock = NSLock()
    private var queued = 0
    private var accepting = true
    private var receive: (@Sendable (Clip) -> Void)?
    private let captureQueue = DispatchQueue(label: "heydot.capture", qos: .userInitiated)
    private let queue = DispatchQueue(label: "heydot.audio", qos: .userInitiated)

    init(input: String?) { self.input = input }

    func start(receive: @escaping @Sendable (Clip) -> Void) throws {
        lifecycle.lock(); defer { lifecycle.unlock() }
        guard !stopped else { throw CancellationError() }
        try microphonePermission()
        guard let uid = input else { throw WakeEngineError.engine(Self.noInputMessage) }
        guard let device = AVCaptureDevice(uniqueID: uid) else { throw WakeEngineError.engine("The microphone isn't connected") }
        let deviceInput: AVCaptureDeviceInput
        do { deviceInput = try AVCaptureDeviceInput(device: device) } catch { throw WakeEngineError.engine("Couldn't open the microphone") }
        output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
                                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                                AVLinearPCMIsBigEndianKey: false]
        session.beginConfiguration()
        guard session.canAddInput(deviceInput), session.canAddOutput(output) else {
            session.commitConfiguration(); throw WakeEngineError.engine("Couldn't open the microphone")
        }
        session.addInput(deviceInput); session.addOutput(output)
        session.commitConfiguration()
        self.receive = receive
        output.setSampleBufferDelegate(self, queue: captureQueue)
        session.startRunning()
        guard session.isRunning else { stop(); throw WakeEngineError.engine("Couldn't start the microphone") }
    }

    /// Runs on the capture queue: copies one 16 kHz mono buffer and queues it for processing.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        ListenerMeter.measure {
            lock.lock()
            guard accepting, queued < 8, let receive else { lock.unlock(); return }
            queued += 1; lock.unlock()
            var handedOff = false
            defer { if !handedOff { lock.lock(); queued -= 1; lock.unlock() } }
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
            let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            guard count > 0 else { return }
            var samples = [Float](repeating: 0, count: count)
            let status = samples.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            guard status == kCMBlockBufferNoErr else { return }
            handedOff = true
            let clip = samples
            queue.async {
                self.lock.lock(); let accepting = self.accepting; self.lock.unlock()
                if accepting { ListenerMeter.measure { receive(clip) } }
                self.lock.lock(); self.queued -= 1; self.lock.unlock()
            }
        }
    }

    func stop() {
        lifecycle.lock(); defer { lifecycle.unlock() }
        stopped = true
        lock.lock(); accepting = false; receive = nil; lock.unlock()
        output.setSampleBufferDelegate(nil, queue: nil)
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        session.inputs.forEach(session.removeInput); session.outputs.forEach(session.removeOutput)
        session.commitConfiguration()
    }
    deinit { stop() }
    static let noInputMessage = "No built-in microphone found. Choose a microphone in HeyDot Settings."
}

private final class LiveSession: @unchecked Sendable {
    // Native state is protected by decodeLock across replacement captures.
    let spotter: Spotter
    let stream: OpaquePointer
    // A stopped capture can still be finishing one queued block when its replacement starts.
    let decodeLock = NSLock()
    var elapsed = 0.0
    var lastMeter = -Double.infinity
    var lastWake = -Double.infinity
    init(_ settings: WakeSettings) throws {
        spotter = try Spotter(settings: settings, directory: ModelFiles.locate())
        stream = try spotter.stream()
    }
    deinit { SherpaOnnxDestroyOnlineStream(stream) }
}

@MainActor public final class WakeEngine: WakeListening {
    public private(set) var inputLevel: Float = -160
    public private(set) var isListening = false
    /// The chosen microphone's Core Audio UID; nil is the built-in microphone. Read on every (re)start.
    public var inputDeviceUID: String? {
        get { selection.uid }
        set { selection.uid = newValue }
    }
    private let selection: InputSelection
    private let supervisor: ListenerSupervisor
    private var generation = UUID()
    /// `log` receives one line per capture restart (sleep and wake, device or configuration change, stall) and
    /// when the microphone is released while the displays sleep or the screen is locked.
    public init(log: @escaping (String) -> Void = { _ in }) {
        let selection = InputSelection()
        self.selection = selection
        supervisor = ListenerSupervisor(resolveInput: { AudioInputs.current(preferredUID: selection.uid) }, log: log)
    }
    public func start(_ settings: WakeSettings, onWake: @escaping @MainActor (WakeEvent) -> Void) throws {
        stop()
        let session = try LiveSession(settings)
        let generation = UUID()
        self.generation = generation
        try supervisor.start { [weak self, session] samples in
            session.decodeLock.lock(); defer { session.decodeLock.unlock() }
            session.elapsed += Double(samples.count) / 16000
            let hits = session.spotter.accept(samples, stream: session.stream)
            let now = ProcessInfo.processInfo.systemUptime
            let fire = hits > 0 && now - session.lastWake >= 3
            if fire { session.lastWake = now }
            let meter = session.elapsed - session.lastMeter >= 0.1
            if meter { session.lastMeter = session.elapsed }
            if meter || fire {
                let peak = meter ? samples.reduce(Float(0)) { max($0, abs($1)) } : 0
                let level = 20 * log10(max(peak, 0.00000001))
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation, self.isListening else { return }
                    if meter { self.inputLevel = level }
                    if fire { onWake(WakeEvent(phrase: settings.phrase, at: Date())) }
                }
            }
        }
        isListening = true
    }
    public func stop() {
        generation = UUID(); supervisor.stop()
        isListening = false; inputLevel = -160
    }
}

@MainActor private final class InputSelection { var uid: String? }

private final class Recording: @unchecked Sendable {
    let lock = NSLock()
    let capture = Capture(input: AudioInputs.current(preferredUID: nil))
    var samples: Clip = []
    var speech = false, finished = false
    var silent = 0
    var continuation: CheckedContinuation<Clip, Error>?
    func finish(_ result: Result<Clip, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true; let continuation = continuation; self.continuation = nil
        lock.unlock()
        capture.stop()
        continuation?.resume(with: result)
    }
}

public final class Enroller: WakeEnrolling {
    public init() {}
    public func record(seconds: Double) async throws -> Clip {
        guard seconds.isFinite, seconds > 0, seconds <= 60 else { throw WakeEngineError.engine("Recording duration must be in (0, 60] seconds") }
        let recording = Recording()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                recording.lock.lock()
                if recording.finished { recording.lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                recording.continuation = continuation
                recording.lock.unlock()
                do {
                    try recording.capture.start { samples in
                        recording.lock.lock()
                        guard !recording.finished else { recording.lock.unlock(); return }
                        let remaining = max(0, Int(seconds * 16000) - recording.samples.count)
                        recording.samples.append(contentsOf: samples.prefix(remaining))
                        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(max(1, samples.count)))
                        if rms > 0.01 { recording.speech = true; recording.silent = 0 }
                        else if recording.speech { recording.silent += samples.count }
                        let done = recording.samples.count >= Int(seconds * 16000) || recording.silent >= 12800
                        let clip = done ? recording.samples : []
                        recording.lock.unlock()
                        if done { recording.finish(.success(clip)) }
                    }
                    // Also bound wall time when an input device stops delivering buffers.
                    DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak recording] in
                        guard let recording else { return }
                        recording.lock.lock(); let samples = recording.samples; recording.lock.unlock()
                        recording.finish(.success(samples))
                    }
                } catch { recording.finish(.failure(error)) }
            }
        } onCancel: { recording.finish(.failure(CancellationError())) }
    }
    /// Learns the token sequences the model hears in the user's takes that agree: every specific (long) reading, and
    /// a short one when it is how this user says it and the listener would miss that take without it
    /// (`Takes.specific`, `Takes.repeated`). Then it measures each clip's confidence (the highest threshold at which
    /// the keywords still fire) and puts the threshold between the strongest negative and the weakest take, leaning
    /// low because live speech scores below enrollment clips. A recorded negative is never answered: when
    /// the two overlap, the threshold goes above the negative and the missed positives are reported.
    public func calibrate(phrase: String, positives: [Clip], negatives: [Clip]) async throws -> Calibration {
        let task = Task.detached(priority: .userInitiated) {
            guard !positives.isEmpty else { throw WakeEngineError.engine("Record at least one positive clip") }
            let directory = try ModelFiles.locate()
            let tokenizer = try KeywordTokenizer(modelDirectory: directory)
            // One model at a time: the decoder is released before the probe spotter loads.
            let heard = try { let decoder = try PhraseDecoder(directory: directory); return positives.map { decoder.pieces($0).filter(tokenizer.knows) } }()
            let defaults = WakeSettings()
            var settings = WakeSettings(phrase: phrase, score: defaults.score, threshold: defaults.threshold)
            // A throwaway base keyword: sherpa-onnx appends the spotter's own keywords to every probe stream.
            let probe = try Spotter(keywords: [try tokenizer.pieces(for: "zebra quartz xylophone")], score: 1,
                                    threshold: 0.99, directory: directory)
            let agreeing = Takes.agreeing(heard)
            for i in agreeing {
                try Task.checkCancellation()
                let line = heard[i].joined(separator: " ")
                guard !settings.learned.contains(line) else { continue }
                if Takes.specific(heard[i]) { settings.learned.append(line); continue }
                guard Takes.repeated(heard[i], among: agreeing.map { heard[$0] }),
                      !probe.fires(positives[i], keywords: try Spotter.keywords(settings, tokenizer: tokenizer),
                                   score: settings.score, threshold: defaults.threshold) else { continue }
                settings.learned.append(line)
            }
            let keywords = try Spotter.keywords(settings, tokenizer: tokenizer)
            try Task.checkCancellation()
            let (weakest, firing) = probe.weakest(positives, keywords: keywords, score: settings.score)
            try Task.checkCancellation()
            let worst = probe.strongest(negatives, keywords: keywords, score: settings.score)
            settings.threshold = Self.threshold(weakest: weakest, worst: worst)
            // Above the weakest positive only when that keeps a margin over a recorded negative: recount then.
            let caught = settings.threshold <= (weakest ?? 0) ? firing
                : positives.filter { probe.fires($0, keywords: keywords, score: settings.score, threshold: settings.threshold) }.count
            let falseHits = worst >= settings.threshold ? 1 : 0
            let note = caught == positives.count && falseHits == 0
                ? "Caught \(caught) of \(positives.count), no false hits."
                : "Caught \(caught) of \(positives.count) with \(falseHits) false hits."
            return Calibration(settings: settings, caught: caught, falseHits: falseHits, note: note)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    /// Margin above a recorded negative; the confidence bisection resolves about 0.015.
    static let margin: Float = 0.03
    static func threshold(weakest: Float?, worst: Float) -> Float {
        guard let weakest else { return max(WakeSettings().threshold, worst + margin) }
        guard weakest >= worst + 2 * margin else { return min(1, worst + margin) }
        return min(weakest, max(0.05, worst + margin, worst + 0.4 * (weakest - worst)))
    }
}
