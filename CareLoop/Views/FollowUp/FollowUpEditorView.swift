import SwiftData
import SwiftUI

struct FollowUpEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var env

    var existing: FollowUp?

    @State private var date = Date().addingTimeInterval(86400 * 14)
    @State private var department = "心内科"
    @State private var doctorName = ""
    @State private var hospital = ""
    @State private var restrictionsText = ""
    @State private var materialsText = ""
    @State private var notes = ""
    @State private var confirmed = true
    @State private var appeared = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CareTheme.sectionSpacing) {
                    editorSection("复诊时间", icon: "clock.fill", tint: CareTheme.sage) {
                        DatePicker("日期与时间", selection: $date)
                            .datePickerStyle(.graphical)
                            .tint(CareTheme.sage)
                    }
                    .careStaggerAppear(index: 0, active: appeared)

                    editorSection("就诊信息", icon: "cross.case.fill", tint: CareTheme.sageBright) {
                        field("科室", text: $department)
                        field("医生（可选）", text: $doctorName)
                        field("医院（可选）", text: $hospital)
                    }
                    .careStaggerAppear(index: 1, active: appeared)

                    editorSection("复诊前禁忌", icon: "exclamationmark.circle.fill", tint: CareTheme.warn) {
                        multilineField("如：空腹、检查前勿剧烈运动", text: $restrictionsText)
                        Text("由你或医生填写，App 不会生成停药建议。")
                            .font(.caption)
                            .foregroundStyle(CareTheme.muted)
                    }
                    .careStaggerAppear(index: 2, active: appeared)

                    editorSection("需要携带的材料", icon: "bag.fill", tint: CareTheme.sage) {
                        multilineField("如：化验单、用药清单", text: $materialsText)
                    }
                    .careStaggerAppear(index: 3, active: appeared)

                    editorSection("备注", icon: "note.text", tint: CareTheme.muted) {
                        multilineField("其他说明", text: $notes)
                    }
                    .careStaggerAppear(index: 4, active: appeared)

                    if existing == nil {
                        Toggle(isOn: $confirmed) {
                            Text("确认这是医生医嘱的复诊安排")
                                .font(.subheadline)
                        }
                        .tint(CareTheme.sage)
                        .careCard()
                        .careStaggerAppear(index: 5, active: appeared)
                    }

                    FollowUpPrimaryButton(title: "保存复诊安排", icon: "checkmark.circle.fill") {
                        save()
                    }
                    .disabled(department.trimmingCharacters(in: .whitespaces).isEmpty || (!confirmed && existing == nil))
                    .opacity(department.trimmingCharacters(in: .whitespaces).isEmpty || (!confirmed && existing == nil) ? 0.5 : 1)
                    .careStaggerAppear(index: 6, active: appeared)
                }
                .padding()
            }
            .background(CareTheme.paper.ignoresSafeArea())
            .navigationTitle(existing == nil ? "添加复诊" : "编辑复诊")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear {
                loadExisting()
                withAnimation { appeared = true }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func editorSection<Content: View>(
        _ title: String,
        icon: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(CareTheme.cardTitle)
                .foregroundStyle(tint)
            content()
        }
        .careCard()
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(CareTheme.paper)
            )
    }

    private func multilineField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text, axis: .vertical)
            .lineLimit(2...5)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(CareTheme.paper)
            )
    }

    private func loadExisting() {
        guard let existing else { return }
        date = existing.date
        department = existing.department
        doctorName = existing.doctorName
        hospital = existing.hospital
        restrictionsText = FollowUpService.joinList(existing.effectiveRestrictions)
        materialsText = FollowUpService.joinList(existing.effectiveMaterials)
        notes = existing.notes
        confirmed = existing.confirmedByUser
    }

    private func save() {
        let restrictions = FollowUpService.splitList(restrictionsText)
        let materials = FollowUpService.splitList(materialsText)
        if let existing {
            existing.date = date
            existing.department = department.trimmingCharacters(in: .whitespaces)
            existing.doctorName = doctorName.trimmingCharacters(in: .whitespaces)
            existing.hospital = hospital.trimmingCharacters(in: .whitespaces)
            existing.preVisitRestrictions = restrictions
            existing.materialsToBring = materials
            existing.notes = notes
            existing.confirmedByUser = true
        } else {
            let item = FollowUp(
                mode: .doctorOrdered,
                date: date,
                department: department.trimmingCharacters(in: .whitespaces),
                doctorName: doctorName.trimmingCharacters(in: .whitespaces),
                hospital: hospital.trimmingCharacters(in: .whitespaces),
                preVisitRestrictions: restrictions,
                materialsToBring: materials,
                notes: notes,
                confirmedByUser: confirmed
            )
            env.context.insert(item)
        }
        try? env.context.save()
        let allFollowUps = (try? env.context.fetch(FetchDescriptor<FollowUp>())) ?? []
        NotificationService.syncFollowUpReminders(from: allFollowUps)
        CareHaptics.success()
        dismiss()
    }
}
