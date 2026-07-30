import Foundation

struct RecoveryPolicy: Sendable {
  var maxDecodedExpansionRatio: Double = 25
  var scannerVersion = "recovery-v1"
  var includePrivacySensitiveReportFields = false

  func deterministicMessageID(for record: MailMessageRecord) -> String {
    let hashPrefix = String(record.rawSHA256.prefix(32))
    return "<mail-surgeon-\(hashPrefix)@recovery.local>"
  }

  func sanitizedFilename(_ filename: String) -> String {
    let lastComponent = URL(fileURLWithPath: filename).lastPathComponent
    let disallowed = CharacterSet(charactersIn: "/\\:\0")
      .union(.controlCharacters)
    let cleanedScalars = lastComponent.unicodeScalars.map { scalar in
      disallowed.contains(scalar) ? "_" : Character(scalar)
    }
    let cleaned = String(cleanedScalars).trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
      return "attachment"
    }
    return cleaned
  }

  func isUnsafeFilename(_ filename: String) -> Bool {
    filename.contains("/")
      || filename.contains("\\")
      || filename.split(separator: "/").contains("..")
      || filename == "."
      || filename == ".."
      || filename.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
  }

  func safeDefaultContentType(for rawBody: Data) -> String? {
    if String(data: rawBody.prefix(2048), encoding: .utf8) != nil {
      return "text/plain; charset=utf-8"
    }
    return nil
  }
}
