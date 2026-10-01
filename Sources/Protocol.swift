import Foundation

struct MasimoFrame: Equatable {
    let bytes: [UInt8]
    var opcode: UInt8 { bytes[2] }
}

struct MasimoReading: Equatable {
    let oxygen: Double
    let pulse: Double
    let respiratoryRate: Double?
    let pvi: Double?
    let pi: Double?
}

struct MasimoLiveSession {
    private enum State { case idle, awaitingStatus, readyToStart, started }
    private var state = State.idle

    mutating func begin() -> [UInt8]? {
        guard state == .idle else { return nil }
        state = .awaitingStatus
        return [0x77, 0x02, 0x01, 0x07]
    }

    mutating func receive(_ frame: MasimoFrame) {
        guard state == .awaitingStatus, MasimoProtocol.validFrame(frame),
              frame.bytes.count == 22, frame.opcode == 1,
              frame.bytes[3] == 0x63, frame.bytes[4] == 0x10 else { return }
        state = .readyToStart
    }

    mutating func nextCommand(canSend: Bool) -> [UInt8]? {
        guard state == .readyToStart, canSend else { return nil }
        state = .started
        // Exact activation observed on this MightySat Rx, firmware 1.0.6.3.
        return [0x77, 0x05, 0x03, 0x1F, 0x00, 0x03, 0xD6]
    }
}

struct MasimoFrameDecoder {
    private var buffer: [UInt8] = []

    mutating func append(_ bytes: [UInt8]) -> [MasimoFrame] {
        buffer.append(contentsOf: bytes)
        var frames: [MasimoFrame] = []
        while buffer.count >= 2 {
            guard buffer[0] == 0x77, buffer[1] >= 2 else {
                buffer.removeFirst(); continue
            }
            let count = Int(buffer[1]) + 2
            guard buffer.count >= count else { break }
            let frame = Array(buffer.prefix(count))
            var crc: UInt8 = 0
            for byte in frame[2..<(count - 1)] {
                crc ^= byte
                for _ in 0..<8 {
                    crc = crc & 0x80 != 0 ? (crc &<< 1) ^ 0x07 : crc &<< 1
                }
            }
            guard crc == frame[count - 1] else { buffer.removeFirst(); continue }
            frames.append(MasimoFrame(bytes: frame))
            buffer.removeFirst(count)
        }
        return frames
    }
}

enum MasimoProtocol {
    static let service = "54C21000-A720-4B4F-11E4-9FE20002A5D5"
    static let transmit = "54C21001-A720-4B4F-11E4-9FE20002A5D5"
    static let receive = "54C21002-A720-4B4F-11E4-9FE20002A5D5"

    static func validFrame(_ frame: MasimoFrame) -> Bool {
        var decoder = MasimoFrameDecoder()
        return decoder.append(frame.bytes) == [frame]
    }

    static func decodeLive(_ frame: MasimoFrame) -> MasimoReading? {
        let b = frame.bytes
        guard b.count == 19, validFrame(frame), frame.opcode == 5,
              b[3...7].allSatisfy({ $0 == 0 }), b[9] == 0,
              (1...100).contains(b[8]), b[10] > 0, b[10] != 255,
              b[11] == 0 || b[11] == 0x10 else { return nil }
        let pvi = Int(b[12]) | Int(b[13]) << 8
        let pi = Int(b[14]) | Int(b[15]) << 8
        // Only display observed status combinations. RRp flags 01/04 remain unexplained.
        let respiratoryRate = b[16] == 0 && (1...100).contains(b[17]) ? Double(b[17]) : nil
        return MasimoReading(oxygen: Double(b[8]), pulse: Double(b[10]),
            respiratoryRate: respiratoryRate, pvi: pvi <= 100 ? Double(pvi) : nil,
            pi: pi <= 2000 ? Double(pi) / 100 : nil)
    }

    // First observed request, without parameters. Do not replay clock-setting or archive requests.
    static func statusQuery(service: String, characteristic: String, notifying: Bool, canSend: Bool) -> [UInt8]? {
        guard service.uppercased() == self.service, characteristic.uppercased() == transmit,
              notifying, canSend else { return nil }
        return [0x77, 0x02, 0x01, 0x07]
    }
}

struct PLXReading: Equatable {
    let oxygen: Double
    let pulse: Double
    let continuous: Bool
}

enum DeviceProtocol {
    static func isMeasurementChannel(service: String, characteristic: String) -> Bool {
        let service = service.uppercased()
        let characteristic = characteristic.uppercased()
        if service == "54C21000-A720-4B4F-11E4-9FE20002A5D5" {
            return characteristic == "54C21002-A720-4B4F-11E4-9FE20002A5D5"
        }
        return service == "1822" && ["2A5E", "2A5F"].contains(characteristic)
    }

    static func isMasimo(_ name: String) -> Bool {
        let normalized = name.lowercased()
        return normalized.contains("mightysat") || normalized.contains("masimo") || normalized.hasPrefix("msat")
    }

    static func decode(characteristic: String, bytes: [UInt8]) -> PLXReading? {
        let uuid = characteristic.uppercased()
            .replacingOccurrences(of: "-0000-1000-8000-00805F9B34FB", with: "")
        let short = uuid.hasPrefix("0000") ? String(uuid.dropFirst(4)) : uuid
        guard short == "2A5F" || short == "2A5E", bytes.count >= 5 else { return nil }
        let continuous = short == "2A5F"
        let flags = bytes[0]
        var offset = 5
        if continuous {
            if flags & 1 != 0 { offset += 4 }
            if flags & 2 != 0 { offset += 4 }
        } else if flags & 1 != 0 {
            offset += 7
        }
        let statusFlag: UInt8 = continuous ? 4 : 2
        let sensorFlag: UInt8 = continuous ? 8 : 4
        let amplitudeFlag: UInt8 = continuous ? 16 : 8
        guard bytes.count >= offset else { return nil }
        if flags & statusFlag != 0 {
            guard bytes.count >= offset + 2 else { return nil }
            let status = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
            // Hide stored, estimated, demonstration, test, calibration and invalid readings.
            guard status & 0xFE40 == 0 else { return nil }
            offset += 2
        }
        if flags & sensorFlag != 0 {
            guard bytes.count >= offset + 3 else { return nil }
            guard bytes[offset...offset + 2].allSatisfy({ $0 == 0 }) else { return nil }
            offset += 3
        }
        if flags & amplitudeFlag != 0 { offset += 2 }
        guard bytes.count >= offset,
              let oxygen = sfloat(bytes[1], bytes[2]), let pulse = sfloat(bytes[3], bytes[4]),
              (0...100).contains(oxygen), pulse > 0, pulse <= 400 else { return nil }
        return PLXReading(oxygen: oxygen, pulse: pulse, continuous: continuous)
    }

    private static func sfloat(_ low: UInt8, _ high: UInt8) -> Double? {
        let word = Int(low) | Int(high) << 8
        var mantissa = word & 0x0FFF
        guard ![0x07FE, 0x07FF, 0x0800, 0x0801, 0x0802].contains(mantissa) else { return nil }
        if mantissa >= 0x0800 { mantissa -= 0x1000 }
        var exponent = (word >> 12) & 15
        if exponent >= 8 { exponent -= 16 }
        return Double(mantissa) * pow(10, Double(exponent))
    }
}
