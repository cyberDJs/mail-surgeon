import Foundation

struct MailAnalyzer {
    private let factory = ConnectorFactory()

    func analyze(source: MailSourceDescriptor) async throws -> MailboxAnalysis {
        let connector = factory.makeConnector(for: source)
        try await connector.validateAccess()

        var messages: [MailMessageRecord] = []
        for try await message in connector.scanMessages() {
            messages.append(message)
        }

        let duplicateCount = Dictionary(grouping: messages, by: \.rawSHA256)
            .values
            .reduce(0) { partial, group in partial + max(0, group.count - 1) }

        let newsletters = messages.filter { message in
            message.headers.keys.contains { $0.caseInsensitiveCompare("List-Unsubscribe") == .orderedSame }
                || message.headers.keys.contains { $0.caseInsensitiveCompare("List-ID") == .orderedSame }
        }.count

        let otpTerms = ["verification code", "one-time password", "otp", "ověřovací kód"]
        let otpCount = messages.filter { message in
            otpTerms.contains { message.subject.localizedCaseInsensitiveContains($0) }
        }.count

        let sensitiveTerms = ["invoice", "faktura", "smlouva", "contract", "bank", "úřad"]
        let sensitiveCount = messages.filter { message in
            sensitiveTerms.contains { message.subject.localizedCaseInsensitiveContains($0) }
        }.count

        return MailboxAnalysis(
            totalMessages: messages.count,
            totalBytes: messages.reduce(0) { $0 + $1.byteSize },
            exactDuplicates: duplicateCount,
            likelyNewsletters: newsletters,
            likelyOneTimeCodes: otpCount,
            largeMessages: messages.filter { $0.byteSize >= 25 * 1_024 * 1_024 }.count,
            sensitiveCandidates: sensitiveCount
        )
    }
}
