import PhotosUI
import SwiftData
import SwiftUI

struct MedicationHomeView: View {
    @Environment(AppEnvironment.self) private var env
    @Query(sort: \Medication.name) private var medications: [Medication]
    @Query private var intakes: [MedicationIntake]
    @State private var showAdd = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var prescriptionDraft: PrescriptionDraft?
    @State private var recognizing = false
    @State private var recognizeError: String?

    var body: some View {
        NavigationStack {
            List {
                Section("用药 Panel") {
                    ForEach(medications, id: \.id) { med in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(med.name).font(.headline)
                                if !med.confirmedByUser {
                                    Text("待确认")
                                        .font(.caption)
                                        .foregroundStyle(CareTheme.warn)
                                }
                            }
                            Text("\(med.dosePerTime) · \(med.timesOfDay.joined(separator: " / ")) · \(med.periodText)")
                                .font(.caption)
                            if !med.cautions.isEmpty {
                                Text(med.cautions).font(.caption2).foregroundStyle(CareTheme.muted)
                            }
                            Text("来源：\(med.source.rawValue)")
                                .font(.caption2)
                        }
                    }
                    Button("添加用药") { showAdd = true }
                }
                Section("处方识别（需确认）") {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        HStack {
                            Image(systemName: "doc.text.viewfinder")
                            Text("从相册识别处方/病历")
                        }
                    }
                    .disabled(recognizing)
                    Text("支持：医院处方笺、药房小票、药盒标签、电子处方截图。识别后逐项核对才会写入。")
                        .font(.caption)
                        .foregroundStyle(CareTheme.muted)
                    if recognizing {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("识别中…")
                        }
                    }
                    if let recognizeError {
                        Text(recognizeError)
                            .font(.caption)
                            .foregroundStyle(CareTheme.warn)
                    }
                }
            }
            .navigationTitle("用药")
            .sheet(isPresented: $showAdd) {
                AddMedicationView()
            }
            .sheet(item: $prescriptionDraft) { draft in
                PrescriptionReviewSheet(draft: draft)
            }
            .onChange(of: pickerItem) { _, item in
                Task { await recognize(item) }
            }
        }
    }

    /// 强路径：视觉模型（vision 时附图）+ Vision OCR 双输入 → 结构化处方 → 人工核对。
    /// 失败时回退启发式 OCR 粗识别，表单带"离线粗识别"警示。
    private func recognize(_ item: PhotosPickerItem?) async {
        guard let item,
              let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        recognizing = true
        recognizeError = nil
        defer {
            recognizing = false
            pickerItem = nil
        }
        do {
            let result = try await MedicalDocumentAnalyzer.analyze(
                image: image,
                docHint: "处方单",
                llm: env.currentLLM()
            )
            guard !result.medications.isEmpty else {
                recognizeError = "未识别到药品条目，请换一张更清晰的照片或手动添加。"
                return
            }
            prescriptionDraft = PrescriptionDraft(result: result, image: image)
        } catch {
            let text = await OCRService.recognize(image: image)
            if let rough = OCRService.parsePrescription(from: text) {
                var ext = ExtractedMedication(
                    name: rough.name,
                    dose: nil,
                    frequency: nil,
                    timesOfDay: rough.times,
                    frequencyPerDay: nil,
                    cautions: nil
                )
                ext.dose = rough.dose.isEmpty ? nil : rough.dose
                ext.cautions = rough.cautions.isEmpty ? nil : rough.cautions
                let result = MedicalDocResult(
                    docType: "处方单",
                    title: "离线粗识别",
                    takenAt: nil,
                    diagnoses: [],
                    labValues: [],
                    medications: [ext],
                    recommendations: [],
                    followUpHint: nil,
                    followUpDate: nil,
                    followUpDepartment: nil,
                    summary: "网络不可用，使用本地 OCR 粗识别，请仔细核对。"
                )
                prescriptionDraft = PrescriptionDraft(result: result, image: image, degraded: true)
            } else {
                recognizeError = "识别失败（\(error.localizedDescription)），可手动添加。"
            }
        }
    }
}

struct AddMedicationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var env
    @State private var name = ""
    @State private var dose = ""
    @State private var times = "08:00"

    var body: some View {
        NavigationStack {
            Form {
                TextField("药品名", text: $name)
                TextField("每次剂量", text: $dose)
                TextField("时间（逗号分隔）", text: $times)
                Text(MedicationEngine.missedHint)
                    .font(.caption)
            }
            .navigationTitle("添加用药")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let med = Medication(
                            name: name,
                            dosePerTime: dose,
                            timesOfDay: times.split { ",， ".contains($0) }.map(String.init)
                        )
                        env.context.insert(med)
                        try? env.context.save()
                        dismiss()
                    }
                    .disabled(name.isEmpty)
                }
            }
        }
    }
}
