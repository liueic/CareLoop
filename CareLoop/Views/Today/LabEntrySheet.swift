import SwiftData
import SwiftUI

/// 手动录入化验指标（hba1c、血脂四项）的表单。
///
/// 这些指标无法从健康 App 自动读取；保存为 `kind == .medicalDoc` 的手帐条目，
/// 与化验单 OCR 共用同一条 `LabMetricStore` 合并路径，喂给风险提示与临床引擎。
struct LabEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var values: [MetricType: String] = [:]
    @State private var labDate: Date = Date()

    private let labTypes: [MetricType] = MetricType.labEntryTypes
        .sorted { $0.rawValue < $1.rawValue }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("化验日期", selection: $labDate, displayedComponents: .date)
                } header: {
                    Text("指标（可只填部分）")
                } footer: {
                    Text("糖化血红蛋白与血脂无法从健康 App 自动读取，录入后用于风险提示与复诊资料。本应用不提供疾病诊断。")
                }
                ForEach(labTypes) { type in
                    HStack {
                        Text(type.displayName)
                        Spacer()
                        TextField(type.unit, text: binding(for: type))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 96)
                    }
                }
            }
            .navigationTitle("录入化验指标")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(!hasAnyValue)
                }
            }
        }
    }

    private func binding(for type: MetricType) -> Binding<String> {
        Binding(
            get: { values[type] ?? "" },
            set: { values[type] = $0 }
        )
    }

    private var hasAnyValue: Bool {
        labTypes.contains { Double(values[$0] ?? "") != nil }
    }

    private func save() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let items = labTypes.compactMap { type -> LabValueItem? in
            guard let raw = values[type], let value = Double(raw) else { return nil }
            return LabValueItem(
                name: type.displayName,
                value: value.description,
                unit: type.unit,
                reference: nil,
                flag: nil
            )
        }
        guard !items.isEmpty else { return }
        let doc = MedicalDocResult(
            docType: LabMetricMapper.manualDocType,
            title: "手动化验录入",
            takenAt: formatter.string(from: labDate),
            diagnoses: [],
            labValues: items,
            medications: [],
            recommendations: [],
            followUpHint: nil,
            followUpDate: nil,
            followUpDepartment: nil,
            summary: "手动录入 \(items.count) 项化验指标"
        )
        modelContext.insert(
            DailyLogEntry(
                kind: .medicalDoc,
                createdAt: labDate,
                structured: DailyStructuredFields(medicalDoc: doc),
                confirmation: .confirmed
            )
        )
        try? modelContext.save()
        dismiss()
    }
}
