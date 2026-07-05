import Foundation

enum DateParser {
    static func dateString(from text: String) -> String? {
        let pattern = #"(20\d{2}-\d{2}-\d{2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let dateRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[dateRange])
    }

    /// Tekst napisu dla klipu: nazwa pliku bez rozszerzenia i bez sufiksu spacji,
    /// np. "2026-06-05 .mov" -> "2026-06-05".
    static func captionText(for fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        return base.trimmingCharacters(in: .whitespaces)
    }
}
