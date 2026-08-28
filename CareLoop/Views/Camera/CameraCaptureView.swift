import AVFoundation
import PhotosUI
import SwiftUI
import UIKit

struct CameraCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var env
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

    var body: some View {
        NavigationStack {
            VStack {
                if let watermarked {
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
            .navigationTitle(watermarked == nil ? "水印相机" : "补充（可跳过）")
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
                    if tags.contains(.diet) {
                        Button("识别食物") { Task { await recognizeFood() } }
                    }
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
        let profile = env.profile()
        let snap = await env.healthProvider.watermarkSnapshot(at: Date())
        snapshot = snap
        let composed = WatermarkComposer.compose(
            image,
            snapshot: snap,
            includeSensitive: profile.showBPOnWatermark || profile.showGlucoseOnWatermark
        )
        captured = image
        watermarked = composed
    }

    private func recognizeFood() async {
        guard let captured else { return }
        recognizing = true
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
            if let data = result.text.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                aiLabel = obj["label"] as? String
                aiExplanation = obj["explanation"] as? String
            } else {
                aiLabel = "待确认的食物记录"
                aiExplanation = result.text
            }
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
