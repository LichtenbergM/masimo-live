import SwiftUI
import AVFoundation
import CoreMediaIO
import Vision

struct USBScreenSource: Identifiable {
    let id: String
    let name: String
}

final class USBReader: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var sources: [USBScreenSource] = []
    @Published var selectedID = ""
    @Published var running = false
    @Published var status = L10n.text("iPhone via USB")
    @Published var detail = L10n.text("Connect and unlock your iPhone, then open the Masimo app’s Home screen.")
    @Published var reading: ScreenReading?
    @Published var readingDate: Date?
    @Published var frames = 0
    @Published var error: String?
    private var discovery: AVCaptureDevice.DiscoverySession?
    private var timer: Timer?
    private var generation = UUID()
    private let queue = DispatchQueue(label: "de.maurice.masimo.usb")
    private var session: AVCaptureSession?
    private var output: AVCaptureVideoDataOutput?
    private var sessionGeneration = UUID()
    private var lastAnalysis = Date.distantPast
    private var capture: Capture?
    private var runtimeObserver: NSObjectProtocol?
    private var receivedSamples = 0
    private var loggedLayout = false
    private var startedAt: Date?
    private var lastFrameDate: Date?

    override init() {
        super.init()
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var enabled: UInt32 = 1
        let result = CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address,
            0, nil, UInt32(MemoryLayout<UInt32>.size), &enabled)
        if result != 0 { error = L10n.format("Could not prepare USB screen access (%d).", result) }
        discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed, position: .unspecified)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    deinit {
        timer?.invalidate()
        if let observer = runtimeObserver { NotificationCenter.default.removeObserver(observer) }
    }

    private var screenDevices: [AVCaptureDevice] {
        let typed = discovery?.devices ?? []
        // Older iOS screen drivers are not included in typed external discovery.
        let legacy = AVCaptureDevice.devices(for: .muxed)
        var seen = Set<String>()
        return (typed + legacy).filter { $0.isConnected && $0.hasMediaType(.muxed) && seen.insert($0.uniqueID).inserted }
    }

    func refresh() {
        // Muxed USB screen sources exclude video-only webcams and Continuity cameras.
        let devices = screenDevices
        sources = devices.map { USBScreenSource(id: $0.uniqueID, name: $0.localizedName) }
        if !running && !sources.contains(where: { $0.id == selectedID }) { selectedID = sources.first?.id ?? "" }
        if running && !sources.contains(where: { $0.id == selectedID }) {
            stop()
            status = L10n.text("USB disconnected")
            detail = L10n.text("Reconnect your iPhone and choose “Read iPhone”.")
        } else if running, let last = lastFrameDate ?? startedAt, Date().timeIntervalSince(last) > 5 {
            reading = nil; readingDate = nil
            status = frames == 0 ? L10n.text("No USB screen data yet") : L10n.text("USB screen feed interrupted")
            detail = L10n.text("Unlock your iPhone and keep the Masimo app visible. Stop and restart reading if needed.")
        }
    }

    func start() {
        guard !running, let device = screenDevices.first(where: { $0.uniqueID == selectedID }) else { return }
        generation = UUID()
        let attempt = generation
        running = true; reading = nil; readingDate = nil; frames = 0; error = nil
        startedAt = Date(); lastFrameDate = nil
        status = L10n.text("Opening iPhone screen…")
        detail = L10n.text("Keep the Masimo app visible on your iPhone.")
        let directory = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("captures/usb", isDirectory: true)
        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                let session = AVCaptureSession()
                session.beginConfiguration()
                let input = try AVCaptureDeviceInput(device: device)
                for port in input.ports where port.mediaType != .video { port.isEnabled = false }
                guard session.canAddInput(input) else { throw USBError.inputUnavailable }
                session.addInput(input)
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                output.setSampleBufferDelegate(self, queue: self.queue)
                guard session.canAddOutput(output) else { throw USBError.outputUnavailable }
                session.addOutput(output)
                if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
                session.commitConfiguration()
                self.session = session; self.output = output; self.sessionGeneration = attempt
                self.lastAnalysis = .distantPast
                self.receivedSamples = 0
                self.loggedLayout = false
                self.capture = try Capture(directory: directory)
                if let observer = self.runtimeObserver { NotificationCenter.default.removeObserver(observer) }
                self.runtimeObserver = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] notification in
                    let message = (notification.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? L10n.text("Unknown USB video error")
                    DispatchQueue.main.async {
                        guard let self = self, self.generation == attempt else { return }
                        self.reading = nil; self.readingDate = nil
                        self.error = message; self.status = L10n.text("USB video error")
                    }
                }
                session.startRunning()
                try self.capture?.append("usb_setup", fields: [
                    "ports": input.ports.map { $0.mediaType.rawValue + ":" + String($0.isEnabled) }.joined(separator: ","),
                    "running": String(session.isRunning),
                    "video_connection": String(output.connection(with: .video) != nil),
                    "video_active": String(output.connection(with: .video)?.isActive ?? false),
                    "video_authorization": String(AVCaptureDevice.authorizationStatus(for: .video).rawValue)])
                DispatchQueue.main.async {
                    guard self.generation == attempt else { return }
                    self.status = L10n.text("Reading iPhone screen")
                    self.detail = L10n.text("Source: Masimo app on iPhone · USB · local text recognition.")
                }
            } catch {
                self.session?.stopRunning(); self.session = nil; self.output = nil; self.capture = nil
                DispatchQueue.main.async {
                    guard self.generation == attempt else { return }
                    self.running = false; self.status = L10n.text("USB reading did not start")
                    self.error = error.localizedDescription
                    self.detail = L10n.text("Unlock your iPhone. If QuickTime is using its screen, close the preview and try again.")
                }
            }
        }
    }

    func stop() {
        generation = UUID(); running = false; reading = nil; readingDate = nil
        status = L10n.text("USB reading stopped")
        detail = L10n.text("Select your iPhone and choose “Read iPhone”.")
        queue.async { [weak self] in
            self?.session?.stopRunning()
            try? self?.capture?.snapshot(["source": "iphone_usb_screen", "status": "stopped", "updated_at": ISO8601DateFormatter().string(from: Date())])
            self?.session = nil; self?.output = nil; self?.capture = nil
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard output === self.output else { return }
        let date = Date()
        receivedSamples += 1
        if receivedSamples == 1 {
            let pixels = CMSampleBufferGetImageBuffer(sampleBuffer)
            try? capture?.append("usb_first_sample", fields: ["pixel_buffer": String(pixels != nil), "sample_count": String(CMSampleBufferGetNumSamples(sampleBuffer)), "width": pixels.map { String(CVPixelBufferGetWidth($0)) } ?? "", "height": pixels.map { String(CVPixelBufferGetHeight($0)) } ?? ""])
        }
        guard date.timeIntervalSince(lastAnalysis) >= 1, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastAnalysis = date
        let attempt = sessionGeneration
        do {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up).perform([request])
            let texts = (request.results ?? []).compactMap { observation -> ScreenText? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let box = observation.boundingBox
                return ScreenText(text: candidate.string, x: box.midX, y: 1 - box.midY,
                    height: box.height, confidence: Double(candidate.confidence))
            }
            let value = MasimoScreenParser.decode(texts)
            if value == nil && !loggedLayout {
                let labels = Set(["PR", "RRP", "PVI", "PI", "SPO2", "SPO₂", "SPOZ"])
                if texts.filter({ labels.contains($0.text.uppercased()) }).count >= 3 {
                    // Only log numeric tokens and known measurement labels from a recognised Masimo layout.
                    let safe = texts.filter { labels.contains($0.text.uppercased()) || ["home", "history", "options"].contains($0.text.lowercased()) || $0.text.range(of: "^[0-9]+([.,][0-9]+)?$", options: .regularExpression) != nil }
                    let summary = safe.map { "\($0.text) x=\($0.x) y=\($0.y) h=\($0.height) c=\($0.confidence)" }.joined(separator: " | ")
                    try? capture?.append("usb_ocr_layout", fields: ["layout": summary])
                    loggedLayout = true
                }
            }
            var saveError: String?
            if let value = value {
                do {
                    let fields = ["source": "iphone_usb_screen", "oxygen": String(value.oxygen),
                        "pulse": String(value.pulse), "rrp": value.respiration.map { String($0) } ?? "", "pvi": value.pvi.map { String($0) } ?? "", "pi": value.pi.map { String($0) } ?? ""]
                    try capture?.append("screen_reading", fields: fields)
                    try capture?.snapshot(fields.merging(["updated_at": ISO8601DateFormatter().string(from: date)]) { _, new in new })
                } catch { saveError = L10n.format("Recording failed: %@", error.localizedDescription) }
            } else {
                do {
                    try capture?.snapshot(["source": "iphone_usb_screen", "status": "no_readable_values", "updated_at": ISO8601DateFormatter().string(from: date)])
                } catch { saveError = L10n.format("Recording failed: %@", error.localizedDescription) }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.generation == attempt, self.running else { return }
                self.frames += 1; self.lastFrameDate = date; self.reading = value; self.readingDate = value == nil ? nil : date
                self.error = saveError
                self.status = value == nil ? L10n.text("Waiting for a readable Masimo screen") : L10n.text("Reading iPhone values")
                self.detail = value == nil
                    ? L10n.text("Open the Masimo app’s Home screen on your iPhone. SpO₂ and pulse must be readable.")
                    : L10n.text("Source: iPhone screen via USB · values recognized locally.")
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.generation == attempt else { return }
                self.frames += 1; self.lastFrameDate = date
                self.reading = nil; self.readingDate = nil
                self.error = L10n.format("Text recognition failed: %@", error.localizedDescription)
            }
        }
    }

    private enum USBError: LocalizedError {
        case inputUnavailable, outputUnavailable
        var errorDescription: String? { L10n.text("The USB screen cannot be opened right now.") }
    }
}

struct USBReaderView: View {
    @StateObject private var reader = USBReader()
    @State private var now = Date()
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Label(reader.status, systemImage: "iphone").font(.title3.bold())
                Text(reader.detail).fixedSize(horizontal: false, vertical: true)
                if let error = reader.error { Text(error).foregroundStyle(.red) }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 16) {
                if !reader.sources.isEmpty {
                    Picker("iPhone", selection: $reader.selectedID) {
                        ForEach(reader.sources) { source in Text(source.name).tag(source.id) }
                    }.disabled(reader.running)
                } else {
                    Text(L10n.text("No iPhone screen found yet.")).foregroundStyle(.secondary)
                }
                Button(reader.running ? L10n.text("Stop reading") : L10n.text("Read iPhone")) {
                    if reader.running { reader.stop() } else { reader.start() }
                }.buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!reader.running && reader.sources.isEmpty)
            }
            let fresh = reader.readingDate.map { now.timeIntervalSince($0) < 5 } ?? false
            let value = fresh ? reader.reading : nil
            HStack(spacing: 16) {
                metric(L10n.text("Oxygen saturation"), value?.oxygen, "%", large: true)
                metric(L10n.text("Pulse rate"), value?.pulse, "bpm", large: true)
            }
            HStack(spacing: 16) {
                metric("RRp", value?.respiration, "/min")
                metric("PVI", value?.pvi, "")
                metric("PI", value?.pi, "", decimals: true)
            }
            Text(value == nil ? L10n.text("No current, readable screen values yet.")
                 : L10n.format("Screen analyzed at %@", reader.readingDate!.formatted(date: .omitted, time: .standard)))
                .foregroundStyle(.secondary)
            Text(L10n.text("Keep the Masimo app open on your iPhone. This mode reads the USB screen feed."))
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                Text(L10n.format("Screen checks: %ld", reader.frames)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("Open recordings")) {
                    let path = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("captures/usb", isDirectory: true)
                    do {
                        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(path)
                    } catch { reader.error = error.localizedDescription }
                }
            }
        }.onReceive(clock) { now = $0 }.onDisappear { reader.stop() }
    }

    private func metric(_ title: String, _ value: Double?, _ unit: String, large: Bool = false, decimals: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value.map { String(format: decimals ? "%.1f" : "%.0f", $0) } ?? "—")
                    .font(.system(size: large ? 48 : 32, weight: .bold, design: .rounded)).monospacedDigit()
                Text(unit).foregroundStyle(.secondary)
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }
}
