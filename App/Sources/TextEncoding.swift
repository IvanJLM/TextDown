import Foundation

/// Reads and writes text files in the encoding they came in.
enum TextEncoding {
    /// How a file was written: its encoding, and whether it starts with a
    /// byte order mark. Both are kept when it is saved.
    struct Format: Equatable {
        var encoding: String.Encoding
        var byteOrderMark = false
    }

    /// Decodes file contents. UTF-8 (with or without a byte order mark) and
    /// UTF-16 with a byte order mark are recognized directly; anything else is
    /// left to Foundation's detector, limited to the encodings text files on a
    /// Mac realistically use.
    static func decode(_ data: Data) -> (text: String, format: Format)? {
        if data.isEmpty { return ("", Format(encoding: .utf8)) }
        let bytes = [UInt8](data.prefix(3))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]), let text = String(data: data.dropFirst(3), encoding: .utf8) {
            return (text, Format(encoding: .utf8, byteOrderMark: true))
        }
        if bytes.starts(with: [0xFF, 0xFE]), let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
            return (text, Format(encoding: .utf16LittleEndian, byteOrderMark: true))
        }
        if bytes.starts(with: [0xFE, 0xFF]), let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
            return (text, Format(encoding: .utf16BigEndian, byteOrderMark: true))
        }
        if let text = String(data: data, encoding: .utf8) { return (text, Format(encoding: .utf8)) }
        var converted: NSString?
        var lossy = ObjCBool(false)
        let raw = NSString.stringEncoding(for: data, encodingOptions: [
            .suggestedEncodingsKey: [String.Encoding.windowsCP1252.rawValue, String.Encoding.isoLatin1.rawValue,
                                     String.Encoding.macOSRoman.rawValue],
            .allowLossyKey: false,
        ], convertedString: &converted, usedLossyConversion: &lossy)
        guard raw != 0, let converted else { return nil }
        return (converted as String, Format(encoding: String.Encoding(rawValue: raw)))
    }

    /// Encodes text for saving in the file's own format, falling back to
    /// UTF-8 when its encoding cannot represent what was typed.
    static func encode(_ text: String, as format: Format) -> Data {
        guard let body = text.data(using: format.encoding) else { return Data(text.utf8) }
        guard format.byteOrderMark else { return body }
        switch format.encoding {
        case .utf8: return Data([0xEF, 0xBB, 0xBF]) + body
        case .utf16LittleEndian: return Data([0xFF, 0xFE]) + body
        case .utf16BigEndian: return Data([0xFE, 0xFF]) + body
        default: return body
        }
    }
}
