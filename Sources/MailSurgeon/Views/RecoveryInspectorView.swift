import SwiftUI

struct RecoveryInspectorView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Inspektor nálezu")
        .font(.headline)
        .padding([.horizontal, .top], 14)
      Divider()
      content
    }
  }

  @ViewBuilder
  private var content: some View {
    if let issue = model.selectedRecoveryIssue {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          DetailSectionView(
            title: "Klasifikace",
            rows: [
              "ID": issue.id,
              "Typ": issue.kind.label,
              "Akce": issue.suggestedAction.rawValue,
              "Opravitelné": issue.isSafelyRepairable ? "Ano" : "Ne",
            ]
          )
          DetailSectionView(
            title: "Závažnost a jistota",
            rows: [
              "Závažnost": issue.severity.czechLabel,
              "Jistota": issue.confidence.czechLabel,
            ]
          )
          DetailSectionView(
            title: "Technické vysvětlení",
            rows: [
              "Název": issue.title,
              "Detail": issue.technicalExplanation,
            ]
          )
          DetailSectionView(title: "Evidence", rows: issue.evidence)
          DetailSectionView(
            title: "Byte rozsah",
            rows: [
              "Offset": issue.byteOffset.map(String.init) ?? "-",
              "Délka": issue.byteLength.map(String.init) ?? "-",
            ]
          )
          if let suggestion = model.selectedRecoverySuggestion {
            DetailSectionView(
              title: "Navržená oprava",
              rows: [
                "Akce": suggestion.action.rawValue,
                "Původní stav": suggestion.originalCondition,
                "Změna": suggestion.proposedChange,
                "Jistota": suggestion.confidence.czechLabel,
                "Mění raw bytes": suggestion.changesRawBytes ? "Ano" : "Ne",
                "Jen metadata": suggestion.metadataOnly ? "Ano" : "Ne",
                "Vyžaduje potvrzení": suggestion.requiresUserConfirmation ? "Ano" : "Ne",
              ]
            )
          }
        }
        .padding(14)
        .textSelection(.enabled)
      }
    } else {
      ContentUnavailableView(
        "Není vybraný nález",
        systemImage: "list.bullet.rectangle",
        description: Text("Detail se zobrazí po výběru recovery nálezu.")
      )
    }
  }
}
