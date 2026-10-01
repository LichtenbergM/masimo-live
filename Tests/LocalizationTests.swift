import Foundation

@main struct LocalizationTests {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let arguments = CommandLine.arguments
        func option(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        let app = option("--app-bundle").flatMap { Bundle(path: $0) }
        let resources = app?.resourceURL ?? root.appendingPathComponent("Resources")
        func check(_ condition: Bool, _ message: String) {
            if !condition { print("FAIL: \(message)"); exit(1) }
        }
        check(option("--app-bundle") == nil || app != nil, "Requested app bundle must exist")
        func matches(_ pattern: String, in text: String) throws -> [String] {
            let regex = try NSRegularExpression(pattern: pattern)
            let text = text as NSString
            return regex.matches(in: text as String, range: NSRange(location: 0, length: text.length))
                .map { text.substring(with: $0.range) }
        }
        var tables: [String: [String: String]] = [:]
        for language in ["en", "de"] {
            let directory = resources.appendingPathComponent("\(language).lproj")
            let url = directory.appendingPathComponent("Localizable.strings")
            guard FileManager.default.fileExists(atPath: url.path) else {
                print("FAIL: Missing \(language) interface translations")
                exit(1)
            }
            let data = try Data(contentsOf: url)
            tables[language] = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        }
        guard let english = tables["en"], let german = tables["de"],
              !english.isEmpty, Set(english.keys) == Set(german.keys) else {
            print("FAIL: English and German must cover the same interface messages")
            exit(1)
        }
        for key in english.keys {
            check(!english[key]!.isEmpty && !german[key]!.isEmpty, "Empty translation: \(key)")
            check(try matches(#"%(?:\d+\$)?(?:@|ld|d)"#, in: english[key]!) ==
                  matches(#"%(?:\d+\$)?(?:@|ld|d)"#, in: german[key]!), "Format arguments must agree: \(key)")
        }
        for (language, expected) in [("en", "Connect"), ("de", "Verbinden")] {
            let bundle = Bundle(path: resources.appendingPathComponent("\(language).lproj").path)!
            check(L10n.text("Connect", bundle: bundle) == expected, "Translate Connect in \(language)")
            check(L10n.text("Untranslated message", bundle: bundle) == "Untranslated message", "Keep English fallback for missing keys")
            let counter = L10n.format("Screen checks: %ld", 12, bundle: bundle)
            check(counter == (language == "en" ? "Screen checks: 12" : "Bildschirmprüfungen: 12"), "Format localized counts")
            let error = L10n.format("Recording failed: %@", "100% unavailable", bundle: bundle)
            check(error == (language == "en" ? "Recording failed: 100% unavailable" : "Aufzeichnung fehlgeschlagen: 100% unavailable"), "Preserve error text without interpreting percent signs")
            let setup = L10n.format("Could not prepare USB screen access (%d).", Int32(-50), bundle: bundle)
            check(setup.contains("(-50)"), "Preserve signed OS error codes")
            let permissions = try Data(contentsOf: resources.appendingPathComponent("\(language).lproj/InfoPlist.strings"))
            let prompts = try PropertyListSerialization.propertyList(from: permissions, format: nil) as! [String: String]
            for key in ["NSBluetoothAlwaysUsageDescription", "NSBluetoothPeripheralUsageDescription", "NSCameraUsageDescription"] {
                check(prompts[key]?.isEmpty == false, "Translate permission prompt \(key) in \(language)")
            }
        }
        if let app = app, let expected = option("--expect-language") {
            check(app.preferredLocalizations.first == expected, "App must select \(expected) from macOS preferences")
            check(L10n.text("Connect", bundle: app) == (expected == "de" ? "Verbinden" : "Connect"), "Packaged app must use the selected language")
            let prompt = app.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") as? String
            check(prompt?.hasPrefix(expected == "de" ? "Masimo Live verbindet" : "Masimo Live connects") == true, "Permission prompts must use the selected language")
        }
        if app == nil {
            let regex = try NSRegularExpression(pattern: #"L10n\.(?:text|format)\("([^"]+)""#)
            for filename in ["Sources/App.swift", "Sources/USBReader.swift"] {
                let source = try String(contentsOf: root.appendingPathComponent(filename), encoding: .utf8) as NSString
                for match in regex.matches(in: source as String, range: NSRange(location: 0, length: source.length)) {
                    let key = source.substring(with: match.range(at: 1))
                    check(english[key] != nil && german[key] != nil, "Translate every interface message: \(key)")
                }
            }
        }
        print("Localization: \(english.count) English/German messages, formatting, and permission checks passed")
    }
}
