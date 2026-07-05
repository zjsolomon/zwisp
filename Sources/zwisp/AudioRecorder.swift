import Accelerate
import AVFoundation
import ZwispCore

/// Captures microphone audio and resamples it to the mono Float32 format
/// (16 kHz by default) that WhisperKit expects.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    // Most recent per-buffer mean-square (RMS²) of captured audio, written on the
    // realtime audio thread and read at animation rate on main via `currentLevel()`.
    private var latestPower: Float = 0
    private var isRunning = false
    // Guards `samples` and `latestPower`, both written on the realtime audio
    // thread and read from the main thread (in stop()/snapshot() and
    // currentLevel() respectively).
    private let lock = NSLock()

    private let targetFormat: AVAudioFormat

    init(config: Configuration.Audio = Configuration.Audio()) {
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: config.sampleRate,
            channels: 1,
            interleaved: false
        )!
    }

    func start() {
        guard !isRunning else { return }
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        latestPower = 0
        lock.unlock()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        Log.write("audio start: input sr=\(inputFormat.sampleRate) ch=\(inputFormat.channelCount)")
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        if converter == nil {
            Log.write("AVAudioConverter is NIL — bad input format (mic permission?)")
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
            isRunning = true
            Log.write("audio engine started")
        } catch {
            Log.write("audio engine FAILED to start: \(error)")
        }
    }

    /// A copy of everything recorded so far, without stopping capture — the
    /// streaming worker's view of the growing buffer. Same lock discipline as
    /// stop(): `samples` is written on the realtime audio thread.
    func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    /// Stops capture and returns the recorded samples at 16 kHz mono.
    func stop() -> [Float] {
        guard isRunning else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        lock.lock()
        let result = samples
        latestPower = 0
        lock.unlock()
        return result
    }

    /// The current microphone level as an RMS amplitude (√ of the latest
    /// per-buffer mean-square). O(1) — reads a single cached Float under the
    /// lock; called by the dictation overlay at ~30 Hz on the main thread.
    func currentLevel() -> Float {
        lock.lock()
        defer { lock.unlock() }
        return latestPower.squareRoot()
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var fedInput = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fedInput {
                status.pointee = .noDataNow
                return nil
            }
            fedInput = true
            status.pointee = .haveData
            return buffer
        }

        if let error {
            NSLog("zwisp: audio convert error: \(error)")
            return
        }

        if let channel = out.floatChannelData {
            let count = Int(out.frameLength)
            // Compute this buffer's mean-square (RMS²) on the stack, before
            // taking the lock, so the realtime path does no work inside the
            // critical section beyond the existing append plus one Float store.
            var meanSquare: Float = 0
            if count > 0 {
                vDSP_measqv(channel[0], 1, &meanSquare, vDSP_Length(count))
            }
            lock.lock()
            samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: count))
            latestPower = meanSquare
            lock.unlock()
        }
    }
}
