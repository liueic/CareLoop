import Foundation
import UIKit

enum MedicalDocumentAnalyzer {

    static func analyze(
        image: UIImage,
        docHint: String,
        llm: any LLMProviding
    ) async throws -> MedicalDocResult {
        let ocrText = await OCRService.recognize(image: image)

        let system = """
        你是一名医疗文档结构化提取助手。请根据 OCR 提取的文本（以及图片，如果可见）分析这份\(docHint)，\
        提取以下信息并以 JSON 返回。

        返回格式（严格 JSON，不要 markdown 代码块）：
        {
          "docType": "\(docHint)",
          "title": "文档标题或简要名称，可为 null",
          "takenAt": "日期 YYYY-MM-DD 或 null",
          "diagnoses": ["诊断1", "诊断2"],
          "labValues": [
            {"name": "指标名", "value": "数值", "unit": "单位或null", "reference": "参考范围或null", "flag": "high/low/normal/null"}
          ],
          "medications": [
            {"name": "药名", "dose": "剂量或null", "frequency": "频次描述如每日2次或null", "timesOfDay": ["08:00", "20:00"], "frequencyPerDay": 2, "cautions": "注意事项或null"}
          ],
          "recommendations": ["建议1", "建议2"],
          "followUpHint": "复诊提示原文或null",
          "followUpDate": "复诊日期 YYYY-MM-DD 或 null",
          "followUpDepartment": "复诊科室或null",
          "summary": "一句话总结"
        }

        如果某字段在文档中找不到，数组返回 []，字符串返回 null。
        flag 规则：数值高于参考范围 → "high"，低于 → "low"，在范围内 → "normal"。
        用药 timesOfDay：从频次或医嘱推断具体服药时间。每日1次默认 ["08:00"]，每日2次默认 ["08:00", "20:00"]，每日3次默认 ["08:00", "14:00", "20:00"]。如有明确时间则用文档中的。
        frequencyPerDay：从频次文本提取数字，如"每日2次"→2，"bid"→2，"tid"→3。
        followUpDate：从复诊提示中推算具体日期。如"两周后"则从 takenAt 起算。
        不要编造文档中不存在的信息。
        """

        var userText = "OCR 提取的文本：\n\(ocrText.isEmpty ? "（无法识别文字，请仅根据图片分析）" : ocrText)"
        if !docHint.isEmpty {
            userText += "\n\n文档类型提示：\(docHint)"
        }

        var images: [Data] = []
        if llm.supportsVision, let jpeg = image.jpegData(compressionQuality: 0.7) {
            images = [jpeg]
        }

        let prompt = LLMPrompt(
            system: system,
            user: userText,
            images: images,
            maxTokens: 1200
        )

        let completion = try await llm.complete(prompt: prompt)
        return try parse(completion.text)
    }

    private static func parse(_ text: String) throws -> MedicalDocResult {
        if let dict = LLMJSON.object(from: text),
           let data = try? JSONSerialization.data(withJSONObject: dict) {
            if let result = try? JSONDecoder().decode(MedicalDocResult.self, from: data) {
                return result
            }
        }
        throw LLMError.invalidResponse
    }
}
