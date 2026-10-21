import Foundation

public enum ApplicationSearch {
    /// All query words must occur in the name, bundle ID, or a name transliteration.
    /// Filtering deliberately preserves discovery order and never merges sources.
    public static func filter(_ apps: [AudioApplication], query: String) -> [AudioApplication] {
        let words = normalized(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return apps }
        return apps.filter { application in
            let fields = searchFields(for: application)
            return words.allSatisfy { word in fields.contains { $0.contains(word) } }
        }
    }

    private static func searchFields(for application: AudioApplication) -> [String] {
        let name = normalized(application.name)
        var fields = [name, normalized(application.bundleID ?? "")]
        let latinWords = Set(name.components(separatedBy: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").inverted).filter { !$0.isEmpty })
        var transliterationInputs = [application.name]
        // ICU's Mandarin transform reads the polyphonic 乐 as "le", including in
        // 音乐. Keep that system spelling, and add the usual media-app reading.
        let musicReading = application.name
            .replacingOccurrences(of: "音乐", with: "音 yuè ")
            .replacingOccurrences(of: "音樂", with: "音 yuè ")
        if musicReading != application.name { transliterationInputs.append(musicReading) }

        for input in transliterationInputs {
            let latin = normalized(input.applyingTransform(.mandarinToLatin, reverse: false) ?? input)
            let syllables = latin.split(whereSeparator: \.isWhitespace).map(String.init)
            fields.append(latin)
            fields.append(syllables.joined())
            fields.append(syllables.compactMap(\.first).map(String.init).joined())
            // Preserve existing Latin words in mixed names: QQ音乐 -> qqyy.
            fields.append(syllables.map { latinWords.contains($0) ? $0 : String($0.prefix(1)) }.joined())
        }
        return fields
    }

    private static func normalized(_ value: String) -> String {
        let unaccented = value.applyingTransform(.stripDiacritics, reverse: false) ?? value
        return unaccented.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
