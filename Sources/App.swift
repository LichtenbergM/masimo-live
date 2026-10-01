import SwiftUI
import CoreBluetooth
import AppKit

struct FoundDevice: Identifiable {
    let id: UUID
    let name: String
    let rssi: Int
}

final class BluetoothReader: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var status = L10n.text("Preparing Bluetooth…")
    @Published var detail = L10n.text("Turn on your MightySat and close the Masimo app on your phone.")
    @Published var devices: [FoundDevice] = []
    @Published var connectedName: String?
    @Published var busy = false
    @Published var scanning = false
    @Published var packets = 0
    @Published var measurementPackets = 0
    @Published var protocolFrames = 0
    @Published var liveFrames = 0
    @Published private var liveFrameBaseline = 0
    @Published private var protocolFrameBaseline = 0
    @Published var canProbe = false
    @Published var deviceInfo: [String: String] = [:]
    @Published var reading: PLXReading?
    @Published var masimoReading: MasimoReading?
    @Published var readingDate: Date?
    @Published var log: [String] = []
    @Published var captureError: String?

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var active: CBPeripheral?
    private var capture: Capture?
    private var scanTimer: Timer?
    private var connectionTimer: Timer?
    private var waitTimer: Timer?
    private var autoScan = false
    private var notifyCount = 0
    private var generation = UUID()
    private var transmitCharacteristic: CBCharacteristic?
    private var receiveNotifying = false
    private var probeSent = false
    private var masimoDecoder = MasimoFrameDecoder()
    private var liveSession = MasimoLiveSession()
    private var exportTimer: Timer?

    var visibleLiveFrames: Int { liveFrames - liveFrameBaseline }
    var visibleProtocolFrames: Int { protocolFrames - protocolFrameBaseline }

    func clearDiagnostics() {
        liveFrameBaseline = liveFrames
        protocolFrameBaseline = protocolFrames
        log.removeAll()
        record("diagnostics_cleared")
    }

    var captureDirectory: URL {
        Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("captures", isDirectory: true)
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        publishLiveData()
        exportTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.publishLiveData()
        }
    }

    private func publishLiveData() {
        do {
            let fields = LiveExport.snapshot(connected: active?.state == .connected, reading: reading,
                extra: masimoReading, receivedAt: readingDate, now: Date())
            let target = captureDirectory.appendingPathComponent("live.json")
            try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]).write(to: target, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        } catch { captureError = L10n.format("Live export failed: %@", error.localizedDescription) }
    }

    func record(_ type: String, _ fields: [String: String] = [:]) {
        if type == "masimo_frame" && fields["opcode"] == "5" || type == "disconnected" || type == "disconnect_requested" {
            publishLiveData()
        }
        let summary = fields.keys.sorted().map { "\($0)=\(fields[$0]!)" }.joined(separator: "  ")
        log.append("\(Date().formatted(date: .omitted, time: .standard))  \(type)  \(summary)")
        if log.count > 250 { log.removeFirst(log.count - 250) }
        do {
            try capture?.append(type, fields: fields)
            try capture?.snapshot(["status": status, "detail": detail,
                "device": connectedName ?? "", "packet_count": String(packets),
                "measurement_packet_count": String(measurementPackets),
                "masimo_frame_count": String(protocolFrames),
                "live_frame_count": String(liveFrames),
                "oxygen": reading.map { String($0.oxygen) } ?? "",
                "pulse": reading.map { String($0.pulse) } ?? "",
                "respiratory_rate": masimoReading?.respiratoryRate.map { String($0) } ?? "",
                "pvi": masimoReading?.pvi.map { String($0) } ?? "",
                "pi": masimoReading?.pi.map { String($0) } ?? "",
                "capture_file": capture?.url.path ?? "", "updated_at": ISO8601DateFormatter().string(from: Date())])
        } catch {
            captureError = L10n.format("Recording failed: %@", error.localizedDescription)
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            status = L10n.text("Bluetooth ready")
            if autoScan { autoScan = false; scan() }
        case .unauthorized:
            invalidateConnection()
            status = L10n.text("Bluetooth access denied")
            detail = L10n.text("System Settings → Privacy & Security → Bluetooth → allow Masimo Live.")
        case .poweredOff:
            invalidateConnection()
            status = L10n.text("Bluetooth is off")
            detail = L10n.text("Enable Bluetooth on your Mac, then choose “Search for device”.")
        case .unsupported:
            invalidateConnection()
            status = L10n.text("Bluetooth LE unavailable")
            detail = L10n.text("This Mac does not support the required Bluetooth connection.")
        default: status = L10n.text("Preparing Bluetooth…")
        }
        record("bluetooth_state", ["state": String(central.state.rawValue)])
    }

    func scan() {
        guard central.state == .poweredOn else {
            centralManagerDidUpdateState(central); return
        }
        guard active == nil else { return }
        scanTimer?.invalidate()
        do {
            if capture == nil { capture = try Capture(directory: captureDirectory) }
        } catch {
            captureError = L10n.format("Could not create recording: %@", error.localizedDescription)
            return
        }
        devices = []; peripherals = [:]
        status = L10n.text("Searching for MightySat…")
        detail = L10n.text("Keep your finger in the device and enable its Bluetooth. Search runs for 30 seconds.")
        scanning = true
        record("scan_started")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.central.stopScan(); self.scanning = false
            self.status = self.devices.isEmpty ? L10n.text("No MightySat found") : L10n.text("Select a device")
            self.detail = self.devices.isEmpty
                ? L10n.text("Move the device closer, insert a finger, and close the phone app. Then search again.")
                : L10n.text("Select your MightySat from the list.")
            self.record("scan_finished", ["matches": String(self.devices.count)])
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
        guard DeviceProtocol.isMasimo(name), active == nil else { return }
        peripherals[peripheral.identifier] = peripheral
        if !devices.contains(where: { $0.id == peripheral.identifier }) {
            devices.append(FoundDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue))
            detail = L10n.text("MightySat found. Choose “Connect”.")
            record("device_found", ["name": name, "id": peripheral.identifier.uuidString,
                "rssi": RSSI.stringValue])
        }
    }

    func connect(_ id: UUID) {
        guard active == nil, let peripheral = peripherals[id] else { return }
        central.stopScan(); scanTimer?.invalidate(); scanning = false
        active = peripheral; busy = true; packets = 0; measurementPackets = 0; notifyCount = 0; deviceInfo = [:]
        protocolFrames = 0; canProbe = false; probeSent = false
        liveFrames = 0; liveSession = MasimoLiveSession(); masimoReading = nil
        liveFrameBaseline = 0; protocolFrameBaseline = 0
        receiveNotifying = false; transmitCharacteristic = nil; masimoDecoder = MasimoFrameDecoder()
        reading = nil; readingDate = nil
        status = L10n.text("Connecting…")
        detail = L10n.text("Disconnect the phone app first.")
        generation = UUID()
        let attempt = generation
        record("connecting", ["id": id.uuidString])
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
        connectionTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            guard let self = self, self.generation == attempt, self.busy else { return }
            self.disconnect()
            self.status = L10n.text("Connection timed out")
            self.detail = L10n.text("Close the Masimo app, keep your finger in the device, and reconnect.")
            self.record("connection_timeout")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard active?.identifier == peripheral.identifier else { return }
        connectionTimer?.invalidate(); busy = false
        connectedName = devices.first(where: { $0.id == peripheral.identifier })?.name ?? peripheral.name ?? "MightySat"
        status = L10n.text("Connected")
        detail = L10n.text("Checking data channels…")
        record("connected", ["id": peripheral.identifier.uuidString, "name": connectedName!])
        peripheral.discoverServices(nil)
        waitTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            guard let self = self, self.active?.state == .connected, self.reading == nil else { return }
            self.detail = self.protocolFrames > 0
                ? L10n.text("Valid Masimo responses received. Choose “Start live readings”.")
                : self.canProbe
                ? L10n.text("Receive channel ready. Choose “Start live readings”.")
                : self.measurementPackets == 0
                ? L10n.text("Device information received. No measurement packets yet; a start command may be needed.")
                : L10n.text("Raw measurement data received. The format has not been decoded yet.")
            self.record("waiting_for_measurements", ["notifications": String(self.notifyCount)])
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard active?.identifier == peripheral.identifier else { return }
        invalidateConnection()
        status = L10n.text("Connection failed")
        detail = error?.localizedDescription ?? L10n.text("Search for the device and connect again.")
        record("connection_failed", ["error": detail])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard active?.identifier == peripheral.identifier else { return }
        invalidateConnection()
        status = L10n.text("Disconnected")
        detail = error?.localizedDescription ?? L10n.text("Search for the device to reconnect.")
        record("disconnected", ["error": error?.localizedDescription ?? ""])
    }

    private func invalidateConnection() {
        scanTimer?.invalidate(); connectionTimer?.invalidate(); waitTimer?.invalidate()
        scanning = false; active = nil; connectedName = nil; busy = false
        reading = nil; readingDate = nil; generation = UUID()
        canProbe = false; probeSent = false; receiveNotifying = false
        transmitCharacteristic = nil; masimoDecoder = MasimoFrameDecoder()
        liveSession = MasimoLiveSession(); masimoReading = nil
    }

    func disconnect() {
        if let peripheral = active { central.cancelPeripheralConnection(peripheral) }
        central.stopScan()
        invalidateConnection()
        status = L10n.text("Disconnected")
        detail = L10n.text("Search for the device to reconnect.")
        record("disconnect_requested")
    }

    func startLive() {
        guard !probeSent, let peripheral = active, peripheral.state == .connected,
              let tx = transmitCharacteristic, tx.properties.contains(.writeWithoutResponse),
              MasimoProtocol.statusQuery(service: tx.service?.uuid.uuidString ?? "",
                characteristic: tx.uuid.uuidString, notifying: receiveNotifying,
                canSend: peripheral.canSendWriteWithoutResponse) != nil,
              let command = liveSession.begin() else {
            detail = L10n.text("Live start is not ready. Check the receive channel and send availability.")
            return
        }
        probeSent = true; canProbe = false
        detail = L10n.text("Requesting status, then starting live readings…")
        peripheral.writeValue(Data(command), for: tx, type: .withoutResponse)
        record("masimo_query", ["uuid": tx.uuid.uuidString, "hex": "77 02 01 07", "source": "observed_iphone_dialog"])
        waitTimer?.invalidate()
        let attempt = generation
        waitTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            guard let self = self, self.generation == attempt, self.liveFrames == 0 else { return }
            self.detail = L10n.text("No live packets received. Keep your finger in the device; disconnect and reconnect if needed.")
            self.record("masimo_live_timeout")
        }
    }

    private func sendPendingLiveStart() {
        guard let peripheral = active, peripheral.state == .connected, receiveNotifying,
              let tx = transmitCharacteristic, tx.properties.contains(.writeWithoutResponse),
              tx.service?.uuid.uuidString == MasimoProtocol.service, tx.uuid.uuidString == MasimoProtocol.transmit,
              let command = liveSession.nextCommand(canSend: peripheral.canSendWriteWithoutResponse) else { return }
        peripheral.writeValue(Data(command), for: tx, type: .withoutResponse)
        detail = L10n.text("Live streaming enabled. Waiting for readings…")
        record("masimo_live_start", ["hex": command.map { String(format: "%02X", $0) }.joined(separator: " "),
            "source": "observed_successful_iphone_dialog"])
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard active?.identifier == peripheral.identifier else { return }
        canProbe = !probeSent && receiveNotifying && transmitCharacteristic != nil
        sendPendingLiveStart()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard active?.identifier == peripheral.identifier else { return }
        if let error = error { detail = error.localizedDescription; record("service_error", ["error": detail]); return }
        for service in peripheral.services ?? [] {
            record("service", ["uuid": service.uuid.uuidString])
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard active?.identifier == peripheral.identifier else { return }
        if let error = error { record("characteristic_error", ["error": error.localizedDescription]); return }
        for characteristic in service.characteristics ?? [] {
            record("characteristic", ["service": service.uuid.uuidString,
                "uuid": characteristic.uuid.uuidString, "properties": String(characteristic.properties.rawValue)])
            if service.uuid.uuidString == MasimoProtocol.service,
               characteristic.uuid.uuidString == MasimoProtocol.transmit,
               characteristic.properties.contains(.writeWithoutResponse) {
                transmitCharacteristic = characteristic
            }
            if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
            if characteristic.properties.contains(.read) { peripheral.readValue(for: characteristic) }
        }
        canProbe = !probeSent && receiveNotifying && transmitCharacteristic != nil
        detail = L10n.text("Waiting for readings. Recording locally.")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard active?.identifier == peripheral.identifier else { return }
        if let error = error {
            record("subscription_error", ["uuid": characteristic.uuid.uuidString, "error": error.localizedDescription])
        } else {
            if characteristic.isNotifying { notifyCount += 1 }
            record("subscribed", ["uuid": characteristic.uuid.uuidString, "active": String(characteristic.isNotifying)])
        }
        if characteristic.service?.uuid.uuidString == MasimoProtocol.service,
           characteristic.uuid.uuidString == MasimoProtocol.receive {
            receiveNotifying = error == nil && characteristic.isNotifying
            canProbe = !probeSent && receiveNotifying && transmitCharacteristic != nil
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard active?.identifier == peripheral.identifier else { return }
        if let error = error {
            record("read_error", ["uuid": characteristic.uuid.uuidString, "error": error.localizedDescription]); return
        }
        guard let data = characteristic.value else { return }
        packets += 1
        let bytes = [UInt8](data)
        let uuid = characteristic.uuid.uuidString
        let service = characteristic.service?.uuid.uuidString ?? ""
        if DeviceProtocol.isMeasurementChannel(service: service, characteristic: uuid) {
            measurementPackets += 1
        }
        if service == "180A", ["2A24", "2A29", "2A25"].contains(uuid), let text = String(data: data, encoding: .utf8) {
            deviceInfo[uuid] = text
        }
        let parsed = DeviceProtocol.decode(characteristic: uuid, bytes: bytes)
        if uuid == "2A5F" || uuid == "2A5E" {
            reading = parsed; readingDate = parsed == nil ? nil : Date()
        }
        if let parsed = parsed {
            detail = parsed.continuous ? L10n.text("Receiving standard readings.") : L10n.text("Single measurement received.")
        } else if DeviceProtocol.isMeasurementChannel(service: service, characteristic: uuid), liveFrames == 0 {
            detail = L10n.text("Raw measurement data received. No readable values yet.")
        }
        record("packet", ["service": service, "uuid": uuid,
            "hex": bytes.map { String(format: "%02X", $0) }.joined(separator: " "),
            "text": deviceInfo[uuid] ?? "", "measurement_channel": String(DeviceProtocol.isMeasurementChannel(service: service, characteristic: uuid)),
            "oxygen": parsed.map { String($0.oxygen) } ?? "", "pulse": parsed.map { String($0.pulse) } ?? ""])
        if service == MasimoProtocol.service, uuid == MasimoProtocol.receive {
            for frame in masimoDecoder.append(bytes) {
                protocolFrames += 1
                liveSession.receive(frame)
                switch frame.opcode {
                case 1:
                    if liveFrames == 0 { detail = L10n.text("Valid status response received.") }
                case 5:
                    liveFrames += 1; waitTimer?.invalidate()
                    masimoReading = MasimoProtocol.decodeLive(frame)
                    reading = masimoReading.map { PLXReading(oxygen: $0.oxygen, pulse: $0.pulse, continuous: true) }
                    readingDate = reading == nil ? nil : Date()
                    detail = reading == nil
                        ? L10n.text("Live packet received, but readings are missing or the status is unknown. Check finger placement and the device display.")
                        : L10n.text("Receiving live readings directly from MightySat.")
                default: break
                }
                record("masimo_frame", ["opcode": String(frame.opcode), "crc_valid": "true",
                    "hex": frame.bytes.map { String(format: "%02X", $0) }.joined(separator: " "),
                    "oxygen": frame.opcode == 5 ? reading.map { String($0.oxygen) } ?? "" : "",
                    "pulse": frame.opcode == 5 ? reading.map { String($0.pulse) } ?? "" : ""])
                sendPendingLiveStart()
            }
        }
    }
}

struct ReaderView: View {
    @StateObject private var reader = BluetoothReader()
    @State private var source = "bluetooth"
    @State private var diagnostics = false
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Masimo Live").font(.largeTitle.bold())
                    Text(L10n.text("MightySat readings on your Mac")).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "waveform.path.ecg").font(.largeTitle).accessibilityHidden(true)
            }
            Picker(L10n.text("Data source"), selection: $source) {
                Text(L10n.text("iPhone via USB")).tag("usb")
                Text(L10n.text("MightySat via Bluetooth")).tag("bluetooth")
            }.pickerStyle(.segmented)
            if source == "usb" {
                USBReaderView()
            } else {
            VStack(alignment: .leading, spacing: 8) {
                Label(reader.status, systemImage: reader.connectedName == nil ? "antenna.radiowaves.left.and.right" : "checkmark.circle")
                    .font(.title3.bold())
                Text(reader.detail).fixedSize(horizontal: false, vertical: true)
                if let error = reader.captureError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))

            if reader.connectedName != nil && !reader.deviceInfo.isEmpty {
                HStack(spacing: 16) {
                    Text(reader.deviceInfo["2A24"] ?? "MightySat").font(.headline)
                    Text(reader.deviceInfo["2A29"] ?? "Masimo").foregroundStyle(.secondary)
                    Spacer()
                    if let serial = reader.deviceInfo["2A25"] { Text(L10n.format("Serial number: %@", serial)).textSelection(.enabled) }
                }
            }

            HStack(spacing: 16) {
                Button(L10n.text("Search for device"), action: reader.scan).buttonStyle(.borderedProminent).controlSize(.large)
                if reader.connectedName != nil || reader.busy {
                    Button(L10n.text("Disconnect"), action: reader.disconnect).controlSize(.large)
                }
                if reader.connectedName != nil {
                    Button(L10n.text("Start live readings"), action: reader.startLive).disabled(!reader.canProbe).controlSize(.large)
                }
                Button(L10n.text("Open recordings")) {
                    do {
                        try FileManager.default.createDirectory(at: reader.captureDirectory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(reader.captureDirectory)
                    } catch { reader.captureError = error.localizedDescription }
                }.controlSize(.large)
            }

            if reader.connectedName == nil && !reader.busy {
                ForEach(reader.devices) { device in
                    HStack {
                        Text(device.name).font(.headline)
                        Spacer()
                        Text("\(device.rssi) dBm").foregroundStyle(.secondary)
                        Button(L10n.text("Connect")) { reader.connect(device.id) }.controlSize(.large)
                    }.padding(16).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                }
            }

            let fresh = reader.readingDate.map { now.timeIntervalSince($0) < 5 } ?? false
            let value = fresh ? reader.reading : nil
            HStack(spacing: 16) {
                metric(L10n.text("Oxygen saturation"), value: value.map { String(format: "%.1f", $0.oxygen) } ?? "—", unit: "%")
                metric(L10n.text("Pulse rate"), value: value.map { String(format: "%.0f", $0.pulse) } ?? "—", unit: "bpm")
            }
            let extra = fresh ? reader.masimoReading : nil
            HStack(spacing: 16) {
                metric("RRp", value: extra?.respiratoryRate.map { String(format: "%.0f", $0) } ?? "—", unit: "/min")
                metric("PVI", value: extra?.pvi.map { String(format: "%.0f", $0) } ?? "—", unit: "%")
                metric("PI", value: extra?.pi.map { String(format: "%.1f", $0) } ?? "—", unit: "%")
            }
            Text(value.map { $0.continuous ? L10n.format("Continuous measurement · last received %@", reader.readingDate!.formatted(date: .omitted, time: .standard)) : L10n.format("Single measurement · received %@", reader.readingDate!.formatted(date: .omitted, time: .standard)) }
                ?? L10n.text("No current, readable measurements yet."))
                .foregroundStyle(.secondary)

            Text(L10n.text("Experimental direct readings · unknown status flags are hidden."))
                .font(.footnote).foregroundStyle(.secondary)

            DisclosureGroup(L10n.format("Connection details · Live packets: %ld · Valid Masimo frames: %ld", reader.visibleLiveFrames, reader.visibleProtocolFrames), isExpanded: $diagnostics) {
                HStack {
                    Button(L10n.text("Clear display"), action: reader.clearDiagnostics)
                        .help(L10n.text("Reset visible counters and connection details. Readings continue."))
                    Spacer()
                    Text(L10n.text("Recording files are kept."))
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 8)
                ScrollView {
                    Text(reader.log.suffix(100).joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }.frame(minHeight: 120, maxHeight: 220).padding(.top, 8)
            }
            }
            Spacer(minLength: 0)
            Text(L10n.text("All recordings stay on this Mac.")).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(32).frame(minWidth: 720, minHeight: 760)
        .onReceive(clock) { now = $0 }
        .onChange(of: source) { _, newValue in if newValue == "usb" { reader.disconnect() } }
    }

    private func metric(_ title: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value).font(.system(size: 48, weight: .bold, design: .rounded)).monospacedDigit()
                Text(unit).font(.title3).foregroundStyle(.secondary)
            }
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }
}

@main struct MasimoLiveApp: App {
    var body: some Scene {
        WindowGroup { ReaderView() }
            .defaultSize(width: 800, height: 820)
    }
}
