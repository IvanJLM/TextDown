import Foundation

/// Reads and writes text files in the encoding they came in.
enum TextEncoding {
    /// Decodes file contents. UTF-8 (with or without a byte order mark) and
    /// UTF-16 with a byte order mark are recognized directly; anything else is
    /// left to Foundation's detector, limited to the encodings text files on a
    /// Mac realistically use.
    static func decode(_ data: Data) -> (text: String, encoding: String.Encoding)? {
        if data.isEmpty { return ("", .utf8) }
        let bytes = [UInt8](data.prefix(3))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]), let text = String(data: data.dropFirst(3), encoding: .utf8) {
            return (text, .utf8)
        }
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) {
            return (text, .utf16)
        }
        if let text = String(data: data, encoding: .utf8) { return (text, .utf8) }
        var converted: NSString?
        var lossy = ObjCBool(false)
        let raw = NSString.stringEncoding(for: data, encodingOptions: [
            .suggestedEncodingsKey: [String.Encoding.windowsCP1252.rawValue, String.Encoding.isoLatin1.rawValue,
                                     String.Encoding.macOSRoman.rawValue],
            .allowLossyKey: false,
        ], convertedString: &converted, usedLossyConversion: &lossy)
        guard raw != 0, let converted else { return nil }
        return (converted as String, String.Encoding(rawValue: raw))
    }

    /// Encodes text for saving, falling back to UTF-8 when the original
    /// encoding cannot represent what was typed.
    static func encode(_ text: String, preferred: String.Encoding) -> Data {
        text.data(using: preferred) ?? Data(text.utf8)
    }
}
