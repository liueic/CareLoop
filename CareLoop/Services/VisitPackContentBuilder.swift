import Foundation

struct VisitPackSection: Sendable {
    var title: String
    var body: String
}

enum VisitPackContentBuilder {
    static let exportBrand = "Exported by CareLoop"

    static func buildSections(_ input: VisitPackInput) -> [VisitPackSection] {
        var sections: [VisitPackSection] = []
        sections.append(metaSection(exportedAt: Date()))
        sections.append(profileSection(input.profile))
        if let followUp = input.followUp {
            sections.append(followUpSection(followUp))
        }
        sections.append(contentsOf: medicationSections(input.medications, adherence: input.adherence))
        sections.append(contentsOf: alertSections(input.alerts))
        sections.append(journalSection(input.logs))
        if !input.reports.isEmpty {
            sections.append(
                VisitPackSection(
                    title: "附：医院报告照片",
                    body: "共 \(input.reports.count) 张，详见下文。"
                )
            )
        }
        return sections.filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    static func metaSection(exportedAt: Date) -> VisitPackSection {
        VisitPackSection(
            title: "材料说明",
            body: """
            生成时间：\(exportedAt.formatted(date: .long, time: .shortened))
            来源：CareLoop 本地健康手帐与用药记录
            用途：就诊时携带参考，供医生了解近期情况
            """
        )
    }

    static func profileSection(_ profile: UserProfile) -> VisitPackSection {
        var lines: [String] = []
        if !profile.conditions.isEmpty {
            lines.append("慢病/状况：\(profile.conditions.joined(separator: "、"))")
        }
        if let birthDate = profile.birthDate {
            let age = Calendar.current.dateComponents([.year], from: birthDate, to: Date()).year ?? 0
            if age > 0 { lines.append("年龄：\(age) 岁") }
        }
        if profile.biologicalSex != .unspecified {
            lines.append("生理性别：\(profile.biologicalSex.rawValue)")
        }
        if !profile.drugAllergies.isEmpty {
            lines.append("药物过敏：\(profile.drugAllergies.joined(separator: "、"))")
        }
        if !profile.foodAllergies.isEmpty {
            lines.append("食物过敏：\(profile.foodAllergies.joined(separator: "、"))")
        }
        if !profile.doctorRestrictions.isEmpty {
            lines.append("医生限制事项：\(profile.doctorRestrictions.joined(separator: "、"))")
        }
        if !profile.regionProvince.isEmpty {
            let region = [profile.regionProvince, profile.regionCity].filter { !$0.isEmpty }.joined(separator: " ")
            lines.append("常居地：\(region)")
        }
        if lines.isEmpty {
            lines.append("尚未填写完整健康画像，可在「我的」中补充。")
        }
        return VisitPackSection(title: "健康画像", body: lines.joined(separator: "\n"))
    }

    static func followUpSection(_ followUp: FollowUp) -> VisitPackSection {
        var lines = [
            "复诊日期：\(followUp.date.formatted(date: .long, time: .shortened))",
            "科室：\(followUp.department)",
        ]
        if !followUp.doctorName.isEmpty { lines.append("医生：\(followUp.doctorName)") }
        if !followUp.hospital.isEmpty { lines.append("医院：\(followUp.hospital)") }
        if !followUp.effectiveRestrictions.isEmpty {
            lines.append("复诊前禁忌：\(FollowUpService.joinList(followUp.effectiveRestrictions))")
        }
        if !followUp.effectiveMaterials.isEmpty {
            lines.append("需要携带：\(FollowUpService.joinList(followUp.effectiveMaterials))")
        }
        if !followUp.notes.isEmpty { lines.append("备注：\(followUp.notes)") }
        return VisitPackSection(title: "复诊安排", body: lines.joined(separator: "\n"))
    }

    static func medicationSections(_ medications: [Medication], adherence: AdherenceSummary) -> [VisitPackSection] {
        let active = medications.filter { $0.isActive && $0.confirmedByUser }
        guard !active.isEmpty else {
            return [VisitPackSection(title: "当前用药", body: "暂无已确认的用药记录。")]
        }
        let medLines = active.map { med -> String in
            var parts = [
                "· \(med.name)",
                "每次 \(med.dosePerTime)",
                "每日 \(med.frequencyPerDay) 次",
                "时间 \(med.timesOfDay.joined(separator: " / "))",
            ]
            if !med.periodText.isEmpty { parts.append("周期 \(med.periodText)") }
            if !med.cautions.isEmpty { parts.append("注意 \(med.cautions)") }
            parts.append("来源 \(med.source.rawValue)")
            return parts.joined(separator: "；")
        }
        return [
            VisitPackSection(title: "当前用药清单", body: medLines.joined(separator: "\n")),
            VisitPackSection(
                title: "近 \(adherence.windowDays) 日服药打卡",
                body: "已服 \(adherence.taken) 次 / 应服 \(adherence.expected) 次（\(adherence.percentText)）"
            ),
        ]
    }

    static func alertSections(_ alerts: [AlertRecord]) -> [VisitPackSection] {
        guard !alerts.isEmpty else {
            return [VisitPackSection(title: "近期健康提示", body: "近 7 日暂无需要特别说明的提示。")]
        }
        let sorted = alerts.sorted { $0.createdAt > $1.createdAt }.prefix(8)
        let guideline = sorted.filter { $0.title.contains("指南评估") }
        let others = sorted.filter { !$0.title.contains("指南评估") }
        var sections: [VisitPackSection] = []
        if !guideline.isEmpty {
            sections.append(VisitPackSection(title: "指南评估摘要", body: alertBlock(Array(guideline))))
        }
        if !others.isEmpty {
            sections.append(VisitPackSection(title: "近期异常与提示", body: alertBlock(Array(others))))
        }
        return sections
    }

    static func journalSection(_ logs: [DailyLogEntry]) -> VisitPackSection {
        guard !logs.isEmpty else {
            return VisitPackSection(title: "近 7 日手帐记录", body: "暂无手帐条目。")
        }
        let sorted = logs.sorted { $0.createdAt > $1.createdAt }.prefix(12)
        let lines = sorted.map { entry -> String in
            let date = entry.createdAt.formatted(date: .abbreviated, time: .shortened)
            let kind = journalKindLabel(entry.kind)
            let tags = entry.tags.isEmpty ? "" : "［\(entry.tags.joined(separator: "、"))］"
            let body = entry.displayBody.replacingOccurrences(of: "\n", with: " ")
            return "· \(date) \(kind)\(tags) \(body)"
        }
        var text = lines.joined(separator: "\n")
        let symptoms = logs.flatMap(\.symptoms)
        if !symptoms.isEmpty {
            let symptomText = symptoms.prefix(8).map { "\($0.name)（\($0.severity.rawValue)）" }.joined(separator: "、")
            text += "\n\n症状记录：\(symptomText)"
        }
        text += "\n\n手帐条目共 \(logs.count) 条（近 7 日）"
        return VisitPackSection(title: "近 7 日手帐记录", body: text)
    }

    static func plainText(_ input: VisitPackInput, exportedAt: Date = Date()) -> String {
        var lines = [
            "CareLoop 就诊材料",
            exportBrand,
            "生成时间：\(exportedAt.formatted(date: .long, time: .shortened))",
            "",
        ]
        for section in buildSections(input) {
            lines.append("【\(section.title)】")
            lines.append(section.body)
            lines.append("")
        }
        if !input.reports.isEmpty {
            lines.append("【附：医院报告照片】")
            lines.append("共 \(input.reports.count) 张（PDF 版含图片）")
            lines.append("")
        }
        lines.append(exportBrand)
        return lines.joined(separator: "\n")
    }

    private static func alertBlock(_ alerts: [AlertRecord]) -> String {
        alerts.map { alert in
            var lines = [
                "· \(alert.createdAt.formatted(date: .abbreviated, time: .omitted)) \(alert.tier.rawValue) \(alert.title)",
                "  变化：\(alert.whatChanged)",
            ]
            if !alert.suggestedAction.isEmpty {
                lines.append("  建议：\(alert.suggestedAction)")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private static func journalKindLabel(_ kind: LogKind) -> String {
        switch kind {
        case .photo: return "照片"
        case .voice: return "语音"
        case .text: return "文字"
        case .quickTag: return "标签"
        case .symptom: return "症状"
        case .medicalDoc: return "病历"
        }
    }
}
