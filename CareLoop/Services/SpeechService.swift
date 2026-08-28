import AVFoundation
import Foundation

@MainActor
final class SpeechService {
    private let engine = AVAudioEngine()
    private var audioBuffer = Data()
    private var baseURL: URL?
    private var apiKey: String?
    private var isRecording = false

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
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let audioData = buffer.audioBufferList.pointee.mBuffers
            if let ptr = audioData.mData {
                let data = Data(bytes: ptr, count: Int(audioData.mDataByteSize))
                Task { @MainActor in
                    self.audioBuffer.append(data)
                }
            }
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

        let wavData = encodeWAV(pcmData: recordedData, sampleRate: 16000, channels: 1, bitsPerSample: 16)
        return await transcribe(audioData: wavData, mimeType: "audio/wav", fileName: "recording.wav")
    }

    private func haltRecording() {
        guard isRecording else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        isRecording = false
    }

    private func transcribe(audioData: Data, mimeType: String, fileName: String) async -> String? {
        guard let baseURL else {
            return mockTranscribe()
        }
        let url = baseURL.appendingPathComponent("audio/transcriptions")
        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 30

        var body = Data()
        body.appendMultipart(name: "model", value: "whisper-1", boundary: boundary)
        body.appendMultipart(name: "language", value: "zh", boundary: boundary)
        body.appendFilePart(name: "file", filename: fileName, mimeType: mimeType, data: audioData, boundary: boundary)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            let decoded = try JSONDecoder().decode(WhisperResponse.self, from: data)
            return decoded.text
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

private struct WhisperResponse: Decodable {
    var text: String
}

private extension Data {
    mutating func appendMultipart(name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }

    mutating func appendFilePart(name: String, filename: String, mimeType: String, data: Data, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
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
