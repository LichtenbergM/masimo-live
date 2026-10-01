import Foundation

struct ScreenText {
    let text: String
    let x: Double
    let y: Double
    let height: Double
    let confidence: Double
}

struct ScreenReading: Equatable {
    let oxygen: Double
    let pulse: Double
    let respiration: Double?
    let pvi: Double?
    let pi: Double?
}

enum MasimoScreenParser {
    static func decode(_ texts: [ScreenText]) -> ScreenReading? {
        func label(_ names: [String]) -> ScreenText? {
            let matches = texts.filter {
                names.contains($0.text.uppercased().replacingOccurrences(of: "₂", with: "2")
                    .filter { !$0.isWhitespace }) && $0.confidence >= 0.7
            }
            return matches.count == 1 ? matches[0] : nil
        }
        // Vision sometimes reads the subscript 2 in this app's SpO₂ label as z.
        // Accept that observed label only; numeric OCR tokens remain strict.
        guard let oxygen = label(["SPO2", "SPO2%", "SPOZ"]), let pulse = label(["PR", "PRBPM"]),
              let respiration = label(["RRP", "RRPRPM"]), let pvi = label(["PVI"]), let pi = label(["PI"]),
              oxygen.y < pulse.y, pulse.y < respiration.y, respiration.y < pvi.y,
              abs(pvi.y - pi.y) < 0.05, pvi.x < 0.5, pi.x > 0.5,
              texts.contains(where: { $0.text.lowercased() == "home" }) else { return nil }
        func value(after anchor: ScreenText, before bottom: Double, half: Int? = nil) -> Double? {
            let matches = texts.filter {
                $0.y > anchor.y && $0.y < bottom && $0.height >= 0.03 && $0.confidence >= 0.7 &&
                (half == nil || (half == 0 ? $0.x < 0.5 : $0.x > 0.5)) &&
                $0.text.range(of: "^[0-9]+([.,][0-9]+)?$", options: .regularExpression) != nil
            }
            guard matches.count == 1 else { return nil }
            return Double(matches[0].text.replacingOccurrences(of: ",", with: "."))
        }
        guard let o = value(after: oxygen, before: pulse.y), let p = value(after: pulse, before: respiration.y),
              (0...100).contains(o), (1...400).contains(p) else { return nil }
        func bounded(_ number: Double?, _ range: ClosedRange<Double>) -> Double? {
            guard let number = number, range.contains(number) else { return nil }
            return number
        }
        let r = bounded(value(after: respiration, before: pvi.y), 1...100)
        let v = bounded(value(after: pvi, before: min(pvi.y + 0.15, 1), half: 0), 0...100)
        let i = bounded(value(after: pi, before: min(pi.y + 0.15, 1), half: 1), 0...100)
        return ScreenReading(oxygen: o, pulse: p, respiration: r, pvi: v, pi: i)
    }
}
