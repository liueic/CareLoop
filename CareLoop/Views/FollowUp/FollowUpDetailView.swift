import PhotosUI
import SwiftData
import SwiftUI

struct FollowUpDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Query(sort: \FollowUp.date) private var allFollowUps: [FollowUp]
    @Query(sort: \HospitalReport.capturedAt, order: .reverse) private var reports: [HospitalReport]
    @Query(sort: \Medication.name) private var medications: [Medication]
    @Query private var intakes: [MedicationIntake]
    @Query(sort: \AlertRecord.createdAt, order: .reverse) private var alerts: [AlertRecord]
    @Query(sort: \DailyLogEntry.createdAt, order: .reverse) private var logs: [DailyLogEntry]

    var followUpID: UUID?

    @State private var showEditor = false
    @State private var showExportSheet = false
    @State private var exportURL: URL?
    @State private var exportError: String?
    @State private var pickerItem: PhotosPickerItem?
    @State private var selectedReportIDs: Set<UUID> = []
    @State private var contentAppeared = false
    @State private var isExporting = false
    @State private var showCompleteConfirm = false

    private var followUp: FollowUp? {
        if let followUpID {
            return allFollowUps.first { $0.id == followUpID }
        }
        return FollowUpService.nextFollowUp(from: allFollowUps)
    }

    private var recentAlerts: [AlertRecord] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return alerts.filter { $0.createdAt >= cutoff }
    }

    private var recentLogs: [DailyLogEntry] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return logs.filter { $0.createdAt >= cutoff }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CareTheme.sectionSpacing) {
                if let followUp, !followUp.isCompleted {
                    activeDetail(followUp)
                        .careStaggerAppear(index: 0, active: contentAppeared)
                } else if let followUp, followUp.isCompleted {
                    completedDetail(followUp)
                        .careStaggerAppear(index: 0, active: contentAppeared)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    emptyState
                        .careStaggerAppear(index: 0, active: contentAppeared)
                }
                reportsSection
                    .careStaggerAppear(index: 1, active: contentAppeared)
                if !FollowUpService.completedFollowUps(from: allFollowUps).isEmpty {
                    historySection
                        .careStaggerAppear(index: 2, active: contentAppeared)
                }
                DisclaimerBanner(compact: true)
                    .careStaggerAppear(index: 3, active: contentAppeared)
            }
            .padding()
            .animation(.spring(response: 0.45, dampingFraction: 0.86), value: followUp?.isCompleted)
        }
        .background(CareTheme.paper.ignoresSafeArea())
        .navigationTitle("复诊安排")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let followUp, !followUp.isCompleted {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("编辑") { showEditor = true }
                }
            }
        }
        .sheet(isPresented: $showEditor) {
            FollowUpEditorView(existing: followUp)
        }
        .sheet(isPresented: $showExportSheet) {
            if let exportURL {
                ShareSheet(items: [exportURL])
            }
        }
        .onAppear {
            selectedReportIDs = Set(reports.prefix(6).map(\.id))
            withAnimation {
                contentAppeared = true
            }
        }
        .onChange(of: pickerItem) { _, item in
            Task { await importReport(item) }
        }
        .confirmationDialog(
            "确认标记为已完成？",
            isPresented: $showCompleteConfirm,
            titleVisibility: .visible
        ) {
            Button("标记已完成", role: .destructive) {
                if let followUp { markCompleted(followUp) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("完成后将不再出现在「下次复诊」提醒中。")
        }
        .alert("导出失败", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    // MARK: - Active detail

    @ViewBuilder
    private func activeDetail(_ followUp: FollowUp) -> some View {
        VStack(alignment: .leading, spacing: CareTheme.sectionSpacing) {
            FollowUpHeroBanner(followUp: followUp)

            VStack(alignment: .leading, spacing: 14) {
                if !followUp.hospital.isEmpty {
                    FollowUpInfoTile(
                        icon: "building.2.fill",
                        title: "医院",
                        value: followUp.hospital,
                        tint: CareTheme.sage
                    )
                }
                if !followUp.effectiveRestrictions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("复诊前禁忌")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(CareTheme.muted)
                        FollowUpChipRow(
                            icon: "exclamationmark.circle",
                            tint: CareTheme.warn,
                            items: followUp.effectiveRestrictions
                        )
                    }
                }
                if !followUp.effectiveMaterials.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("需要携带")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(CareTheme.muted)
                        FollowUpChipRow(
                            icon: "bag.fill",
                            tint: CareTheme.sage,
                            items: followUp.effectiveMaterials
                        )
                    }
                }
                if !followUp.notes.isEmpty {
                    FollowUpInfoTile(
                        icon: "note.text",
                        title: "备注",
                        value: followUp.notes,
                        tint: CareTheme.muted
                    )
                }
                if followUp.mode == .smartSuggested {
                    Text(SmartFollowUpEngine.wording)
                        .font(.caption)
                        .foregroundStyle(CareTheme.muted)
                }
            }
            .careCard()

            VStack(spacing: 10) {
                FollowUpPrimaryButton(
                    title: "一键导出就诊材料",
                    icon: "square.and.arrow.up",
                    isLoading: isExporting
                ) {
                    exportVisitPack(for: followUp)
                }
                Button {
                    showCompleteConfirm = true
                } label: {
                    Text("标记已完成")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(CareTheme.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(CareCardPressStyle())
            }
        }
    }

    private func completedDetail(_ followUp: FollowUp) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(CareTheme.sage)
                    .symbolEffect(.bounce, value: followUp.completedAt)
                VStack(alignment: .leading, spacing: 2) {
                    Text("已完成")
                        .font(.headline)
                    if let completedAt = followUp.completedAt {
                        Text(completedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(CareTheme.muted)
                    }
                }
            }
            Divider()
            FollowUpInfoTile(icon: "cross.case.fill", title: "科室", value: followUp.department, tint: CareTheme.sage)
            FollowUpInfoTile(
                icon: "calendar",
                title: "复诊日期",
                value: followUp.date.formatted(date: .long, time: .shortened),
                tint: CareTheme.muted
            )
        }
        .careCard()
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            FollowUpEmptyIllustration()
            VStack(spacing: 6) {
                Text("还没有下次复诊安排")
                    .font(.headline)
                    .foregroundStyle(CareTheme.ink)
                Text("记录医生口头医嘱的复诊日期、科室和携带材料，就诊前可一键导出材料包。")
                    .font(CareTheme.body)
                    .foregroundStyle(CareTheme.muted)
                    .multilineTextAlignment(.center)
            }
            FollowUpPrimaryButton(title: "添加下次复诊", icon: "plus.circle.fill") {
                showEditor = true
            }
        }
        .frame(maxWidth: .infinity)
        .careCard()
    }

    // MARK: - Reports

    private var reportsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("我的医院报告", systemImage: "doc.text.image")
                    .font(CareTheme.cardTitle)
                    .foregroundStyle(CareTheme.ink)
                Spacer()
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label("添加", systemImage: "plus.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(CareTheme.sage)
                }
            }
            Text("化验单、出院小结等照片保存在本地，导出就诊材料时可勾选附上。不会写入手帐时间线。")
                .font(.caption)
                .foregroundStyle(CareTheme.muted)
            if reports.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.title2)
                            .foregroundStyle(CareTheme.track)
                        Text("还没有保存的报告照片")
                            .font(.caption)
                            .foregroundStyle(CareTheme.muted)
                    }
                    .padding(.vertical, 12)
                    Spacer()
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                    ForEach(reports, id: \.id) { report in
                        FollowUpReportTile(
                            report: report,
                            selected: selectedReportIDs.contains(report.id)
                        ) {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
                                if selectedReportIDs.contains(report.id) {
                                    selectedReportIDs.remove(report.id)
                                } else {
                                    selectedReportIDs.insert(report.id)
                                }
                            }
                            CareHaptics.light()
                        }
                        .contextMenu {
                            Button("删除", role: .destructive) {
                                deleteReport(report)
                            }
                        }
                    }
                }
            }
            Button {
                exportVisitPack(for: followUp)
            } label: {
                Label("导出就诊材料", systemImage: "square.and.arrow.up")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .tint(CareTheme.sage)
            .disabled(followUp == nil && medications.filter { $0.isActive }.isEmpty && reports.isEmpty)
        }
        .careCard()
    }

    // MARK: - History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("历史复诊", systemImage: "clock.arrow.circlepath")
                .font(CareTheme.cardTitle)
                .foregroundStyle(CareTheme.ink)
            ForEach(FollowUpService.completedFollowUps(from: allFollowUps), id: \.id) { item in
                HStack(spacing: 12) {
                    Circle()
                        .fill(CareTheme.sageSoft)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.department)
                            .font(.subheadline.weight(.medium))
                        Text(item.date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                            .foregroundStyle(CareTheme.muted)
                    }
                    Spacer()
                    Text("已完成")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(CareTheme.sage)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(CareTheme.sageSoft))
                }
                .padding(.vertical, 4)
            }
        }
        .careCard()
    }

    // MARK: - Actions

    private func markCompleted(_ followUp: FollowUp) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            followUp.completedAt = Date()
        }
        try? env.context.save()
        let allFollowUps = (try? env.context.fetch(FetchDescriptor<FollowUp>())) ?? []
        NotificationService.syncFollowUpReminders(from: allFollowUps)
        CareHaptics.success()
    }

    private func exportVisitPack(for followUp: FollowUp?) {
        isExporting = true
        let selected = reports.filter { selectedReportIDs.contains($0.id) }
        let input = VisitPackInput(
            followUp: followUp,
            profile: env.profile(),
            medications: medications,
            alerts: recentAlerts,
            adherence: MedicationEngine.adherence(intakes: intakes, expectedSlots: medications.count * 7),
            logs: recentLogs,
            reports: selected
        )
        Task {
            do {
                let url = try VisitPackExporter.makePDF(input)
                await MainActor.run {
                    exportURL = url
                    isExporting = false
                    showExportSheet = true
                    CareHaptics.success()
                }
            } catch {
                await MainActor.run {
                    isExporting = false
                    exportError = error.localizedDescription
                }
            }
        }
    }

    private func importReport(_ item: PhotosPickerItem?) async {
        guard let item,
              let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data),
              let ref = try? PhotoStore.saveJPEG(image) else { return }
        await MainActor.run {
            let report = HospitalReport(title: "医院报告", photoRef: ref)
            env.context.insert(report)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) {
                selectedReportIDs.insert(report.id)
            }
            try? env.context.save()
            pickerItem = nil
            CareHaptics.light()
        }
    }

    private func deleteReport(_ report: HospitalReport) {
        withAnimation(.easeOut(duration: 0.2)) {
            selectedReportIDs.remove(report.id)
            env.context.delete(report)
        }
        try? env.context.save()
    }
}

/// UIKit share sheet wrapper for PDF export.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
