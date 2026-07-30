import Foundation

struct MailAnalyzer: Sendable {
    private let factory = ConnectorFactory()

    func analyze(
        source: MailSourceDescriptor,
        progress: (@MainActor @Sendable (AnalysisProgress) -> Void)? = nil
    ) async throws -> MailboxAnalysis {
        let connector = factory.makeConnector(for: source)
        try await connector.validateAccess()

        await progress?(AnalysisProgress(
            messagesScanned: 0,
            bytesScanned: 0,
            status: "Připravuji čtení: \(source.name)"
        ))

        var totalMessages = 0
        var totalBytes: Int64 = 0
        var exactDuplicates = 0
        var likelyNewsletters = 0
        var likelyOneTimeCodes = 0
        var largeMessages = 0
        var sensitiveCandidates = 0
        var hashes: [String: Int] = [:]

        for try await message in connector.scanMessages() {
            totalMessages += 1
            totalBytes += message.byteSize

            let existingHashCount = hashes[message.rawSHA256, default: 0]
            if existingHashCount > 0 {
                exactDuplicates += 1
            }
            hashes[message.rawSHA256] = existingHashCount + 1

            if message.headers.keys.contains(where: { $0.caseInsensitiveCompare("List-Unsubscribe") == .orderedSame })
                || message.headers.keys.contains(where: { $0.caseInsensitiveCompare("List-ID") == .orderedSame })
            {
                likelyNewsletters += 1
            }

            let otpTerms = ["verification code", "one-time password", "otp", "ověřovací kód"]
            if otpTerms.contains(where: { message.subject.localizedCaseInsensitiveContains($0) }) {
                likelyOneTimeCodes += 1
            }

            if message.byteSize >= 25 * 1_024 * 1_024 {
                largeMessages += 1
            }

            let sensitiveTerms = ["invoice", "faktura", "smlouva", "contract", "bank", "úřad"]
            if sensitiveTerms.contains(where: { message.subject.localizedCaseInsensitiveContains($0) }) {
                sensitiveCandidates += 1
            }

            await progress?(AnalysisProgress(
                messagesScanned: totalMessages,
                bytesScanned: totalBytes,
                status: "Skenuji: \(message.folderPath)"
            ))
        }

        return MailboxAnalysis(
            totalMessages: totalMessages,
            totalBytes: totalBytes,
            exactDuplicates: exactDuplicates,
            likelyNewsletters: likelyNewsletters,
            likelyOneTimeCodes: likelyOneTimeCodes,
            largeMessages: largeMessages,
            sensitiveCandidates: sensitiveCandidates
        )
    }
}
