import AVFoundation
import PhotosUI
import SwiftData
import SwiftUI
import UIKit

struct CameraCaptureView: View {
    enum CaptureMode: String, CaseIterable, Identifiable {
        case journal = "日记"
        case medicalDoc = "病历/报告"
        var id: String { rawValue }
    }

    private let docHintOptions = ["检验报告", "病历", "出院小结", "处方单", "药房小票", "药盒", "诊断证明"]

    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var env
    @State private var mode: CaptureMode = .journal
    @State private var captured: UIImage?
    @State private var watermarked: UIImage?
    @State private var snapshot: WatermarkSnapshot?
    @State private var note = ""
    @State private var tags: Set<LogTag> = []
    @State private var aiLabel: String?
    @State private var aiExplanation: String?
    @State private var pendingAI = false
    @State private var recognizing = false
    @State private var errorText: String?
    @State private var cameraUnavailable = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var docHint = "检验报告"
    @State private var medicalDocResult: MedicalDocResult?

    var body: some View {
        NavigationStack {
            VStack {
                if watermarked == nil && captured == nil {
                    Picker("模式", selection: $mode) {
                        ForEach(CaptureMode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.top, 4)
                }
                if let medicalDocResult, mode == .medicalDoc {
                    medicalDocReview(medicalDocResult)
                } else if mode == .medicalDoc, let captured {
                    medicalDocCaptureReview(captured)
                } else if let watermarked {
                    review(watermarked)
                } else if cameraUnavailable {
                    fallbackCapture
                } else {
                    CameraPreview(
                        onCapture: { image in
                            Task { await handleCapture(image) }
                        },
                        onUnavailable: {
                            cameraUnavailable = true
                        }
                    )
                    .ignoresSafeArea()
                }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onChange(of: pickerItem) { _, item in
                Task { await importPicked(item) }
            }
        }
    }

    private var navTitle: String {
        if watermarked != nil || captured != nil {
            return mode == .medicalDoc ? "病历识别" : "补充（可跳过）"
        }
        return mode == .medicalDoc ? "病历/报告识别" : "水印相机"
    }

    private var fallbackCapture: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 48))
                .foregroundStyle(CareTheme.sage)
            Text("模拟器没有摄像头，可以用演示照片或相册完成水印手帐。")
                .multilineTextAlignment(.center)
                .foregroundStyle(CareTheme.muted)
            Button("使用演示照片") {
                Task { await handleCapture(DemoPhoto.make()) }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("camera.demoPhoto")
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Text("从相册选择")
            }
            DisclaimerBanner(compact: true)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CareTheme.paper.ignoresSafeArea())
    }

    @ViewBuilder
    private func review(_ image: UIImage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                TextField("想写一句就写，不写也能保存", text: $note, axis: .vertical)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(LogTag.allCases) { tag in
                            let on = tags.contains(tag)
                            Button(tag.rawValue) {
                                if on { tags.remove(tag) } else { tags.insert(tag) }
                            }
                            .buttonStyle(.bordered)
                            .tint(on ? CareTheme.sage : CareTheme.muted)
                        }
                    }
                }
                if recognizing {
                    ProgressView("正在识别（需你确认）…")
                }
                if let aiLabel {
                    VStack(alignment: .leading) {
                        Text("识别：\(aiLabel)")
                        if let aiExplanation { Text(aiExplanation).font(.caption) }
                        Text("识别结果必须由你确认后才写入档案")
                            .font(.caption)
                            .foregroundStyle(CareTheme.warn)
                    }
                }
                if let errorText {
                    Text(errorText).foregroundStyle(CareTheme.danger).font(.caption)
                }
                HStack {
                    Button("直接保存") { save(confirmAI: false) }
                    .accessibilityIdentifier("camera.saveDirect")
                    Button("识别食物") { Task { await recognizeFood() } }
                    if aiLabel != nil {
                        Button("确认识别") { save(confirmAI: true) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                DisclaimerBanner(compact: true)
            }
            .padding()
        }
        .background(CareTheme.paper.ignoresSafeArea())
    }

    private func handleCapture(_ image: UIImage) async {
        captured = image
        if mode == .medicalDoc {
            return
        }
        let profile = env.profile()
        let snap = await env.healthProvider.watermarkSnapshot(at: Date())
        snapshot = snap
        let composed = WatermarkComposer.compose(
            image,
            snapshot: snap,
            includeSensitive: profile.showBPOnWatermark || profile.showGlucoseOnWatermark
        )
        watermarked = composed
    }

    private func recognizeFood() async {
        guard let captured else { return }
        recognizing = true
        errorText = nil
        defer { recognizing = false }
        let llm = env.currentLLM()
        if !llm.supportsVision {
            errorText = "当前模型不支持看图，请到「我的 → 模型服务」切换到多模态模型。"
            pendingAI = true
            return
        }
        do {
            let jpeg = captured.jpegData(compressionQuality: 0.7) ?? Data()
            let prompt = LLMPrompt(
                system: "你只描述食物可能类别与是否高糖/高盐的提示，不做诊断。输出 JSON {label, explanation}",
                user: "请识别这张饮食照片，给出简短中文标签和解释，必须由用户确认。",
                images: [jpeg]
            )
            let result = try await llm.complete(prompt: prompt)
            if let obj = LLMJSON.object(from: result.text) {
                aiLabel = obj["label"] as? String
                aiExplanation = obj["explanation"] as? String
            } else {
                aiLabel = "待确认的食物记录"
                aiExplanation = result.text
            }
            tags.insert(.diet)
            pendingAI = true
        } catch {
            errorText = "识别暂不可用，可手动打标签。\(error.localizedDescription)"
            pendingAI = true
        }
    }

    private func save(confirmAI: Bool) {
        guard let watermarked, let snapshot else { return }
        do {
            let ref = try PhotoStore.saveJPEG(watermarked)
            var structured = DailyStructuredFields()
            structured.recognizedFoodLabel = confirmAI ? aiLabel : nil
            structured.recognizedExplanation = confirmAI ? aiExplanation : nil
            let entry = DailyLogEntry(
                kind: .photo,
                photoRef: ref,
                watermark: snapshot,
                contentText: note,
                tags: tags.map(\.rawValue),
                structured: structured,
                confirmation: confirmAI ? .confirmed : (pendingAI ? .pendingAI : .skipped)
            )
            entry.aiLabel = aiLabel
            entry.aiExplanation = aiExplanation
            env.context.insert(entry)
            try env.context.save()
            Task { await env.refreshTodayPipeline() }
            dismiss()
        } catch {
            errorText = "保存失败"
        }
    }

    @ViewBuilder
    private func medicalDocCaptureReview(_ image: UIImage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                Picker("文档类型", selection: $docHint) {
                    ForEach(docHintOptions, id: \.self) { Text($0) }
                }
                .pickerStyle(.menu)

                if recognizing {
                    ProgressView("正在识别文档内容…")
                }
                if let errorText {
                    Text(errorText).foregroundStyle(CareTheme.danger).font(.caption)
                }

                HStack {
                    Button("重新拍照") {
                        captured = nil
                        medicalDocResult = nil
                    }
                    Button("识别这份文档") { Task { await recognizeMedicalDocument() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(recognizing)
                }

                Text(CareLoopCopy.notADiagnosis)
                    .font(.caption)
                    .foregroundStyle(CareTheme.muted)
            }
            .padding()
        }
        .background(CareTheme.paper.ignoresSafeArea())
    }

    private func recognizeMedicalDocument() async {
        guard let captured else { return }
        recognizing = true
        errorText = nil
        defer { recognizing = false }
        do {
            let llm = env.currentLLM()
            let result = try await MedicalDocumentAnalyzer.analyze(
                image: captured,
                docHint: docHint,
                llm: llm
            )
            medicalDocResult = result
        } catch {
            errorText = "识别失败：\(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private func medicalDocReview(_ result: MedicalDocResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(result.docType)
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(CareTheme.sage.opacity(0.15))
                        .clipShape(Capsule())
                    if let takenAt = result.takenAt {
                        Text(takenAt).font(.caption).foregroundStyle(CareTheme.muted)
                    }
                }

                if let title = result.title, !title.isEmpty {
                    Text(title).font(.headline)
                }

                if !result.diagnoses.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("诊断").font(.caption.bold()).foregroundStyle(CareTheme.muted)
                        ForEach(result.diagnoses, id: \.self) { dx in
                            Text("• \(dx)")
                        }
                    }
                }

                if !result.labValues.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("检验值").font(.caption.bold()).foregroundStyle(CareTheme.muted)
                        ForEach(result.labValues, id: \.name) { lab in
                            HStack {
                                Text(lab.name)
                                Spacer()
                                Text("\(lab.value)\(lab.unit.map { " \($0)" } ?? "")")
                                    .monospacedDigit()
                                if let flag = lab.flag {
                                    Image(systemName: flag == "high" ? "arrow.up.circle.fill" : flag == "low" ? "arrow.down.circle.fill" : "checkmark.circle")
                                        .foregroundStyle(flag == "high" ? CareTheme.danger : flag == "low" ? Color.orange : CareTheme.sage)
                                }
                            }
                            .font(.subheadline)
                        }
                    }
                }

                if !result.medications.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("用药").font(.caption.bold()).foregroundStyle(CareTheme.muted)
                        ForEach(result.medications, id: \.name) { med in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(med.name)
                                    if let dose = med.dose { Text(dose).foregroundStyle(CareTheme.muted) }
                                }
                                .font(.subheadline)
                                HStack(spacing: 6) {
                                    if let freq = med.frequency {
                                        Text(freq)
                                            .font(.caption)
                                            .foregroundStyle(CareTheme.sage)
                                    }
                                    if let times = med.timesOfDay, !times.isEmpty {
                                        Text(times.joined(separator: ", "))
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(CareTheme.muted)
                                    }
                                }
                            }
                        }
                    }
                }

                if !result.recommendations.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("建议").font(.caption.bold()).foregroundStyle(CareTheme.muted)
                        ForEach(result.recommendations, id: \.self) { rec in
                            Text("• \(rec)")
                        }
                    }
                }

                if let followUp = result.followUpHint {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(followUp, systemImage: "calendar")
                            .font(.subheadline)
                            .foregroundStyle(CareTheme.sage)
                        if let dateStr = result.followUpDate {
                            HStack(spacing: 4) {
                                Text("复诊日期：\(dateStr)")
                                if let dept = result.followUpDepartment {
                                    Text("·")
                                    Text(dept)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(CareTheme.muted)
                        }
                    }
                } else if let dateStr = result.followUpDate {
                    HStack(spacing: 4) {
                        Label("复诊：\(dateStr)", systemImage: "calendar")
                            .font(.subheadline)
                        if let dept = result.followUpDepartment {
                            Text("· \(dept)")
                        }
                    }
                    .foregroundStyle(CareTheme.sage)
                }

                Text(result.summary)
                    .font(.subheadline)
                    .padding(.top, 4)

                Text("识别结果需由你确认后才写入档案")
                    .font(.caption)
                    .foregroundStyle(CareTheme.warn)

                HStack {
                    Button("重新识别") {
                        medicalDocResult = nil
                        captured = nil
                    }
                    Button("确认并保存") { saveMedicalDoc(result) }
                        .buttonStyle(.borderedProminent)
                }

                Text(CareLoopCopy.medicalDisclaimer)
                    .font(.caption)
                    .foregroundStyle(CareTheme.muted)
            }
            .padding()
        }
        .background(CareTheme.paper.ignoresSafeArea())
    }

    private func saveMedicalDoc(_ result: MedicalDocResult) {
        do {
            var photoRef: String?
            if let captured, let jpeg = captured.jpegData(compressionQuality: 0.8) {
                let fileName = "medicaldoc-\(UUID().uuidString).jpg"
                let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(fileName)
                try jpeg.write(to: url)
                photoRef = url.path
            }

            var structured = DailyStructuredFields()
            structured.medicalDoc = result
            let entry = DailyLogEntry(
                kind: .medicalDoc,
                photoRef: photoRef,
                watermark: nil,
                contentText: result.summary,
                tags: [LogTag.symptom.rawValue],
                structured: structured,
                confirmation: .confirmed
            )
            entry.aiLabel = result.title ?? result.docType
            entry.aiExplanation = result.summary
            env.context.insert(entry)

            let prescribedDate = PrescriptionParser.parseDate(result.takenAt)

            MedicationImporter.importMedications(from: result, into: env.context, source: .medicalDocOCR)

            if let dateStr = result.followUpDate, let followDate = PrescriptionParser.parseDate(dateStr) {
                let followUp = FollowUp(
                    mode: .doctorOrdered,
                    date: followDate,
                    department: result.followUpDepartment ?? "",
                    notes: result.followUpHint ?? "",
                    confirmedByUser: true
                )
                env.context.insert(followUp)
            }

            try env.context.save()
            Task { await env.refreshTodayPipeline() }
            dismiss()
        } catch {
            errorText = "保存失败"
        }
    }

    private func importPicked(_ item: PhotosPickerItem?) async {
        guard let item, let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return }
        await handleCapture(image)
    }
}

struct CameraPreview: UIViewControllerRepresentable {
    var onCapture: (UIImage) -> Void
    var onUnavailable: () -> Void

    func makeUIViewController(context: Context) -> CameraViewController {
        let controller = CameraViewController()
        controller.onCapture = onCapture
        controller.onUnavailable = onUnavailable
        return controller
    }

    func updateUIViewController(_ uiViewController: CameraViewController, context: Context) {
        uiViewController.onCapture = onCapture
        uiViewController.onUnavailable = onUnavailable
    }
}

final class CameraViewController: UIViewController {
    var onCapture: ((UIImage) -> Void)?
    var onUnavailable: (() -> Void)?
    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var preview: AVCaptureVideoPreviewLayer?
    private let shutter = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configure()
        shutter.backgroundColor = UIColor.white
        shutter.layer.cornerRadius = 36
        shutter.accessibilityIdentifier = "camera.shutter"
        shutter.translatesAutoresizingMaskIntoConstraints = false
        shutter.addTarget(self, action: #selector(shoot), for: .touchUpInside)
        view.addSubview(shutter)
        NSLayoutConstraint.activate([
            shutter.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            shutter.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            shutter.widthAnchor.constraint(equalToConstant: 72),
            shutter.heightAnchor.constraint(equalToConstant: 72),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .photo
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.onUnavailable?() }
            return
        }
        session.addInput(input)
        if session.canAddOutput(output) {
            session.addOutput(output)
        }
        session.commitConfiguration()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.insertSublayer(layer, at: 0)
        preview = layer
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.startRunning()
        }
    }

    @objc private func shoot() {
        let settings = AVCapturePhotoSettings()
        output.capturePhoto(with: settings, delegate: self)
    }
}

extension CameraViewController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else { return }
        DispatchQueue.main.async {
            self.onCapture?(image)
        }
    }
}
