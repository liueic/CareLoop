import PhotosUI
import SwiftData
import SwiftUI

struct MedicationHomeView: View {
    @Environment(AppEnvironment.self) private var env
    @Query(sort: \Medication.name) private var medications: [Medication]
    @Query private var intakes: [MedicationIntake]
    @State private var showAdd = false
    @State private var ocrImage: UIImage?
    @State private var pickerItem: PhotosPickerItem?
    @State private var draft: DraftMedication?

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
                        Text("从相册识别处方/病历")
                    }
                    if let draft {
                        Text("识别到：\(draft.name) \(draft.dose)")
                        Button("确认写入") {
                            let med = Medication(
                                name: draft.name,
                                dosePerTime: draft.dose.isEmpty ? "按医嘱" : draft.dose,
                                timesOfDay: draft.times,
                                cautions: draft.cautions,
                                source: .prescriptionOCR,
                                prescribedDate: Date(),
                                confirmedByUser: true
                            )
                            env.context.insert(med)
                            try? env.context.save()
                            self.draft = nil
                        }
                    }
                }
            }
            .navigationTitle("用药")
            .sheet(isPresented: $showAdd) {
                AddMedicationView()
            }
            .onChange(of: pickerItem) { _, item in
                Task { await recognize(item) }
            }
        }
    }

    private func recognize(_ item: PhotosPickerItem?) async {
        guard let item, let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return }
        let text = await OCRService.recognize(image: image)
        draft = OCRService.parsePrescription(from: text)
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
