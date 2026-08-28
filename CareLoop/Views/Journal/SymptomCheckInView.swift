import SwiftUI

struct SymptomCheckInView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var env
    @State private var selected: [String] = []
    @State private var severity: SymptomSeverity = .mild
    @State private var note = ""
    private let options = ["头晕", "心悸", "乏力", "头痛", "胸闷", "恶心", "失眠", "水肿", "胸痛", "严重头晕"]

    var body: some View {
        NavigationStack {
            Form {
                Section("选择症状") {
                    ForEach(options, id: \.self) { item in
                        Toggle(item, isOn: Binding(
                            get: { selected.contains(item) },
                            set: { on in
                                if on { selected.append(item) } else { selected.removeAll { $0 == item } }
                            }
                        ))
                    }
                }
                Section("程度") {
                    Picker("程度", selection: $severity) {
                        ForEach(SymptomSeverity.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("补充（可选）") {
                    TextField("想说的都可以写", text: $note, axis: .vertical)
                }
                DisclaimerBanner(compact: true)
            }
            .navigationTitle("今天身体怎么样")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("记下") { save() } }
            }
        }
    }

    private func save() {
        let symptoms = selected.map { SymptomEntry(name: $0, severity: severity) }
        let entry = DailyLogEntry(
            kind: .symptom,
            contentText: note,
            tags: [LogTag.symptom.rawValue],
            symptoms: symptoms,
            confirmation: .confirmed
        )
        env.context.insert(entry)
        try? env.context.save()
        Task { await env.refreshTodayPipeline() }
        dismiss()
    }
}

struct VoiceNoteView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var env
    @State private var service = SpeechService()
    @State private var text = ""
    @State private var recording = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text(text.isEmpty ? "按住说，松手转写。也可以直接打字。" : text)
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
                TextField("手动补充", text: $text, axis: .vertical)
                Button(recording ? "停止并转写" : "开始说话") {
                    Task { await toggle() }
                }
                .buttonStyle(.borderedProminent)
                DisclaimerBanner(compact: true)
                Spacer()
            }
            .padding()
            .background(CareTheme.paper.ignoresSafeArea())
            .navigationTitle("语音速记")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
            }
        }
    }

    private func toggle() async {
        if recording {
            service.stop()
            recording = false
        } else {
            let ok = await service.requestAccess()
            guard ok else { return }
            try? service.start { partial in
                text = partial
            }
            recording = true
        }
    }

    private func save() {
        if recording { service.stop() }
        let entry = DailyLogEntry(kind: .voice, transcript: text, contentText: text, tags: [], confirmation: .confirmed)
        env.context.insert(entry)
        try? env.context.save()
        dismiss()
    }
}
