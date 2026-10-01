import Foundation

enum LiveExport {
    static func snapshot(connected: Bool, reading: PLXReading?, extra: MasimoReading?,
                         receivedAt: Date?, now: Date) -> [String: Any] {
        let age = receivedAt.map { now.timeIntervalSince($0) }
        let fresh = connected && reading?.continuous == true && age.map { $0 >= 0 && $0 < 5 } == true
        let clock = ISO8601DateFormatter()
        clock.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func value(_ number: Double?) -> Any {
            if fresh, let number = number { return number }
            return NSNull()
        }
        return ["schema_version": 1, "source": "bluetooth", "connected": connected, "fresh": fresh,
                "received_at": receivedAt.map { clock.string(from: $0) } as Any? ?? NSNull(),
                "valid_until": receivedAt.map { clock.string(from: $0.addingTimeInterval(5)) } as Any? ?? NSNull(),
                "measurements": ["spo2_percent": value(reading?.oxygen), "pulse_bpm": value(reading?.pulse),
                    "rrp_per_min": value(extra?.respiratoryRate), "pvi_percent": value(extra?.pvi),
                    "pi_percent": value(extra?.pi)]]
    }
}
