import SwiftData
import SwiftUI

struct JournalHomeView: View {
    @Environment(AppEnvironment.self) private var env
    @Query(sort: \DailyLogEntry.createdAt, order: .reverse) private var entries: [DailyLogEntry]
    @Query private var intakes: [MedicationIntake]
    @Query private var alerts: [AlertRecord]
    @State private var showCamera = false
    @State private var showSymptom = false
    @State private var showVoice = false
    @State private var selectedDay: Date = Date()
    @State private var weekOffset = 0
    @Binding var selectedTab: Int

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CareTheme.sectionSpacing) {
                    header
                    captureDeck
                    heatmapCard
                    weekStrip
                    timeline
                }
                .padding()
            }
            .background(CareTheme.paper.ignoresSafeArea())
            .navigationBarHidden(true)
            .sheet(isPresented: $showCamera) { CameraCaptureView() }
            .sheet(isPresented: $showSymptom) { SymptomCheckInView() }
            .sheet(isPresented: $showVoice) { VoiceNoteView() }
        }
    }

    // MARK: 顶部问候 + Streak

    private var header: some View {
        let streak = StreakService.consecutiveDays(entries)
        let todayAlerts = alerts.filter { Calendar.current.isDateInToday($0.createdAt) }
        let status = TodayStatus.from(alerts: todayAlerts)
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("今天感觉怎么样？")
                    .font(CareTheme.pageTitle)
                    .foregroundStyle(CareTheme.ink)
                Text(Date().formatted(.dateTime.month().day().weekday()))
                    .font(CareTheme.caption)
                    .foregroundStyle(CareTheme.muted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill")
                        .foregroundStyle(streak > 0 ? Color(red: 0.85, green: 0.45, blue: 0.15) : CareTheme.muted)
                    Text("连续 \(streak) 天")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(CareTheme.ink)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.white))
                .shadow(color: CareTheme.ink.opacity(0.06), radius: 6, y: 2)
                Button {
                    selectedTab = 1
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(CareTheme.statusColor(status))
                            .frame(width: 7, height: 7)
                        Text(status.rawValue)
                            .font(.caption.weight(.medium))
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                    }
                    .foregroundStyle(CareTheme.muted)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("journal.statusPill")
            }
        }
        .padding(.top, 8)
    }

    // MARK: 记录入口

    private var captureDeck: some View {
        VStack(spacing: 10) {
            Button {
                showCamera = true
            } label: {
                VStack(spacing: 10) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 34))
                    Text("拍一张，留下今天")
                        .font(.headline)
                    Text("自动叠健康水印，拍完即可保存")
                        .font(.caption)
                        .opacity(0.85)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 132)
                .background(
                    RoundedRectangle(cornerRadius: CareTheme.cardCornerRadius, style: .continuous)
                        .fill(CareTheme.brandGradient)
                        .shadow(color: CareTheme.sage.opacity(0.35), radius: 10, y: 4)
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("journal.openCamera")
            HStack(spacing: 10) {
                captureAction(
                    icon: "waveform.path.ecg",
                    title: "症状打卡",
                    tint: CareTheme.danger,
                    identifier: "journal.symptom"
                ) { showSymptom = true }
                captureAction(
                    icon: "waveform",
                    title: "语音速记",
                    tint: Color(red: 0.38, green: 0.36, blue: 0.62),
                    identifier: "journal.voice"
                ) { showVoice = true }
            }
        }
    }

    private func captureAction(
        icon: String,
        title: String,
        tint: Color,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(CareTheme.ink)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: CareTheme.smallCornerRadius, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: CareTheme.ink.opacity(0.05), radius: 6, y: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    // MARK: 坚持记录热力图

    private var heatmapCard: some View {
        let dates = entries.map(\.createdAt) + intakes.filter { $0.status == .taken }.compactMap(\.takenAt)
        return VStack(alignment: .leading, spacing: 10) {
            Label("坚持记录", systemImage: "calendar")
                .font(CareTheme.cardTitle)
                .foregroundStyle(CareTheme.ink)
            ActivityHeatmapView(counts: ActivityHeatmap.counts(dates: dates))
        }
        .careCard()
    }

    // MARK: 周视图

    private var weekDays: [Date] {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        let today = calendar.startOfDay(for: Date())
        guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start,
              let start = calendar.date(byAdding: .weekOfYear, value: -weekOffset, to: weekStart) else {
            return []
        }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private var weekStrip: some View {
        let recordedDays = Set(entries.map { Calendar.current.startOfDay(for: $0.createdAt) })
        return VStack(spacing: 8) {
            HStack {
                Button {
                    weekOffset += 1
                } label: {
                    Image(systemName: "chevron.left")
                }
                Spacer()
                Text(weekOffset == 0 ? "本周" : weekDays.first.map { $0.formatted(.dateTime.month().day()) } ?? "")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(CareTheme.ink)
                Spacer()
                Button {
                    weekOffset = max(0, weekOffset - 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(weekOffset == 0)
            }
            .foregroundStyle(CareTheme.muted)
            .padding(.horizontal, 4)
            HStack(spacing: 0) {
                ForEach(weekDays, id: \.self) { day in
                    let calendar = Calendar.current
                    let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)
                    let isFuture = day > Date()
                    let hasRecords = recordedDays.contains(calendar.startOfDay(for: day))
                    Button {
                        selectedDay = day
                    } label: {
                        VStack(spacing: 4) {
                            Text(day.formatted(.dateTime.weekday(.narrow)))
                                .font(.caption2)
                                .foregroundStyle(isSelected ? .white : CareTheme.muted)
                            Text(day.formatted(.dateTime.day()))
                                .font(CareTheme.metricValueSmall)
                                .monospacedDigit()
                                .foregroundStyle(isSelected ? .white : CareTheme.ink)
                            Circle()
                                .fill(hasRecords ? (isSelected ? Color.white : CareTheme.sage) : Color.clear)
                                .frame(width: 4, height: 4)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: CareTheme.smallCornerRadius, style: .continuous)
                                .fill(isSelected ? CareTheme.sage : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isFuture)
                    .opacity(isFuture ? 0.35 : 1)
                }
            }
        }
        .careCard()
    }

    // MARK: 时间线

    private var timeline: some View {
        let dayEntries = entries.filter { Calendar.current.isDate($0.createdAt, inSameDayAs: selectedDay) }
        return VStack(alignment: .leading, spacing: 12) {
            Text(selectedDay.formatted(.dateTime.year().month().day().weekday()))
                .font(.title3.bold())
                .foregroundStyle(CareTheme.ink)
            if dayEntries.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.title2)
                        .foregroundStyle(CareTheme.sage)
                    Text("这一天还没有记录。一张照片也算。")
                        .font(CareTheme.body)
                        .foregroundStyle(CareTheme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .careCard()
            }
            ForEach(dayEntries, id: \.id) { entry in
                JournalCard(entry: entry)
            }
        }
    }
}

struct JournalCard: View {
    let entry: DailyLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if entry.confirmationState == .pendingAI {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("识别结果待你确认后才会写入档案")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(CareTheme.warn)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(CareTheme.warn.opacity(0.10))
                )
            }
            HStack(spacing: 6) {
                Image(systemName: IconCatalog.icon(for: entry.kind))
                    .font(.caption)
                Text(label)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(entry.createdAt.formatted(.dateTime.hour().minute()))
                    .font(.caption)
                    .foregroundStyle(CareTheme.muted)
            }
            .foregroundStyle(CareTheme.sage)

            if let doc = entry.medicalDoc {
                medicalDocSection(doc)
            } else if let ref = entry.photoRef, let image = PhotoStore.load(ref) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: 220)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: CareTheme.smallCornerRadius, style: .continuous))
            }

            Text(entry.displayBody)
                .font(CareTheme.body)
                .foregroundStyle(CareTheme.ink)
            if !entry.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(entry.tags, id: \.self) { tag in
                        TagChip(text: tag, color: IconCatalog.color(forTag: tag))
                    }
                }
            }
        }
        .careCard()
    }

    @ViewBuilder
    private func medicalDocSection(_ doc: MedicalDocResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(doc.docType)
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(CareTheme.sage.opacity(0.15))
                    .clipShape(Capsule())
                if let title = doc.title, !title.isEmpty {
                    Text(title).font(.caption).foregroundStyle(CareTheme.muted)
                }
            }
            if !doc.diagnoses.isEmpty {
                Text(doc.diagnoses.joined(separator: "、"))
                    .font(.subheadline)
                    .foregroundStyle(CareTheme.ink)
            }
            if !doc.labValues.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(doc.labValues.prefix(3), id: \.name) { lab in
                        HStack(spacing: 4) {
                            Text(lab.name).font(.caption)
                            Text("\(lab.value)\(lab.unit.map { " \($0)" } ?? "")")
                                .font(.caption.monospacedDigit())
                            if let flag = lab.flag {
                                Image(systemName: flag == "high" ? "arrow.up.circle.fill" : flag == "low" ? "arrow.down.circle.fill" : "checkmark.circle")
                                    .font(.caption2)
                                    .foregroundStyle(flag == "high" ? CareTheme.danger : flag == "low" ? Color.orange : CareTheme.sage)
                            }
                        }
                    }
                    if doc.labValues.count > 3 {
                        Text("+\(doc.labValues.count - 3) 项")
                            .font(.caption2)
                            .foregroundStyle(CareTheme.muted)
                    }
                }
            }
            if !doc.medications.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(doc.medications, id: \.name) { med in
                        HStack(spacing: 4) {
                            Text(med.name).font(.caption)
                            if let dose = med.dose, !dose.isEmpty {
                                Text(dose).font(.caption).foregroundStyle(CareTheme.muted)
                            }
                            if let freq = med.frequency, !freq.isEmpty {
                                Text("· \(freq)").font(.caption2).foregroundStyle(CareTheme.muted)
                            }
                        }
                    }
                }
            }
            if let followUpDate = doc.followUpDate, !followUpDate.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "calendar").font(.caption2)
                    Text(followUpDate).font(.caption)
                    if let dept = doc.followUpDepartment, !dept.isEmpty {
                        Text(dept).font(.caption).foregroundStyle(CareTheme.muted)
                    }
                }
                .foregroundStyle(CareTheme.sage)
            } else if let hint = doc.followUpHint, !hint.isEmpty {
                Label(hint, systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(CareTheme.sage)
            }
        }
    }

    private var label: String {
        switch entry.kind {
        case .photo: "水印照片"
        case .voice: "语音"
        case .text: "文字"
        case .quickTag: "标签"
        case .symptom: "症状"
        case .medicalDoc: "病历识别"
        }
    }
}
