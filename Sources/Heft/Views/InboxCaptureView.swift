import SwiftUI

struct InboxCaptureView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var capture = ""
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    private var trimmedCapture: String {
        capture.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Capture to Inbox")
                    .font(.title2.weight(.semibold))
                Text("Adds a timestamped item to \(model.vaultName) / Inbox.md")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $capture)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(5)
                    .focused($isFocused)
                if capture.isEmpty {
                    Text("What do you want to remember?")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 110)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(.separator, lineWidth: 1)
            }

            HStack {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else {
                    Text("Newest captures appear first, grouped by date.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add to Inbox", action: submit)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(trimmedCapture.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 520)
        .onAppear { isFocused = true }
    }

    private func submit() {
        guard !trimmedCapture.isEmpty else { return }
        if model.captureToInbox(capture) {
            dismiss()
        } else {
            errorMessage = model.status
        }
    }
}
