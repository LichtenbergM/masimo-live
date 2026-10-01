import Foundation

@main struct ProtocolTests {
    static func main() throws {
        var failures = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures += 1; print("FAIL: \(message)") }
        }
        // A broader filter would connect to unrelated nearby devices.
        check(DeviceProtocol.isMasimo("MightySat 123"), "Recognizes MightySat")
        check(DeviceProtocol.isMasimo("MSat012345"), "Recognizes MSat device name")
        check(!DeviceProtocol.isMasimo("Example Headphones"), "Rejects unrelated device")
        check(!DeviceProtocol.isMasimo(""), "Rejects unnamed device")
        check(!DeviceProtocol.isMeasurementChannel(service: "180A", characteristic: "2A24"),
              "Device information is never counted as measurement traffic")
        check(DeviceProtocol.isMeasurementChannel(service: "54C21000-A720-4B4F-11E4-9FE20002A5D5",
              characteristic: "54C21002-A720-4B4F-11E4-9FE20002A5D5"), "Recognizes actual MightySat receive channel")
        check(!DeviceProtocol.isMeasurementChannel(service: "54C21000-A720-4B4F-11E4-9FE20002A5D5",
              characteristic: "54C21001-A720-4B4F-11E4-9FE20002A5D5"), "Does not classify command channel as readings")
        check(DeviceProtocol.isMeasurementChannel(service: "1822", characteristic: "2A5F"),
              "Recognizes standard measurement channel")

        // Independent fixtures: normal SpO2 = 98, pulse = 72; SFLOAT little endian.
        let normal: [UInt8] = [0, 98, 0, 72, 0]
        check(DeviceProtocol.decode(characteristic: "2A5F", bytes: normal) ==
              PLXReading(oxygen: 98, pulse: 72, continuous: true), "Decodes standard continuous measurement")
        check(DeviceProtocol.decode(characteristic: "00002A5E-0000-1000-8000-00805F9B34FB", bytes: normal) ==
              PLXReading(oxygen: 98, pulse: 72, continuous: false), "Decodes standard spot check, expanded UUID")
        check(DeviceProtocol.decode(characteristic: "12342A5F-1234-1234-1234-123456789ABC", bytes: normal) == nil,
              "Never guesses a proprietary UUID")
        check(DeviceProtocol.decode(characteristic: "2A5F", bytes: [0, 0xD4, 0xF3, 0xD0, 0xF2]) ==
              PLXReading(oxygen: 98, pulse: 72, continuous: true), "Handles signed decimal exponent")
        for length in 0..<5 {
            check(DeviceProtocol.decode(characteristic: "2A5F", bytes: Array(normal.prefix(length))) == nil,
                  "Rejects truncated mandatory fields of length \(length)")
        }
        check(DeviceProtocol.decode(characteristic: "2A5F", bytes: [1, 98, 0, 72, 0]) == nil,
              "Rejects truncated optional fast fields")
        check(DeviceProtocol.decode(characteristic: "2A5E", bytes: [1, 98, 0, 72, 0]) == nil,
              "Rejects truncated timestamp")
        // Invalid measurement status, sensor disconnected, archived data, NaN and out-of-range data.
        check(DeviceProtocol.decode(characteristic: "2A5F", bytes: [4, 98, 0, 72, 0, 0, 128]) == nil,
              "Suppresses invalid measurement")
        check(DeviceProtocol.decode(characteristic: "2A5F", bytes: [8, 98, 0, 72, 0, 0x10, 0, 0]) == nil,
              "Suppresses sensor status warning")
        check(DeviceProtocol.decode(characteristic: "2A5F", bytes: [4, 98, 0, 72, 0, 0, 2]) == nil,
              "Does not present archived measurements as live")
        check(DeviceProtocol.decode(characteristic: "2A5F", bytes: [4, 98, 0, 72, 0, 128, 0]) != nil,
              "Allows validated measurement status")
        for special: UInt16 in [0x07FE, 0x07FF, 0x0800, 0x0801, 0x0802] {
            check(DeviceProtocol.decode(characteristic: "2A5F", bytes:
                  [0, UInt8(special & 255), UInt8(special >> 8), 72, 0]) == nil, "Suppresses SFLOAT special \(special)")
        }
        check(DeviceProtocol.decode(characteristic: "2A5F", bytes: [0, 101, 0, 72, 0]) == nil,
              "Rejects impossible oxygen percentage")
        check(DeviceProtocol.decode(characteristic: "2A5F", bytes: [0, 98, 0, 0, 0]) == nil,
              "Does not present zero pulse as a valid reading")
        // All optional fields: fast/slow metrics precede status fields.
        check(DeviceProtocol.decode(characteristic: "2A5F", bytes:
              [31, 98, 0, 72, 0, 99, 0, 73, 0, 97, 0, 71, 0, 128, 0, 0, 0, 0, 10, 0]) != nil,
              "Correctly skips fast and slow metrics")
        // Independent wire fixtures from the iPhone capture: status split into 20 + 2 bytes.
        func hex(_ text: String) -> [UInt8] {
            stride(from: 0, to: text.count, by: 2).map { offset in
                let start = text.index(text.startIndex, offsetBy: offset)
                return UInt8(text[start..<text.index(start, offsetBy: 2)], radix: 16)!
            }
        }
        let status = hex("77140163101f00030100170010e6000000f600000018")
        let ack = hex("7703fe02cc")
        for split in 1..<status.count {
            var stream = MasimoFrameDecoder()
            check(stream.append(Array(status.prefix(split))).isEmpty, "Waits for complete Masimo frame at split \(split)")
            check(stream.append(Array(status.dropFirst(split))) == [MasimoFrame(bytes: status)],
                  "Reassembles captured status across split \(split)")
        }
        var joined = MasimoFrameDecoder()
        check(joined.append(status + ack) == [MasimoFrame(bytes: status), MasimoFrame(bytes: ack)],
              "Separates consecutive frames without losing acknowledgement")
        var damaged = status; damaged[8] ^= 1
        var corrupt = MasimoFrameDecoder()
        check(corrupt.append(damaged).isEmpty, "Rejects corrupted captured payload using CRC")
        check(corrupt.append(ack) == [MasimoFrame(bytes: ack)], "Recovers after corrupt frame")
        var noisy = MasimoFrameDecoder()
        check(noisy.append([0, 0x77, 0] + ack) == [MasimoFrame(bytes: ack)], "Resynchronizes after noise and invalid length")
        let service = "54C21000-A720-4B4F-11E4-9FE20002A5D5"
        let tx = "54C21001-A720-4B4F-11E4-9FE20002A5D5"
        check(MasimoProtocol.statusQuery(service: service, characteristic: tx, notifying: true, canSend: true)
              == hex("77020107"), "Emits the independently captured first query on the verified Masimo channel")
        check(MasimoProtocol.statusQuery(service: "180A", characteristic: tx, notifying: true, canSend: true) == nil,
              "Never sends proprietary query to unrelated service")
        check(MasimoProtocol.statusQuery(service: service, characteristic: service, notifying: true, canSend: true) == nil,
              "Never sends query to wrong characteristic")
        check(MasimoProtocol.statusQuery(service: service, characteristic: tx, notifying: false, canSend: true) == nil,
              "Waits for receive subscription before query")
        check(MasimoProtocol.statusQuery(service: service, characteristic: tx, notifying: true, canSend: false) == nil,
              "Does not write when peripheral has no send capacity")

        // Invented measurement values with independently encoded CRCs; no personal readings.
        let live = hex("7711050000000000620048101400260200100e")
        check(MasimoProtocol.decodeLive(MasimoFrame(bytes: live)) ==
              MasimoReading(oxygen: 98, pulse: 72, respiratoryRate: 16, pvi: 20, pi: 5.5),
              "Decodes all five independently encoded fixture values")
        let warming = hex("771105000000000062004a101600580204ff5b")
        check(MasimoProtocol.decodeLive(MasimoFrame(bytes: warming)) ==
              MasimoReading(oxygen: 98, pulse: 74, respiratoryRate: nil, pvi: 22, pi: 6),
              "Hides unavailable respiration without dropping other live values")
        let flaggedRespiration = hex("7711050000000000630046001200c201010d76")
        check(MasimoProtocol.decodeLive(MasimoFrame(bytes: flaggedRespiration)) ==
              MasimoReading(oxygen: 99, pulse: 70, respiratoryRate: nil, pvi: 18, pi: 4.5),
              "Conservatively hides respiration with an unexplained status flag")
        for unrelated in [status, ack, hex("77110493240030003c0047004d00540060009c"),
                          hex("771e0600000000000000000000000000000000000000000000000000000000e2")] {
            check(MasimoProtocol.decodeLive(MasimoFrame(bytes: unrelated)) == nil,
                  "Does not turn status, ACK, signal or archived frames into live values")
        }
        var damagedLive = live; damagedLive[8] ^= 1
        check(MasimoProtocol.decodeLive(MasimoFrame(bytes: damagedLive)) == nil,
              "Never displays a live frame with a broken checksum")
        check(MasimoProtocol.decodeLive(MasimoFrame(bytes: Array(live.prefix(10)))) == nil,
              "Rejects truncated live fields")
        // Observed finger-removal/reacquisition status patterns with invented measurement values.
        let noFinger = hex("7711050000200004ff04ff04ff0cffff04ff8c")
        let acquiring = hex("771105000000000062004a14ff20710211146c")
        let recovered = hex("771105000000000062004a10092071021014c5")
        for unavailable in [noFinger, acquiring] {
            check(MasimoProtocol.validFrame(MasimoFrame(bytes: unavailable)), "No-finger fixture has a valid wire checksum")
            check(MasimoProtocol.decodeLive(MasimoFrame(bytes: unavailable)) == nil,
                  "Hides no-finger and reacquiring status patterns")
        }
        check(MasimoProtocol.decodeLive(MasimoFrame(bytes: recovered)) ==
              MasimoReading(oxygen: 98, pulse: 74, respiratoryRate: nil, pvi: nil, pi: 6.25),
              "Recovers primary values on the next good packet while hiding unknown optional flags")
        // Independently CRC-encoded adverse inputs; changing a field must not bypass validation.
        for invalid in ["771105010000000060004d101d00a406000db7",
                        "7711050000000000600000101d00a406000d19",
                        "7711050000000000ff004d101d00a406000d4a",
                        "771105000000000060004d801d00a406000d5b"] {
            check(MasimoProtocol.decodeLive(MasimoFrame(bytes: hex(invalid))) == nil,
                  "Hides unknown status, zero pulse, invalid oxygen and unknown pulse flags")
        }
        check(MasimoProtocol.decodeLive(MasimoFrame(bytes: hex("771105000000000060004d101d00a40600ffd2")))?.respiratoryRate == nil,
              "Hides RRp sentinel even when the respiration flag is zero")
        check(MasimoProtocol.decodeLive(MasimoFrame(bytes: hex("771105000000000060004d10ffffa406000dc8")))?.pvi == nil,
              "Hides unavailable PVI independently")
        check(MasimoProtocol.decodeLive(MasimoFrame(bytes: hex("771105000000000060004d101d00ffff000d22")))?.pi == nil,
              "Hides unavailable PI independently")
        var session = MasimoLiveSession()
        check(session.nextCommand(canSend: true) == nil, "Never activates streaming without an explicit start")
        check(session.begin() == hex("77020107"), "Starts with the observed status query")
        check(session.begin() == nil, "Cannot duplicate a start within one session")
        session.receive(MasimoFrame(bytes: ack))
        check(session.nextCommand(canSend: true) == nil, "An unrelated ACK cannot authorize live activation")
        session.receive(MasimoFrame(bytes: damaged))
        check(session.nextCommand(canSend: true) == nil, "A corrupt status cannot authorize live activation")
        session.receive(MasimoFrame(bytes: status))
        check(session.nextCommand(canSend: false) == nil, "Preserves pending activation during BLE backpressure")
        check(session.nextCommand(canSend: true) == hex("7705031f0003d6"),
              "Sends exactly the successful iPhone activation after valid status")
        check(session.nextCommand(canSend: true) == nil, "Sends activation only once")
        if failures > 0 { print("\(failures) failed"); exit(1) }
        print("All protocol tests passed")
    }
}
