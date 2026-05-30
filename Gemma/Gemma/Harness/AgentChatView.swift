import SwiftUI

/// macOS chat surface for the agent: a scrolling transcript of `model.agentLog`, an input
/// field + Send button driving `runAgentTurn`, and a Memory sheet over the inspector.
struct AgentChatView: View {
    @Bindable var model: HarnessModel
    @State private var input: String = ""

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            inputBar
        }
        .frame(minWidth: 560, minHeight: 420)
        .toolbar {
            ToolbarItem {
                Button { model.showMemory = true } label: {
                    Label("Memory", systemImage: "brain")
                }
            }
        }
        .sheet(isPresented: $model.showMemory) {
            NavigationStack {
                Group {
                    if model.inspectorStore() != nil {
                        MemoryInspectorView(store: model.inspectorStore())
                    } else {
                        ContentUnavailableView("No memory store", systemImage: "brain",
                                               description: Text("Memory is disabled or not yet initialized. Send a message with memory enabled, then reopen."))
                    }
                }
                .frame(minWidth: 420, minHeight: 360)
                .toolbar { Button("Done") { model.showMemory = false } }
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(model.agentLog.enumerated()), id: \.offset) { idx, line in
                        Text(line)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(idx)
                    }
                }
                .padding()
            }
            .onChange(of: model.agentLog.count) { _, newCount in
                if newCount > 0 { withAnimation { proxy.scrollTo(newCount - 1, anchor: .bottom) } }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Message Gemma…", text: $input)
                .textFieldStyle(.roundedBorder)
                .onSubmit(send)
                .disabled(model.agentRunning)
            Button("Send", action: send)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(model.agentRunning || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !model.agentRunning else { return }
        input = ""
        Task { await model.runAgentTurn(text) }
    }
}
