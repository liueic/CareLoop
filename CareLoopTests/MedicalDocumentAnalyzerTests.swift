import Foundation
import Testing
import UIKit

@testable import CareLoop

/// 记录 prompt 并回放固定回复的打桩 Provider（沿用 DietAgentStreamingTests 的脚本化模式）。
final class ScriptedDocLLMProvider: LLMProviding, @unchecked Sendable {
    var supportsVision: Bool
    var responseText: String
    private(set) var receivedPrompts: [LLMPrompt] = []

    init(supportsVision: Bool = false, responseText: String) {
        self.supportsVision = supportsVision
        self.responseText = responseText
    }

    func complete(prompt: LLMPrompt) async throws -> LLMCompletion {
        receivedPrompts.append(prompt)
        return LLMCompletion(text: responseText, modelID: "stub")
    }

    func completeConversation(_ request: LLMConversationRequest) async throws -> LLMConversationResponse {
        LLMConversationResponse(
            message: LLMChatMessage(role: "assistant", content: responseText, toolCallID: nil, toolCalls: []),
            modelID: "stub",
            finishReason: "stop"
        )
    }

    func listModels() async throws -> [String] { [] }

    func ping(modelID: String) async throws -> TimeInterval { 0.1 }
}

/// 医疗文档结构化解析：处方新字段、围栏容错、坏 JSON 报错、vision 附图行为、prompt 组装。
struct MedicalDocumentAnalyzerTests {
    private let prescriptionJSON = """
    {
      "docType": "处方单",
      "title": "门诊处方",
      "takenAt": "2026-08-20",
      "diagnoses": ["高血压2级"],
      "labValues": [],
      "medications": [
        {"name": "苯磺酸氨氯地平片", "dose": "5mg", "frequency": "每日1次，晨起", "timesOfDay": ["08:00"],
         "frequencyPerDay": 1, "cautions": "避免柚子", "spec": "5mg×28片", "quantity": "1盒", "durationText": "30天"}
      ],
      "recommendations": [],
      "followUpHint": null, "followUpDate": null, "followUpDepartment": null,
      "summary": "高血压处方",
      "hospitalName": "市第一人民医院",
      "doctorName": "王医生"
    }
    """

    private func makeImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12)).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
        }
    }

    @Test func parsesPrescriptionFields() async throws {
        let stub = ScriptedDocLLMProvider(responseText: prescriptionJSON)
        let result = try await MedicalDocumentAnalyzer.analyze(image: makeImage(), docHint: "处方单", llm: stub)
        let med = try #require(result.medications.first)
        #expect(med.name == "苯磺酸氨氯地平片")
        #expect(med.spec == "5mg×28片")
        #expect(med.quantity == "1盒")
        #expect(med.durationText == "30天")
        #expect(result.hospitalName == "市第一人民医院")
        #expect(result.doctorName == "王医生")
    }

    @Test func toleratesMarkdownFence() async throws {
        let fenced = "```json\n\(prescriptionJSON)\n```"
        let stub = ScriptedDocLLMProvider(responseText: fenced)
        let result = try await MedicalDocumentAnalyzer.analyze(image: makeImage(), docHint: "处方单", llm: stub)
        #expect(result.medications.count == 1)
    }

    @Test func invalidJSONThrows() async {
        let stub = ScriptedDocLLMProvider(responseText: "这不是 JSON")
        await #expect(throws: LLMError.self) {
            _ = try await MedicalDocumentAnalyzer.analyze(image: makeImage(), docHint: "处方单", llm: stub)
        }
    }

    @Test func visionDisabledSendsNoImage() async throws {
        let stub = ScriptedDocLLMProvider(supportsVision: false, responseText: prescriptionJSON)
        _ = try await MedicalDocumentAnalyzer.analyze(image: makeImage(), docHint: "处方单", llm: stub)
        #expect(stub.receivedPrompts.count == 1)
        #expect(stub.receivedPrompts[0].images.isEmpty)
    }

    @Test func visionEnabledAttachesImage() async throws {
        let stub = ScriptedDocLLMProvider(supportsVision: true, responseText: prescriptionJSON)
        _ = try await MedicalDocumentAnalyzer.analyze(image: makeImage(), docHint: "处方单", llm: stub)
        #expect(stub.receivedPrompts[0].images.count == 1)
    }

    @Test func promptIncludesOCRTextAndDocHint() async throws {
        let stub = ScriptedDocLLMProvider(responseText: prescriptionJSON)
        _ = try await MedicalDocumentAnalyzer.analyze(image: makeImage(), docHint: "处方单", llm: stub)
        let prompt = stub.receivedPrompts[0]
        #expect(prompt.user.contains("OCR 提取的文本"))
        #expect(prompt.user.contains("处方单"))
    }

    @Test func prescriptionHintAddsAntiHallucinationInstructions() async throws {
        let stub = ScriptedDocLLMProvider(responseText: prescriptionJSON)
        _ = try await MedicalDocumentAnalyzer.analyze(image: makeImage(), docHint: "处方单", llm: stub)
        #expect(stub.receivedPrompts[0].system.contains("处方类文档补充要求"))
        #expect(stub.receivedPrompts[0].system.contains("禁止根据药品外观推测药名"))

        let plain = ScriptedDocLLMProvider(responseText: prescriptionJSON)
        _ = try await MedicalDocumentAnalyzer.analyze(image: makeImage(), docHint: "检验报告", llm: plain)
        #expect(!plain.receivedPrompts[0].system.contains("处方类文档补充要求"))
    }
}
