import SwiftData
import SwiftUI

/// 处方识别结果传递到核对表单的载体。
struct PrescriptionDraft: Identifiable {
    let id = UUID()
    var result: MedicalDocResult
    var image: UIImage?
    /// 离线/降级路径（启发式 OCR 粗识别）时为 true，表单顶部显示警示。
    var degraded = false
}

/// 药房处方识别结果的**可编辑**核对表单：用户逐项确认/修改后才写入用药列表，
/// 同时把处方照片与结构化结果存入手帐（复诊资料包自动带上处方照片）。
/// 与化验单走同一 `kind == .medicalDoc` 存储，识别结果统一由一条链路沉淀。
struct PrescriptionReviewSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let draft: PrescriptionDraft

    struct MedRow: Identifiable {
        let id = UUID()
        var selected: Bool
        var name: String
        var spec: String
        var dose: String
        var frequency: Int
        var sig: String
        var cautions: String
        var durationText: String
        var existsAlready: Bool
    }

    @State private var rows: [MedRow] = []
    @State private var prescribedDate = Date()

    var body: some View {
        NavigationStack {
            Form {
                if draft.degraded {
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(CareTheme.warn)
                            Text("离线粗识别，质量有限，请逐项仔细核对。")
                                .font(.caption)
                        }
                    }
                }
                Section("处方信息") {
                    if let hospital = draft.result.hospitalName, !hospital.isEmpty {
                        LabeledContent("医院/药房", value: hospital)
                    }
                    if let doctor = draft.result.doctorName, !doctor.isEmpty {
                        LabeledContent("医师", value: doctor)
                    }
                    DatePicker("处方日期", selection: $prescribedDate, displayedComponents: .date)
                }
                Section("药品（勾选后导入）") {
                    ForEach($rows) { $row in
                        MedRowEditor(row: $row)
                    }
                }
                Section {
                    Text("由 AI 识别，请逐项核对后再保存；识别结果不构成用药指导，具体请遵医嘱。")
                        .font(.caption)
                        .foregroundStyle(CareTheme.muted)
                }
            }
            .navigationTitle("核对处方")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(!rows.contains(where: \.selected))
                }
            }
            .onAppear(perform: buildRows)
        }
    }

    // MARK: - 行编辑

    private struct MedRowEditor: View {
        @Binding var row: MedRow

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $row.selected) {
                    HStack(spacing: 6) {
                        TextField("药品名", text: $row.name)
                            .font(.headline)
                        if row.existsAlready {
                            Text("已存在·跳过")
                                .font(.caption2)
                                .foregroundStyle(CareTheme.warn)
                        }
                    }
                }
                .toggleStyle(.switch)
                if row.selected {
                    HStack(spacing: 12) {
                        TextField("规格", text: $row.spec)
                        TextField("每次剂量", text: $row.dose)
                    }
                    .font(.subheadline)
                    Picker("频次", selection: $row.frequency) {
                        Text("1次/日").tag(1)
                        Text("2次/日").tag(2)
                        Text("3次/日").tag(3)
                        Text("4次/日").tag(4)
                    }
                    .pickerStyle(.segmented)
                    TextField("用法（如 每日3次，餐前）", text: $row.sig)
                        .font(.subheadline)
                    Text("服药时间：\(PrescriptionParser.timesOfDay(frequency: row.frequency, sig: row.sig).joined(separator: " / "))")
                        .font(.caption)
                        .foregroundStyle(CareTheme.muted)
                    TextField("注意事项", text: $row.cautions)
                        .font(.subheadline)
                    TextField("疗程（如 7天，留空为长期）", text: $row.durationText)
                        .font(.subheadline)
                }
            }
        }
    }

    // MARK: - 数据流

    private func buildRows() {
        let existingNames = Set(
            ((try? env.context.fetch(FetchDescriptor<Medication>())) ?? []).map(\.name)
        )
        rows = draft.result.medications.map { ext in
            MedRow(
                selected: !ext.name.isEmpty,
                name: ext.name,
                spec: ext.spec ?? "",
                dose: ext.dose ?? PrescriptionParser.dosePerTake(from: ext.frequency) ?? "",
                frequency: ext.frequencyPerDay
                    ?? PrescriptionParser.frequencyPerDay(from: ext.frequency)
                    ?? 1,
                sig: ext.frequency ?? "",
                cautions: ext.cautions ?? "",
                durationText: ext.durationText ?? "",
                existsAlready: existingNames.contains(ext.name)
            )
        }
        if let date = PrescriptionParser.parseDate(draft.result.takenAt) {
            prescribedDate = date
        }
    }

    private func save() {
        let dateText: String = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            return formatter.string(from: prescribedDate)
        }()
        let selected = rows.filter(\.selected).map { row in
            ExtractedMedication(
                name: row.name,
                dose: row.dose.isEmpty ? nil : row.dose,
                frequency: row.sig.isEmpty ? nil : row.sig,
                timesOfDay: PrescriptionParser.timesOfDay(frequency: row.frequency, sig: row.sig),
                frequencyPerDay: row.frequency,
                cautions: row.cautions.isEmpty ? nil : row.cautions,
                spec: row.spec.isEmpty ? nil : row.spec,
                quantity: nil,
                durationText: row.durationText.isEmpty ? nil : row.durationText
            )
        }

        var result = draft.result
        result.medications = selected
        result.takenAt = dateText

        MedicationImporter.importMedications(from: result, into: modelContext, source: .prescriptionOCR)

        var photoRef: String?
        if let image = draft.image {
            photoRef = try? PhotoStore.saveJPEG(image, quality: 0.8)
        }
        var structured = DailyStructuredFields()
        structured.medicalDoc = result
        let entry = DailyLogEntry(
            kind: .medicalDoc,
            createdAt: prescribedDate,
            photoRef: photoRef,
            contentText: result.summary,
            tags: [LogTag.symptom.rawValue],
            structured: structured,
            confirmation: .confirmed
        )
        entry.aiLabel = result.title ?? result.docType
        modelContext.insert(entry)
        try? modelContext.save()

        let allMeds = (try? modelContext.fetch(FetchDescriptor<Medication>())) ?? []
        NotificationService.syncMedicationReminders(from: allMeds)
        Task { await env.refreshTodayPipeline() }
        dismiss()
    }
}
