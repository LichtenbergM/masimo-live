import SwiftUI
import CoreBluetooth
import AppKit

struct FoundDevice: Identifiable {
    let id: UUID
    let name: String
    let rssi: Int
}

final class BluetoothReader: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var status = "Bluetooth wird vorbereitet …"
    @Published var detail = "MightySat einschalten und die Masimo-App auf dem Handy schließen."
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
        } catch { captureError = "Live-Export fehlgeschlagen: \(error.localizedDescription)" }
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
            captureError = "Aufzeichnung fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            status = "Bluetooth bereit"
            if autoScan { autoScan = false; scan() }
        case .unauthorized:
            invalidateConnection()
            status = "Bluetooth-Zugriff fehlt"
            detail = "Systemeinstellungen → Datenschutz & Sicherheit → Bluetooth → Masimo Live erlauben."
        case .poweredOff:
            invalidateConnection()
            status = "Bluetooth ist ausgeschaltet"
            detail = "Bluetooth am Mac einschalten, danach „Gerät suchen“ wählen."
        case .unsupported:
            invalidateConnection()
            status = "Bluetooth LE nicht verfügbar"
            detail = "Dieser Mac unterstützt die benötigte Bluetooth-Verbindung nicht."
        default: status = "Bluetooth wird vorbereitet …"
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
            captureError = "Aufzeichnung kann nicht erstellt werden: \(error.localizedDescription)"
            return
        }
        devices = []; peripherals = [:]
        status = "MightySat wird gesucht …"
        detail = "Gerät am Finger lassen und Bluetooth am MightySat aktivieren. Suche läuft 30 Sekunden."
        scanning = true
        record("scan_started")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.central.stopScan(); self.scanning = false
            self.status = self.devices.isEmpty ? "Kein MightySat gefunden" : "Gerät auswählen"
            self.detail = self.devices.isEmpty
                ? "Gerät näher an den Mac legen, Finger hineinstecken und die Handy-App schließen. Dann erneut suchen."
                : "Wähle deinen MightySat aus der Liste."
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
            detail = "MightySat gefunden. Wähle „Verbinden“."
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
        status = "Verbindung wird aufgebaut …"
        detail = "Die Handy-App muss getrennt sein."
        generation = UUID()
        let attempt = generation
        record("connecting", ["id": id.uuidString])
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
        connectionTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            guard let self = self, self.generation == attempt, self.busy else { return }
            self.disconnect()
            self.status = "Verbindung hat zu lange gedauert"
            self.detail = "Masimo-App schließen, Gerät am Finger lassen und erneut verbinden."
            self.record("connection_timeout")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard active?.identifier == peripheral.identifier else { return }
        connectionTimer?.invalidate(); busy = false
        connectedName = devices.first(where: { $0.id == peripheral.identifier })?.name ?? peripheral.name ?? "MightySat"
        status = "Verbunden"
        detail = "Datenschnittstellen werden geprüft …"
        record("connected", ["id": peripheral.identifier.uuidString, "name": connectedName!])
        peripheral.discoverServices(nil)
        waitTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            guard let self = self, self.active?.state == .connected, self.reading == nil else { return }
            self.detail = self.protocolFrames > 0
                ? "Gültige Masimo-Antworten empfangen. „Live-Werte starten“ wählen."
                : self.canProbe
                ? "Empfangskanal bereit. „Live-Werte starten“ wählen."
                : self.measurementPackets == 0
                ? "Geräteinformationen gelesen. Noch keine Messdaten empfangen; ein Startbefehl könnte nötig sein."
                : "Rohdaten vom Messkanal empfangen. Das Format ist noch nicht ausgewertet."
            self.record("waiting_for_measurements", ["notifications": String(self.notifyCount)])
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard active?.identifier == peripheral.identifier else { return }
        invalidateConnection()
        status = "Verbindung fehlgeschlagen"
        detail = error?.localizedDescription ?? "Gerät erneut suchen und verbinden."
        record("connection_failed", ["error": detail])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard active?.identifier == peripheral.identifier else { return }
        invalidateConnection()
        status = "Verbindung getrennt"
        detail = error?.localizedDescription ?? "Gerät suchen, um erneut zu verbinden."
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
        status = "Verbindung getrennt"
        detail = "Gerät suchen, um erneut zu verbinden."
        record("disconnect_requested")
    }

    func startLive() {
        guard !probeSent, let peripheral = active, peripheral.state == .connected,
              let tx = transmitCharacteristic, tx.properties.contains(.writeWithoutResponse),
              MasimoProtocol.statusQuery(service: tx.service?.uuid.uuidString ?? "",
                characteristic: tx.uuid.uuidString, notifying: receiveNotifying,
                canSend: peripheral.canSendWriteWithoutResponse) != nil,
              let command = liveSession.begin() else {
            detail = "Live-Start noch nicht bereit. Empfangskanal und Sendebereitschaft prüfen."
            return
        }
        probeSent = true; canProbe = false
        detail = "Status wird abgefragt, danach startet die Live-Übertragung …"
        peripheral.writeValue(Data(command), for: tx, type: .withoutResponse)
        record("masimo_query", ["uuid": tx.uuid.uuidString, "hex": "77 02 01 07", "source": "observed_iphone_dialog"])
        waitTimer?.invalidate()
        let attempt = generation
        waitTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            guard let self = self, self.generation == attempt, self.liveFrames == 0 else { return }
            self.detail = "Keine Live-Pakete empfangen. Gerät am Finger lassen; bei Bedarf trennen und erneut verbinden."
            self.record("masimo_live_timeout")
        }
    }

    private func sendPendingLiveStart() {
        guard let peripheral = active, peripheral.state == .connected, receiveNotifying,
              let tx = transmitCharacteristic, tx.properties.contains(.writeWithoutResponse),
              tx.service?.uuid.uuidString == MasimoProtocol.service, tx.uuid.uuidString == MasimoProtocol.transmit,
              let command = liveSession.nextCommand(canSend: peripheral.canSendWriteWithoutResponse) else { return }
        peripheral.writeValue(Data(command), for: tx, type: .withoutResponse)
        detail = "Live-Übertragung aktiviert. Warte auf Messwerte …"
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
        detail = "Warte auf Messdaten. Aufzeichnung läuft lokal."
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
            detail = parsed.continuous ? "Standard-Messwerte werden empfangen." : "Eine Einzelmessung wurde empfangen."
        } else if DeviceProtocol.isMeasurementChannel(service: service, characteristic: uuid), liveFrames == 0 {
            detail = "Rohdaten vom Messkanal empfangen. Noch keine lesbaren Messwerte."
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
                    if liveFrames == 0 { detail = "Gültige Statusantwort empfangen." }
                case 5:
                    liveFrames += 1; waitTimer?.invalidate()
                    masimoReading = MasimoProtocol.decodeLive(frame)
                    reading = masimoReading.map { PLXReading(oxygen: $0.oxygen, pulse: $0.pulse, continuous: true) }
                    readingDate = reading == nil ? nil : Date()
                    detail = reading == nil
                        ? "Live-Paket empfangen, Messung fehlt oder Status ist unbekannt. Finger und Geräteanzeige prüfen."
                        : "Live-Messwerte direkt vom MightySat empfangen."
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
                    Text("MightySat-Messwerte am Mac").foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "waveform.path.ecg").font(.largeTitle).accessibilityHidden(true)
            }
            Picker("Datenquelle", selection: $source) {
                Text("iPhone per USB").tag("usb")
                Text("MightySat per Bluetooth").tag("bluetooth")
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
                    if let serial = reader.deviceInfo["2A25"] { Text("Seriennummer: \(serial)").textSelection(.enabled) }
                }
            }

            HStack(spacing: 16) {
                Button("Gerät suchen", action: reader.scan).buttonStyle(.borderedProminent).controlSize(.large)
                if reader.connectedName != nil || reader.busy {
                    Button("Trennen", action: reader.disconnect).controlSize(.large)
                }
                if reader.connectedName != nil {
                    Button("Live-Werte starten", action: reader.startLive).disabled(!reader.canProbe).controlSize(.large)
                }
                Button("Aufzeichnungen öffnen") {
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
                        Button("Verbinden") { reader.connect(device.id) }.controlSize(.large)
                    }.padding(16).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                }
            }

            let fresh = reader.readingDate.map { now.timeIntervalSince($0) < 5 } ?? false
            let value = fresh ? reader.reading : nil
            HStack(spacing: 16) {
                metric("Sauerstoffsättigung", value: value.map { String(format: "%.1f", $0.oxygen) } ?? "—", unit: "%")
                metric("Puls", value: value.map { String(format: "%.0f", $0.pulse) } ?? "—", unit: "bpm")
            }
            let extra = fresh ? reader.masimoReading : nil
            HStack(spacing: 16) {
                metric("RRp", value: extra?.respiratoryRate.map { String(format: "%.0f", $0) } ?? "—", unit: "/min")
                metric("PVI", value: extra?.pvi.map { String(format: "%.0f", $0) } ?? "—", unit: "%")
                metric("PI", value: extra?.pi.map { String(format: "%.1f", $0) } ?? "—", unit: "%")
            }
            Text(value.map { $0.continuous ? "Fortlaufende Messung · zuletzt \(reader.readingDate!.formatted(date: .omitted, time: .standard))" : "Einzelmessung · empfangen \(reader.readingDate!.formatted(date: .omitted, time: .standard))" }
                ?? "Noch keine aktuellen, lesbaren Messwerte.")
                .foregroundStyle(.secondary)

            Text("Experimentelle direkte Auslesung · unbekannte Statusflags werden ausgeblendet.")
                .font(.footnote).foregroundStyle(.secondary)

            DisclosureGroup("Verbindungsdetails · \(reader.visibleLiveFrames) Live-Pakete · \(reader.visibleProtocolFrames) gültige Masimo-Rahmen", isExpanded: $diagnostics) {
                HStack {
                    Button("Anzeige leeren", action: reader.clearDiagnostics)
                        .help("Sichtbare Zähler und Verbindungsdetails zurücksetzen. Die Messung läuft weiter.")
                    Spacer()
                    Text("Aufzeichnungsdateien bleiben erhalten.")
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
            Text("Alle Aufzeichnungen bleiben lokal auf diesem Mac.").font(.footnote).foregroundStyle(.secondary)
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
