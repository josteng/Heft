import HeftCore
import SwiftUI

/// The Ask pane: whether the search bar offers Ask, and which agent it runs.
///
/// A tab of its own rather than a section of Search: off by default, a
/// switch at the bottom of another pane was where nobody would find it.
/// Experimental, as Vim is, and plain about whose plan it runs on and what
/// keeps it in check.
struct AskSettingsView: View {
    @ObservedObject private var settings = GeneralSettings.shared
    /// Where the agent command was found, looked up off the main thread:
    /// failing the usual places, it asks a login shell.
    @State private var agentStatus = " "
    @State private var showsDetails = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.asksAgent) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text("Ask about your notes")
                            ExperimentalBadge()
                            // The rest of what it is and what keeps it in
                            // check, a click away, so the pane is not a page.
                            // A tooltip inside a toggle's label never showed.
                            Button { showsDetails.toggle() } label: {
                                Image(systemName: "info.circle")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("What Ask is, and what keeps it in check")
                            .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
                                Text(Self.details)
                                    .font(.callout)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(width: 320)
                                    .padding(14)
                            }
                        }
                        Text("In the search bar (⌘6, or ? in ⌘T) and the right sidebar. "
                            + "Runs your own Claude Code, on your Claude plan.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Section {
                LabeledContent {
                    TextField("", text: $settings.agentCommand, prompt: Text(GeneralSettings.standardAgentCommand))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                } label: {
                    SettingLabel("Agent", detail: agentStatus)
                }
                .task(id: settings.agentCommand) {
                    let typed = settings.agentCommand.trimmingCharacters(in: .whitespaces)
                    let command = typed.isEmpty ? GeneralSettings.standardAgentCommand : typed
                    let found = await Task.detached { AgentLocator.find(command: command) }.value
                    agentStatus = found.map { $0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
                        ?? "Not found. Install Claude Code, or name the command's full path."
                }
                Picker(selection: $settings.agentModel) {
                    ForEach(Self.models, id: \.self) { Text($0.capitalized).tag($0) }
                    if !Self.models.contains(settings.agentModel) {
                        Text(settings.agentModel).tag(settings.agentModel)
                    }
                } label: {
                    SettingLabel("Model", detail: "Haiku answers in seconds; the others think longer and use more of your plan.")
                }
                .defaultMenuTint()
                let unavailable = OnDeviceModel.unavailableReason
                Toggle(isOn: Binding(
                    get: { settings.namesChats && unavailable == nil },
                    set: { settings.namesChats = $0 }
                )) {
                    SettingLabel(
                        "Name chats with Apple Intelligence",
                        detail: (unavailable.map { $0 + " Until then a chat is named by its first question." })
                            ?? "After the first answer, on this Mac. Off, a chat is named by its first "
                            + "question. Right-click a chat to rename it."
                    )
                }
                .disabled(unavailable != nil)
                Toggle(isOn: $settings.suggestsQuestions) {
                    SettingLabel(
                        "Suggest questions",
                        detail: "A new chat in the right sidebar offers a few things to ask about the note "
                            + "that is open. They go once you ask."
                    )
                }
                Picker(selection: $settings.askFirst) {
                    ForEach(GeneralSettings.AskFirst.allCases) { Text($0.title).tag($0) }
                } label: {
                    SettingLabel(
                        "Put Ask first in ⌘T",
                        detail: "So Return asks rather than searches. A question is text ending in ?, starting "
                            + "with a word like what, how or summarise, or a whole sentence; a note whose "
                            + "name starts with it still comes first."
                    )
                }
                .defaultMenuTint()
            }
            .disabled(!settings.asksAgent)
        }
        .formStyle(.grouped)
    }

    private static let models = ["haiku", "sonnet", "opus"]

    private static let details = """
        Changes it wants are proposed in the chat, for you to accept or reject.

        It runs your own Claude Code, signed in with your own account, so its use counts against \
        your Claude plan. Heft never sees your login.

        Each run may read only the focused folder, or the whole vault, and may only propose \
        changes. Those limits are Claude Code's permission rules, which Heft sets for every run; \
        they are not a separate sandbox.

        Separate from agent access: an agent you run yourself can use the heft command whether \
        Ask is on or off. File ▸ Set Up Agent Access teaches it how.
        """
}

/// The mark on a setting that is still finding its shape, as Vim and Ask are.
struct ExperimentalBadge: View {
    var body: some View {
        Text("EXPERIMENTAL")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.orange.opacity(0.12), in: .capsule)
    }
}
