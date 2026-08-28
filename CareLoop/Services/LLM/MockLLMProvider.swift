import Foundation

struct MockLLMProvider: LLMProviding {
    var supportsVision: Bool { true }

    func complete(prompt: LLMPrompt) async throws -> LLMCompletion {
        if prompt.user.contains("OCR 提取的文本") || prompt.system.contains("医疗文档") {
            return medicalDocResponse()
        }
        if prompt.user.contains("饮食照片") || prompt.system.contains("食物") {
            return foodResponse()
        }
        let ids = prompt.user
            .split(separator: "\n")
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("- ") else { return nil }
                let rest = trimmed.dropFirst(2)
                return rest.split(separator: " ").first.map(String.init)
            }
        let cited = Array(ids.prefix(2))
        let names = cited.joined(separator: "、")
        let body: String
        if prompt.user.contains("饮食") {
            body = "建议从候选中选择 \(names)。烹调少盐少糖，口味按你的辣度偏好来。这不是医疗建议。"
        } else {
            body = "建议从候选中选择 \(names)，保持能够对话的强度。出现胸痛或严重不适请停止并就医。"
        }
        let json = """
        {"title":"本地模板建议","body":"\(body)","citedIDs":\(jsonArray(cited))}
        """
        return LLMCompletion(text: json, modelID: "mock-template")
    }

    func listModels() async throws -> [String] { ["mock-template"] }

    func ping(modelID: String) async throws -> TimeInterval { 0.05 }

    private func foodResponse() -> LLMCompletion {
        let json = """
        {"label":"清蒸鱼+米饭","explanation":"低盐清淡，适合控压饮食"}
        """
        return LLMCompletion(text: json, modelID: "mock-template")
    }

    private func medicalDocResponse() -> LLMCompletion {
        let json = """
        {"docType":"检验报告","title":"血常规+生化","takenAt":"2026-08-20","diagnoses":["2型糖尿病","高血压2级"],"labValues":[{"name":"空腹血糖","value":"8.9","unit":"mmol/L","reference":"3.9–6.1","flag":"high"},{"name":"糖化血红蛋白","value":"7.8","unit":"%","reference":"4.0–6.0","flag":"high"},{"name":"收缩压","value":"152","unit":"mmHg","reference":"<140","flag":"high"},{"name":"血钾","value":"3.6","unit":"mmol/L","reference":"3.5–5.5","flag":null}],"medications":[{"name":"二甲双胍","dose":"500mg","frequency":"每日2次","timesOfDay":["08:00","18:00"],"frequencyPerDay":2,"cautions":"随餐服用"},{"name":"氨氯地平","dose":"5mg","frequency":"每日1次","timesOfDay":["08:00"],"frequencyPerDay":1,"cautions":"晨起"}],"recommendations":["两周后复查空腹血糖","低盐低脂饮食","每日监测血压"],"followUpHint":"两周后内分泌科复诊","followUpDate":"2026-09-03","followUpDepartment":"内分泌科","summary":"血糖控制欠佳，血压偏高，建议调整用药并加强监测"}
        """
        return LLMCompletion(text: json, modelID: "mock-template")
    }

    private func jsonArray(_ ids: [String]) -> String {
        let inner = ids.map { "\"\($0)\"" }.joined(separator: ",")
        return "[\(inner)]"
    }
}
