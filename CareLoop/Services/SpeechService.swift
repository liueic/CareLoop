import AVFoundation
import Foundation
import OpenAI

@MainActor
final class SpeechService {
    private let engine = AVAudioEngine()
    private var audioBuffer = Data()
    private var baseURL: URL?
    private var apiKey: String?
    private var isRecording = false
    private var converter: AVAudioConverter?
    /// 实际写入 WAV 头的采样率——必须与 tap 产出的数据一致。
    private var activeSampleRate: Double = 16000

    func configure(baseURL: URL?, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    func requestAccess() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func start(onPartial: @escaping @MainActor (String) -> Void) throws {
        haltRecording()
        audioBuffer = Data()
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        let input = engine.inputNode
        let nativeFormat = input.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1) else {
            throw NSError(domain: "CareLoop.Speech", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建 16kHz 目标格式"])
        }
        activeSampleRate = 16000

        if nativeFormat.sampleRate == targetFormat.sampleRate, nativeFormat.channelCount == targetFormat.channelCount {
            installTap(format: nativeFormat, convertingTo: nil)
        } else {
            // 硬件原生采样率（iPhone 通常 48kHz）必须实时重采样到 16kHz 单声道，
            // 否则 WAV 头与数据错配，音频被拉长变调，转写质量明显受损。
            converter = AVAudioConverter(from: nativeFormat, to: targetFormat)
            installTap(format: nativeFormat, convertingTo: targetFormat)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    func stop() async -> String? {
        guard isRecording else { return nil }
        haltRecording()

        let recordedData = audioBuffer
        audioBuffer = Data()
        guard !recordedData.isEmpty else { return nil }

        let wavData = encodeWAV(
            pcmData: recordedData,
            sampleRate: Int(activeSampleRate),
            channels: 1,
            bitsPerSample: 16
        )
        return await transcribe(audioData: wavData)
    }

    private func haltRecording() {
        guard isRecording else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        converter = nil
        isRecording = false
    }

    private func installTap(format: AVAudioFormat, convertingTo targetFormat: AVAudioFormat?) {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let pcm: AVAudioPCMBuffer
            if let targetFormat, let converter = self.converter {
                pcm = Self.convert(buffer, with: converter, to: targetFormat) ?? buffer
            } else {
                pcm = buffer
            }
            guard let channel = pcm.floatChannelData?[0] else { return }
            let frameCount = Int(pcm.frameLength)
            var samples = [Int16](repeating: 0, count: frameCount)
            for index in 0..<frameCount {
                let clamped = max(-1.0, min(1.0, Float(channel[index])))
                samples[index] = Int16(clamped * Float(Int16.max))
            }
            let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
            Task { @MainActor in
                self.audioBuffer.append(data)
            }
        }
    }

    /// 单次把一个 native 缓冲区完整转换为 16kHz 单声道。
    private nonisolated static func convert(
        _ input: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var error: NSError?
        var inputExhausted = false
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if inputExhausted {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputExhausted = true
            outStatus.pointee = .haveData
            return input
        }
        guard error == nil, status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    private func transcribe(audioData: Data) async -> String? {
        guard let baseURL else {
            return mockTranscribe()
        }
        let client = OpenAI(
            configuration: OpenAIProvider.makeConfiguration(baseURL: baseURL, apiKey: apiKey ?? "")
        )
        do {
            let result = try await client.audioTranscriptions(
                query: AudioTranscriptionQuery(
                    file: audioData,
                    fileType: .wav,
                    model: "whisper-1",
                    language: "zh"
                )
            )
            return result.text
        } catch {
            return nil
        }
    }

    private func mockTranscribe() -> String? {
        "这是一段模拟的语音转写结果，用于本地测试。"
    }

    private func encodeWAV(pcmData: Data, sampleRate: Int, channels: Int, bitsPerSample: Int) -> Data {
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = pcmData.count

        var header = Data()
        header.append("RIFF".data(using: .ascii)!)
        header.append(UInt32(36 + dataSize).littleEndianBytes)
        header.append("WAVE".data(using: .ascii)!)
        header.append("fmt ".data(using: .ascii)!)
        header.append(UInt32(16).littleEndianBytes)
        header.append(UInt16(1).littleEndianBytes)
        header.append(UInt16(channels).littleEndianBytes)
        header.append(UInt32(sampleRate).littleEndianBytes)
        header.append(UInt32(byteRate).littleEndianBytes)
        header.append(UInt16(blockAlign).littleEndianBytes)
        header.append(UInt16(bitsPerSample).littleEndianBytes)
        header.append("data".data(using: .ascii)!)
        header.append(UInt32(dataSize).littleEndianBytes)
        header.append(pcmData)
        return header
    }
}

private extension UInt32 {
    var littleEndianBytes: Data {
        var value = self.littleEndian
        return Data(bytes: &value, count: MemoryLayout<UInt32>.size)
    }
}

private extension UInt16 {
    var littleEndianBytes: Data {
        var value = self.littleEndian
        return Data(bytes: &value, count: MemoryLayout<UInt16>.size)
    }
}
