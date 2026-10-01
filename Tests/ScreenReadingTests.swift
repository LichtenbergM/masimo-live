import Foundation

@main struct ScreenReadingTests {
    static func main() {
        func token(_ text: String, _ x: Double, _ y: Double, _ h: Double = 0.02, _ c: Double = 1) -> ScreenText {
            ScreenText(text: text, x: x, y: y, height: h, confidence: c)
        }
        let frame = [token("SpO₂",0.1,0.14),token("97",0.5,0.24,0.1),
                     token("PR",0.08,0.36),token("60",0.5,0.44,0.08),
                     token("RRp",0.08,0.52),token("12",0.5,0.6,0.08),
                     token("PVI",0.08,0.68),token("31",0.25,0.73,0.05),
                     token("PI",0.56,0.68),token("7.7",0.75,0.73,0.05),token("Home",0.17,0.9)]
        var checks = 0
        func check(_ ok: Bool, _ message: String) {
            checks += 1
            if !ok { print("FAIL:", message); exit(1) }
        }
        check(MasimoScreenParser.decode(frame) == ScreenReading(oxygen:97,pulse:60,respiration:12,pvi:31,pi:7.7), "observed layout assigns each value to its label")
        let observedLabel = frame.map { $0.text == "SpO₂" ? token("SpOz",0.074,0.1395,0.02035) : $0 }
        check(MasimoScreenParser.decode(observedLabel)?.oxygen == 97, "observed Vision SpOz label maps to oxygen without changing numeric tokens")
        check(MasimoScreenParser.decode(observedLabel.filter { $0.text != "97" }) == nil, "recognised label cannot supply a missing measurement")
        check(MasimoScreenParser.decode(Array(frame.reversed()))?.pulse == 60, "OCR result order is irrelevant")
        check(MasimoScreenParser.decode(frame.filter { $0.text != "Home" }) == nil, "unidentified screen is rejected")
        check(MasimoScreenParser.decode(frame.filter { $0.text != "60" }) == nil, "missing pulse clears the complete reading")
        let waiting = MasimoScreenParser.decode(frame.filter { !["12", "31", "7.7"].contains($0.text) })
        check(waiting?.oxygen == 97 && waiting?.pulse == 60, "oxygen and pulse are available while supplementary values are pending")
        check(MasimoScreenParser.decode(frame + [token("99",0.5,0.42,0.08)]) == nil, "ambiguous pulse is rejected")
        check(MasimoScreenParser.decode(frame.map { $0.text == "97" ? token("197",0.5,0.24,0.1) : $0 }) == nil, "out-of-range oxygen rejected")
        check(MasimoScreenParser.decode(frame.map { $0.text == "60" ? token("6O",0.5,0.44,0.08) : $0 }) == nil, "OCR characters are never guessed into numbers")
        check(MasimoScreenParser.decode(frame.map { $0.text == "60" ? token("60",0.5,0.44,0.08,0.4) : $0 }) == nil, "low confidence rejected")
        check(MasimoScreenParser.decode(frame.map { $0.text == "7.7" ? token("7,7",0.75,0.73,0.05) : $0 })?.pi == 7.7, "decimal comma supported")
        check(MasimoScreenParser.decode(frame + [token("PR",0.08,0.4)]) == nil, "duplicate label rejected")
        check(MasimoScreenParser.decode(frame + [token("09:41",0.15,0.03,0.03)])?.pulse == 60, "status-bar clock ignored")
        print("Screen parser: \(checks) checks passed")
    }
}
