import KeepoCore
import SwiftUI

/// One visible, editable assumption set — never a hidden constant (spec).
/// Reached from Insights, where the numbers these assumptions drive are
/// actually shown.
struct FISettingsView: View {
    let session: SessionStore
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var hasTarget = false
    @State private var targetAnnualSpendText = ""
    @State private var withdrawalRateText = ""
    @State private var realReturnRateText = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if isLoading {
                    ProgressView()
                } else {
                    Section {
                        Toggle("Set a target annual spend", isOn: $hasTarget)
                        if hasTarget {
                            TextField("0.00", text: $targetAnnualSpendText)
                                .keyboardType(.decimalPad)
                        }
                    } footer: {
                        Text("Off derives it automatically from your trailing 12 months of expenses.")
                    }

                    Section("Withdrawal rate") {
                        TextField("0.04", text: $withdrawalRateText)
                            .keyboardType(.decimalPad)
                    }

                    Section("Real return rate") {
                        TextField("0.05", text: $realReturnRateText)
                            .keyboardType(.decimalPad)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("FI Assumptions")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(isLoading || isSaving)
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        if let settings = try? await FIRepository.fetchSettings(client: session.client) {
            hasTarget = settings.targetAnnualSpend != nil
            targetAnnualSpendText = settings.targetAnnualSpend
                .map { AmountFormatter.editableString($0, minorUnit: 2) } ?? ""
            withdrawalRateText = "\(settings.withdrawalRate)"
            realReturnRateText = "\(settings.realReturnRate)"
        }
        isLoading = false
    }

    private func save() async {
        guard let withdrawalRate = AmountParser.parse(withdrawalRateText),
              let realReturnRate = AmountParser.parse(realReturnRateText) else {
            errorMessage = "Enter valid rates."
            return
        }
        let targetAnnualSpend = hasTarget ? AmountParser.parse(targetAnnualSpendText) : nil

        isSaving = true
        errorMessage = nil
        do {
            try await FIRepository.updateSettings(
                client: session.client, targetAnnualSpend: targetAnnualSpend,
                withdrawalRate: withdrawalRate, realReturnRate: realReturnRate
            )
            onSaved()
            dismiss()
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isSaving = false
    }
}
