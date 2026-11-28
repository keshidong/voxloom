import Foundation

enum QwenASRTextFormat {
    private static let digitCharacters = "0-9０-９零〇幺一二两兩三四五六七八九"
    private static let integerCharacters = digitCharacters + "十百千万萬亿億"
    private static let identifierCharacters = "A-Za-zＡ-Ｚａ-ｚ" + digitCharacters
    private static let wholeIdentifier = try! NSRegularExpression(
        pattern: "\\A\\s*([\(identifierCharacters)\\h]+?)\\s*[。．.!?！？]?\\s*\\z")
    private static let labeledIdentifier = try! NSRegularExpression(
        pattern: "(?:编号|验证码|序列号|邀请码|订单号|识别码)\\h*(?:是|为)?\\h*[:：]?\\h*([\(identifierCharacters)\\h]+)")
    private static let decimal = try! NSRegularExpression(
        pattern: "(?<![A-Za-z\(integerCharacters)点點.．])([\(integerCharacters)]+)\\h*([点點.．])\\h*([\(digitCharacters)](?:\\h*[\(digitCharacters)])*)(?!\\h*[\(digitCharacters)点點]|[.．][\(integerCharacters)])(?:\\h+(?=\\p{Han}))?")
    private static let timeOfDay = ["上午", "下午", "早上", "中午", "傍晚", "晚上", "凌晨", "清晨"]
    private static let ambiguousSpokenSuffix =
        "^(?:刻|十|[百千万萬亿億](?=\\h*[\(integerCharacters)])|分(?!贝|貝|钟|鐘|米|升|克))"
    private static let chineseDigits: [Character: Character] = {
        var result = Dictionary(uniqueKeysWithValues: zip("零一二三四五六七八九", "0123456789"))
        result["〇"] = "0"
        result["幺"] = "1"
        result["两"] = "2"
        result["兩"] = "2"
        return result
    }()

    static func normalized(_ text: String) -> String {
        let source = text as NSString
        let full = NSRange(location: 0, length: source.length)
        if let match = wholeIdentifier.firstMatch(in: text, range: full),
           let formatted = identifier(source.substring(with: match.range(at: 1)), hasLabel: false) {
            return formatted
        }
        let identifiers = replacingMatches(of: labeledIdentifier, in: text, replacingGroup: 1) { match, source in
            identifier(source.substring(with: match.range(at: 1)), hasLabel: true)
        }
        return replacingMatches(of: decimal, in: identifiers, replacingGroup: 0) { match, source in
            guard let whole = integer(source.substring(with: match.range(at: 1))),
                  let fraction = digits(source.substring(with: match.range(at: 3))) else { return nil }
            let separator = source.substring(with: match.range(at: 2))
            if separator == "点" || separator == "點" {
                let before = source.substring(to: match.range.location).trimmingCharacters(in: .whitespaces)
                let after = source.substring(from: NSMaxRange(match.range)).trimmingCharacters(in: .whitespaces)
                guard !timeOfDay.contains(where: before.hasSuffix),
                      after.range(of: ambiguousSpokenSuffix, options: .regularExpression) == nil,
                      !(whole == "1" && fraction == "1" && after.hasPrefix("滴")) else { return nil }
            }
            return whole + "." + fraction
        }
    }

    private static func identifier(_ text: String, hasLabel: Bool) -> String? {
        let normalized = text.folding(options: .widthInsensitive, locale: nil)
        let words = normalized.split(whereSeparator: \.isWhitespace)
        let compact = words.joined()
        guard let first = compact.first, let last = compact.last else { return nil }
        if !hasLabel {
            let hasLetters = compact.contains { $0.isASCII && $0.isLetter }
            let hasDigits = compact.contains { digit($0) != nil }
            let isSpelled = words.allSatisfy { word in word.count == 1 || word.contains { digit($0) != nil } }
            let boundedByDigits = digit(first) != nil && digit(last) != nil
            guard hasLetters, hasDigits, isSpelled, words.count > 1 || boundedByDigits else { return nil }
        }
        return compact.map { character in
            digit(character).map(String.init) ?? character.lowercased()
        }.joined()
    }

    private static func digit(_ character: Character) -> Character? {
        if character.isASCII && character.isNumber { return character }
        return chineseDigits[character]
    }

    private static func digits(_ text: String) -> String? {
        let characters = text.folding(options: .widthInsensitive, locale: nil).filter { !$0.isWhitespace }
        let translated = characters.compactMap(digit)
        guard !translated.isEmpty, translated.count == characters.count else { return nil }
        return String(translated)
    }

    private static func integer(_ text: String) -> String? {
        if let direct = digits(text) { return direct }
        let canonical = text.replacingOccurrences(of: "两", with: "二")
            .replacingOccurrences(of: "兩", with: "二")
            .replacingOccurrences(of: "〇", with: "零")
            .replacingOccurrences(of: "萬", with: "万")
            .replacingOccurrences(of: "億", with: "亿")
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.numberStyle = .spellOut
        formatter.isLenient = false
        // A round trip rejects colloquial whole parts such as 一百二.
        guard let value = formatter.number(from: canonical), formatter.string(from: value) == canonical,
              value.stringValue.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return value.stringValue
    }

    private static func replacingMatches(
        of pattern: NSRegularExpression, in text: String, replacingGroup group: Int,
        with replacement: (NSTextCheckingResult, NSString) -> String?
    ) -> String {
        let source = text as NSString
        let range = NSRange(location: 0, length: source.length)
        let output = NSMutableString(string: text)
        for match in pattern.matches(in: text, range: range).reversed() {
            if let value = replacement(match, source) {
                output.replaceCharacters(in: match.range(at: group), with: value)
            }
        }
        return output as String
    }
}
