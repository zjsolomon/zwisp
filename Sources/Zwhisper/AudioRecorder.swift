import AVFoundation
import ZwhisperCore

/// Captures microphone audio and resamples it to the mono Float32 format
/// (16 kHz by default) that WhisperKit expects.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private var isRunning = false
    // Guards `samples`, which is written on the realtime audio thread and read
    // from the main thread in stop().
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

    func requestPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted { NSLog("Zwhisper: microphone permission denied") }
        }
    }

    func start() {
        guard !isRunning else { return }
        lock.lock()
        samples.removeAll(keepingCapacity: true)
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

    /// Stops capture and returns the recorded samples at 16 kHz mono.
    func stop() -> [Float] {
        guard isRunning else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        lock.lock()
        let result = samples
        lock.unlock()
        return result
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
            NSLog("Zwhisper: audio convert error: \(error)")
            return
        }

        if let channel = out.floatChannelData {
            let count = Int(out.frameLength)
            lock.lock()
            samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: count))
            lock.unlock()
        }
    }
}
