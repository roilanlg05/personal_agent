import SwiftUI

/// macOS chat surface for the agent: a scrolling transcript of `model.agentLog`, an input
/// field + Send button driving `runAgentTurn`, and a Memory sheet over the inspector.
struct AgentChatView: View {
    @Bindable var model: HarnessModel
    @State private var input: String = ""
    @State private var consolidationState: MemoryClient.StateSnapshot?
    @State private var consolidationPollTask: Task<Void, Never>?
    @State private var showSettingsSheet: Bool = false

    private var serverReady: Bool {
        // Cloud chat providers have no local server to wait on — the prompt is always usable.
        if !model.chatUsesLocalServer { return true }
        if case .ready = model.serverManager.state { return true }
        return false
    }

    @ViewBuilder private var serverBanner: some View {
        if model.chatUsesLocalServer {
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
    }

    /// Consolidation status banner. Polls `MemoryClient.state()` every 2s while the view is
    /// alive: when `isRunning == true` we show "Reflexionando…"; on the trailing edge of a
    /// cycle (was running, now not) we briefly surface "Memoria consolidada" plus the new
    /// total node count so the user knows something landed. Hidden otherwise.
    @ViewBuilder private var consolidationBanner: some View {
        if let s = consolidationState, s.isRunning {
            Label("Reflexionando…", systemImage: "brain.head.profile")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
        } else if let s = consolidationState, let last = s.lastCycle, last.endedAt != nil,
                  (Date().timeIntervalSince1970 - (last.endedAt ?? 0)) < 30 {
            Label("Memoria consolidada · \(s.nodeCount) nodos",
                  systemImage: "checkmark.seal")
                .font(.caption)
                .foregroundStyle(.green)
                .padding(.vertical, 4)
                .transition(.opacity)
        }
    }

    private func startConsolidationPoll() {
        consolidationPollTask?.cancel()
        consolidationPollTask = Task { @MainActor in
            while !Task.isCancelled {
                if let client = model.memory {
                    consolidationState = try? await client.state()
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder private var apiKeyBanner: some View {
        if model.isMissingApiKey {
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .foregroundStyle(.orange)
                Text("Falta la API Key de \(model.currentProviderKind.displayName).")
                    .font(.caption)
                    .foregroundStyle(.primary)
                Spacer()
                Button("Configurar") {
                    showSettingsSheet = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(10)
            .background(Color.orange.opacity(0.15))
            .cornerRadius(8)
            .padding(.horizontal)
            .padding(.top, 4)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            apiKeyBanner
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
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 420)
        #endif
        .task { startConsolidationPoll() }
        .onDisappear { consolidationPollTask?.cancel() }
        .animation(.easeInOut(duration: 0.25), value: consolidationState?.isRunning)
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                Button { model.showMemory = true } label: {
                    Label("Memory", systemImage: "brain")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { model.consolidateNow() } label: {
                    Label("Consolidar", systemImage: "moon.zzz")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettingsSheet = true } label: {
                    Label("Settings", systemImage: "gear")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.ensureWake()
                    Task {
                        if model.wake?.state == .off { await model.wake?.enable() }
                        else { model.wake?.disable() }
                    }
                } label: {
                    let on = model.wake != nil && model.wake?.state != .off
                    Label(on ? "Escuchando" : "Hey Jarvis",
                          systemImage: on ? "ear.badge.checkmark" : "ear")
                        .foregroundStyle(on ? .green : .secondary)
                }
            }
            #else
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
                SettingsLink { Label("Settings", systemImage: "gear") }
            }
            ToolbarItem {
                Button {
                    model.ensureWake()
                    Task {
                        if model.wake?.state == .off { await model.wake?.enable() }
                        else { model.wake?.disable() }
                    }
                } label: {
                    let on = model.wake != nil && model.wake?.state != .off
                    Label(on ? "Escuchando" : "Hey Jarvis",
                          systemImage: on ? "ear.badge.checkmark" : "ear")
                        .foregroundStyle(on ? .green : .secondary)
                }
                .help("Activar/desactivar escucha continua \u{201C}Hey Jarvis\u{201D}")
            }
            #endif
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
                #if os(macOS)
                .frame(minWidth: 420, minHeight: 360)
                #endif
                .toolbar { Button("Done") { model.showMemory = false } }
            }
        }
        #if os(iOS)
        .sheet(isPresented: $showSettingsSheet) {
            NavigationStack {
                SettingsView(model: model)
                    .toolbar { Button("Done") { showSettingsSheet = false } }
            }
        }
        #endif
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

    private var voiceIcon: String {
        switch model.voice.state {
        case .idle:      return "mic"
        case .recording: return "stop.circle.fill"
        case .sending:   return "ellipsis"
        case .playing:   return "speaker.wave.2.fill"
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            Button(action: { model.voice.toggleRecording() }) {
                Image(systemName: voiceIcon)
                    .foregroundStyle(model.voice.state == .recording ? .red : .primary)
            }
            .buttonStyle(.borderless)
            .disabled(model.agentRunning || model.voice.state == .sending || model.voice.state == .playing
                      || model.wake?.state == .capturing || model.wake?.state == .busy)   // don't fight a wake turn
            .help(model.voice.state == .recording ? "Detener y enviar" : "Hablar con Gemma")

            TextField("Message Gemma…", text: $input)
                .textFieldStyle(.roundedBorder)
                .onSubmit(send)
                .disabled(model.agentRunning || !serverReady || model.voice.state != .idle)
            Button("Send", action: send)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(model.agentRunning || !serverReady || model.voice.state != .idle
                          || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
