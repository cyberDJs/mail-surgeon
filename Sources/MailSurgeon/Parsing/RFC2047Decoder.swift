import Foundation

struct RFC2047Decoder: Sendable {
  func decode(_ value: String) -> String {
    let pattern = #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return value
    }

    let nsValue = value as NSString
    let fullRange = NSRange(location: 0, length: nsValue.length)
    let matches = regex.matches(in: value, range: fullRange)
    guard !matches.isEmpty else { return value }

    var decoded = ""
    var cursor = 0
    var previousWasEncodedWord = false

    for match in matches {
      let gapRange = NSRange(location: cursor, length: match.range.location - cursor)
      let gap = nsValue.substring(with: gapRange)
      let charset = nsValue.substring(with: match.range(at: 1))
      let encoding = nsValue.substring(with: match.range(at: 2))
      let encodedText = nsValue.substring(with: match.range(at: 3))

      guard
        let replacement = decodeWord(
          charset: charset,
          encoding: encoding,
          encodedText: encodedText
        )
      else {
        decoded += gap + nsValue.substring(with: match.range)
        cursor = match.range.location + match.range.length
        previousWasEncodedWord = false
        continue
      }

      if !(previousWasEncodedWord && gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
        decoded += gap
      }
      decoded += replacement
      cursor = match.range.location + match.range.length
      previousWasEncodedWord = true
    }

    decoded += nsValue.substring(from: cursor)
    return decoded
  }

  private func decodeWord(charset: String, encoding: String, encodedText: String) -> String? {
    let data: Data?
    switch encoding.lowercased() {
    case "b":
      data = Data(base64Encoded: encodedText)
    case "q":
      data = decodeQuotedPrintable(encodedText)
    default:
      data = nil
    }

    guard let data else { return nil }
    switch charset.lowercased() {
    case "utf-8", "utf8":
      return String(data: data, encoding: .utf8)
    case "iso-8859-1", "latin1", "latin-1":
      return String(data: data, encoding: .isoLatin1)
    default:
      return nil
    }
  }

  private func decodeQuotedPrintable(_ value: String) -> Data {
    var output = Data()
    let bytes = Array(value.utf8)
    var index = 0

    while index < bytes.count {
      let byte = bytes[index]
      if byte == 0x5F {
        output.append(0x20)
        index += 1
        continue
      }

      if byte == 0x3D, index + 2 < bytes.count,
        let high = hexValue(bytes[index + 1]),
        let low = hexValue(bytes[index + 2])
      {
        output.append(high << 4 | low)
        index += 3
        continue
      }

      output.append(byte)
      index += 1
    }

    return output
  }

  private func hexValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 48...57:
      byte - 48
    case 65...70:
      byte - 55
    case 97...102:
      byte - 87
    default:
      nil
    }
  }
}
