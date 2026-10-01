import Foundation

@main struct LiveExportTests {
    static func main() throws {
        var failures = 0
        func check(_ ok: @autoclosure () -> Bool, _ message: String) {
            if !ok() { failures += 1; print("FAIL: \(message)") }
        }
        let date = Date(timeIntervalSince1970: 1_893_499_200)
        let reading = PLXReading(oxygen: 96, pulse: 77, continuous: true)
        let extra = MasimoReading(oxygen: 96, pulse: 77, respiratoryRate: 13, pvi: 29, pi: 17)
        let current = LiveExport.snapshot(connected: true, reading: reading, extra: extra,
                                          receivedAt: date, now: date.addingTimeInterval(1))
        let values = current["measurements"] as? [String: Any] ?? [:]
        check(current["fresh"] as? Bool == true, "Exports a recent continuous reading as fresh")
        check(values["spo2_percent"] as? Double == 96 && values["pulse_bpm"] as? Double == 77,
              "Exports numeric primary values")
        check(values["rrp_per_min"] as? Double == 13 && values["pvi_percent"] as? Double == 29 &&
              values["pi_percent"] as? Double == 17, "Exports numeric optional values with explicit units")
        check(current["received_at"] as? String == "2030-01-01T12:00:00.000Z", "Preserves the measurement reception time")
        check(current["valid_until"] as? String == "2030-01-01T12:00:05.000Z", "Gives consumers an absolute expiry time")
        let cases: [(Bool, PLXReading?, Date?, Date)] = [
            (false, Optional(reading), Optional(date), date),
            (true, Optional(reading), Optional(date), date.addingTimeInterval(5)),
            (true, Optional(reading), Optional(date), date.addingTimeInterval(60)),
            (true, Optional(reading), Optional(date), date.addingTimeInterval(-1)),
            (true, Optional<PLXReading>.none, Optional(date), date),
            (true, Optional(reading), Optional<Date>.none, date),
            (true, Optional(PLXReading(oxygen: 96, pulse: 77, continuous: false)), Optional(date), date)
        ]
        for (connected, value, time, now) in cases {
            let d = LiveExport.snapshot(connected: connected, reading: value, extra: extra, receivedAt: time, now: now)
            let m = d["measurements"] as? [String: Any] ?? [:]
            check(d["fresh"] as? Bool == false, "Rejects disconnected, expired, future, missing or spot readings")
            check(m.count == 5 && m.values.allSatisfy { $0 is NSNull }, "Clears every exported value on invalid freshness")
        }
        let noExtras = LiveExport.snapshot(connected: true, reading: reading, extra: nil, receivedAt: date, now: date)
        check((noExtras["measurements"] as? [String: Any])?["rrp_per_min"] is NSNull, "Missing optional values are explicit JSON nulls")
        let encoded = try JSONSerialization.data(withJSONObject: current)
        let decoded = try JSONSerialization.jsonObject(with: encoded)
        check(decoded is [String: Any], "Output is valid JSON")
        if failures > 0 { exit(1) }
        print("Live export tests passed")
    }
}
