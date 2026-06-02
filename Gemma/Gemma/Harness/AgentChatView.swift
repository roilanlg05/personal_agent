import SwiftUI

/// macOS chat surface for the agent: a scrolling transcript of `model.agentLog`, an input
/// field + Send button driving `runAgentTurn`, and a Memory sheet over the inspector.
struct AgentChatView: View {
    @Bindable var model: HarnessModel
    @State private var input: String = ""

    private var serverReady: Bool {
        if case .ready = model.serverManager.state { return true }
        return false
    }

    @ViewBuilder private var serverBanner: some View {
        switch model.serverManager.state {
        case .idle, .starting:
            Label("Iniciando server…", systemImage: "hourglass").foregroundStyle(.secondary)
        case .loadingModel:
            Label("Cargando modelo…", systemImage: "shippingbox").foregroundStyle(.secondary)
        case .ready:
            Label("Listo", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .stopped:
            HStack(spacing: 8) {
                Label("Detenido", systemImage: "stop.circle").foregroundStyle(.secondary)
                Button("Reintentar") { model.startServer() }
            }
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 4) {
                Label("Error del server", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(reason).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text(model.serverManager.manualCommand).font(.caption.monospaced())
                    .textSelection(.enabled).foregroundStyle(.secondary)
                Button("Reintentar") { model.startServer() }
            }
        }
    }

    /// Consolidation status banner. In M3a the scheduler lives inside the Memory Service
    /// (Docker) — the harness no longer drives it. A future follow-up can poll
    /// `MemoryClient.state()` here to surface progress; for now the banner is silent.
    /// TODO(m3a-follow-up): poll `client.state()` and render lastCycle.status / isRunning.
    @ViewBuilder private var consolidationBanner: some View {
        EmptyView()
    }

    var body: some View {
        VStack(spacing: 0) {
            serverBanner
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal).padding(.top, 8)
            consolidationBanner
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            transcript
            Divider()
            inputBar
        }
        .frame(minWidth: 560, minHeight: 420)
        .toolbar {
            ToolbarItem {
                Button { model.consolidateNow() } label: {
                    Label("Consolidar", systemImage: "moon.zzz")
                }
            }
            ToolbarItem {
                Button { model.showMemory = true } label: {
                    Label("Memory", systemImage: "brain")
                }
            }
            ToolbarItem {
                // In-window shortcut to the Settings scene (also at ⌘, / Gemma → Settings…).
                SettingsLink { Label("Settings", systemImage: "gear") }
            }
        }
        .sheet(isPresented: $model.showMemory) {
            NavigationStack {
                Group {
                    if let client = model.memoryClient() {
                        MemoryView(client: client)
                    } else {
                        ContentUnavailableView("No memory client", systemImage: "brain",
                                               description: Text("Memory is disabled or not yet initialized. Send a message with memory enabled, then reopen."))
                    }
                }
                .frame(minWidth: 420, minHeight: 360)
                .toolbar { Button("Done") { model.showMemory = false } }
            }
        }
        .task { model.ensureMemory() }
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
                .disabled(model.agentRunning || !serverReady)
            Button("Send", action: send)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(model.agentRunning || !serverReady || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !model.agentRunning, serverReady else { return }
        input = ""
        Task { await model.runAgentTurn(text) }
    }
}
