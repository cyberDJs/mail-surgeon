import Foundation

struct ParsedSearchQuery: Equatable, Sendable {
  var ftsQuery: String?
  var filters: [SearchFilter]

  static let empty = ParsedSearchQuery(ftsQuery: nil, filters: [])
}

enum SearchFilter: Equatable, Sendable {
  case senderContains(String)
  case recipientContains(String)
  case hasAttachment
  case category(MessageClassificationFlags)
  case largerThanBytes(Int64)
  case before(Date)
  case after(Date)
}

enum SearchQueryError: LocalizedError, Equatable {
  case invalidFilter(String)
  case invalidDate(String)
  case invalidSize(String)

  var errorDescription: String? {
    switch self {
    case .invalidFilter(let filter):
      "Neplatný filtr: \(filter)"
    case .invalidDate(let value):
      "Neplatné datum ve filtru: \(value). Použij formát YYYY-MM-DD."
    case .invalidSize(let value):
      "Neplatná velikost ve filtru: \(value). Použij např. 10MB."
    }
  }
}

struct SearchQueryParser: Sendable {
  func parse(_ input: String, enabledFilters: Set<MessageFilter> = []) throws -> ParsedSearchQuery {
    let tokens = tokenize(input)
    guard !tokens.isEmpty || !enabledFilters.isEmpty else { return .empty }

    var ftsTerms: [String] = []
    var filters: [SearchFilter] = enabledFilters.map { .category($0.flag) }

    for token in tokens {
      if let separator = token.firstIndex(of: ":") {
        let key = token[..<separator].lowercased()
        let value = String(token[token.index(after: separator)...])
        guard !value.isEmpty else { throw SearchQueryError.invalidFilter(token) }

        switch key {
        case "from":
          filters.append(.senderContains(value))
        case "to":
          filters.append(.recipientContains(value))
        case "has":
          guard value.lowercased() == "attachment" else {
            throw SearchQueryError.invalidFilter(token)
          }
          filters.append(.hasAttachment)
        case "is":
          filters.append(.category(try categoryFlag(value, token: token)))
        case "larger":
          filters.append(.largerThanBytes(try parseSize(value)))
        case "before":
          filters.append(.before(try parseDate(value)))
        case "after":
          filters.append(.after(try parseDate(value)))
        default:
          throw SearchQueryError.invalidFilter(token)
        }
      } else {
        ftsTerms.append(token)
      }
    }

    return ParsedSearchQuery(
      ftsQuery: ftsTerms.isEmpty ? nil : ftsTerms.map(quoteFTSTerm).joined(separator: " "),
      filters: filters
    )
  }

  private func tokenize(_ input: String) -> [String] {
    input.split(whereSeparator: { $0.isWhitespace }).map(String.init)
  }

  private func quoteFTSTerm(_ term: String) -> String {
    "\"\(term.replacingOccurrences(of: "\"", with: "\"\""))\""
  }

  private func categoryFlag(_ value: String, token: String) throws -> MessageClassificationFlags {
    switch value.lowercased() {
    case "duplicate":
      .duplicate
    case "newsletter":
      .newsletter
    case "otp":
      .oneTimeCode
    case "sensitive":
      .sensitive
    default:
      throw SearchQueryError.invalidFilter(token)
    }
  }

  private func parseDate(_ value: String) throws -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    guard let date = formatter.date(from: value) else {
      throw SearchQueryError.invalidDate(value)
    }
    return date
  }

  private func parseSize(_ value: String) throws -> Int64 {
    let uppercased = value.uppercased()
    let units: [(suffix: String, multiplier: Int64)] = [
      ("GB", 1_024 * 1_024 * 1_024),
      ("MB", 1_024 * 1_024),
      ("KB", 1_024),
      ("B", 1),
    ]

    for unit in units where uppercased.hasSuffix(unit.suffix) {
      let number = uppercased.dropLast(unit.suffix.count)
      guard let value = Double(number), value >= 0 else {
        throw SearchQueryError.invalidSize(String(number))
      }
      return Int64(value * Double(unit.multiplier))
    }

    guard let bytes = Int64(value), bytes >= 0 else {
      throw SearchQueryError.invalidSize(value)
    }
    return bytes
  }
}
