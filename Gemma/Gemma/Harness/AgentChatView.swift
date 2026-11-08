import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

struct ChatAttachment: Identifiable {
    let id = UUID()
    let name: String
    let iconName: String
    let image: PlatformImage?
    let textContent: String?
}

/// macOS chat surface for the agent: a scrolling transcript of `model.agentLog`, an input
/// field + Send button driving `runAgentTurn`, and a Memory sheet over the inspector.
struct AgentChatView: View {
    @Bindable var model: HarnessModel
    @State private var input: String = ""
    @State private var attachments: [ChatAttachment] = []
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showFilePicker: Bool = false
    @State private var dictationManager = SpeechDictationManager()
    @State private var consolidationState: MemoryClient.StateSnapshot?
    @State private var consolidationPollTask: Task<Void, Never>?
    @State private var showSettingsSheet: Bool = false
    @State private var showOnDeviceModelPicker: Bool = false
    @State private var onDeviceImportError: String?

    #if os(iOS)
    private var inputBackground: Color { Color(uiColor: .secondarySystemBackground) }
    private var buttonFillBackground: Color { Color(uiColor: .secondarySystemFill) }
    private var tertiaryBackground: Color { Color(uiColor: .tertiarySystemFill) }
    private var barBackground: Color { Color(uiColor: .systemBackground) }
    #else
    private var inputBackground: Color { Color(nsColor: .controlBackgroundColor) }
    private var buttonFillBackground: Color { Color.secondary.opacity(0.15) }
    private var tertiaryBackground: Color { Color.secondary.opacity(0.1) }
    private var barBackground: Color { Color(nsColor: .windowBackgroundColor) }
    #endif

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

    @State private var isApiKeyBannerDismissed: Bool = false

    @ViewBuilder private var apiKeyBanner: some View {
        if model.isMissingApiKey && !isApiKeyBannerDismissed {
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
                Button {
                    isApiKeyBannerDismissed = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(10)
            .background(Color.orange.opacity(0.15))
            .cornerRadius(8)
            .padding(.horizontal)
            .padding(.top, 4)
        }
    }

    @ViewBuilder private var onDeviceModelBanner: some View {
        if model.currentProviderKind == .onDevice && LlamaCppRuntime.defaultModelURL() == nil {
            HStack(spacing: 8) {
                Image(systemName: "cpu")
                    .foregroundStyle(.orange)
                Text("Selecciona tu archivo .gguf para correr en el iPhone.")
                    .font(.caption)
                Spacer()
                Button("Cargar .gguf") {
                    showOnDeviceModelPicker = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(10)
            .background(Color.orange.opacity(0.15))
            .cornerRadius(8)
            .padding(.horizontal)
            .padding(.top, 4)
            .fileImporter(
                isPresented: $showOnDeviceModelPicker,
                allowedContentTypes: [.data, UTType(filenameExtension: "gguf") ?? .data]
            ) { result in
                switch result {
                case .success(let url):
                    do {
                        _ = try LlamaCppRuntime.importModel(from: url)
                        model.rebuildRuntime()
                    } catch {
                        onDeviceImportError = error.localizedDescription
                    }
                case .failure(let err):
                    onDeviceImportError = err.localizedDescription
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            apiKeyBanner
            onDeviceModelBanner
            serverBanner
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal).padding(.top, 8)
            consolidationBanner
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

            ZStack(alignment: .bottom) {
                transcript

                inputBar
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            }
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
                    let isCustom = model.wakeDetector?.useCustomWakeWord == true
                    let title = on ? "Escuchando" : (isCustom ? "Voz activa" : "Hey Jarvis")
                    Label(title, systemImage: on ? "ear.badge.checkmark" : "ear")
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
                    let isCustom = model.wakeDetector?.useCustomWakeWord == true
                    let title = on ? "Escuchando" : (isCustom ? "Activación por voz" : "Hey Jarvis")
                    Label(title, systemImage: on ? "ear.badge.checkmark" : "ear")
                        .foregroundStyle(on ? .green : .secondary)
                }
                .help("Activar/desactivar escucha continua")
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
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                for url in urls {
                    guard url.startAccessingSecurityScopedResource() else { continue }
                    defer { url.stopAccessingSecurityScopedResource() }
                    let name = url.lastPathComponent
                    let ext = url.pathExtension.lowercased()
                    let content = try? String(contentsOf: url, encoding: .utf8)
                    let icon: String
                    if ["png", "jpg", "jpeg", "heic", "webp"].contains(ext),
                       let data = try? Data(contentsOf: url),
                       let img = PlatformImage(data: data) {
                        attachments.append(ChatAttachment(name: name, iconName: "photo", image: img, textContent: nil))
                        continue
                    } else if ["pdf", "doc", "docx", "pages"].contains(ext) {
                        icon = "doc.richtext"
                    } else {
                        icon = "doc.text"
                    }
                    attachments.append(ChatAttachment(name: name, iconName: icon, image: nil, textContent: content))
                }
            case .failure:
                break
            }
        }
        .onChange(of: selectedPhotoItems) { _, items in
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let img = PlatformImage(data: data) {
                        await MainActor.run {
                            attachments.append(ChatAttachment(name: "Foto", iconName: "photo", image: img, textContent: nil))
                        }
                    }
                }
                await MainActor.run {
                    selectedPhotoItems.removeAll()
                }
            }
        }
        .task { model.ensureMemory() }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach($model.agentLog) { $entry in
                        ChatLogRow(entry: $entry,
                                   panel: entry.panelID.flatMap { model.browserPanels.panels[$0] })
                            .id(entry.id)
                    }
                    Color.clear.frame(height: 75)
                }
                .padding()
            }
            .onChange(of: model.agentLog.count) { _, newCount in
                if newCount > 0, let lastId = model.agentLog.last?.id {
                    withAnimation { proxy.scrollTo(lastId, anchor: .bottom) }
                }
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

    private func toggleDictation() {
        if dictationManager.state == .recording {
            dictationManager.stopDictation()
        } else {
            Task {
                let ok = await dictationManager.startDictation(existingText: input) { updatedText in
                    input = updatedText
                }
                if !ok, let err = dictationManager.lastError {
                    model.agentLog.append(ChatLogEntry(role: "system", text: "Dictado: \(err)"))
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            // Símbolo + flotante para fotos y documentos
            Menu {
                PhotosPicker(selection: $selectedPhotoItems, maxSelectionCount: 5, matching: .images) {
                    Label("Fotos y Videos", systemImage: "photo.on.rectangle")
                }
                Button {
                    showFilePicker = true
                } label: {
                    Label("Documentos", systemImage: "doc")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
                    .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 3)
            }
            .buttonStyle(.plain)
            .disabled(model.agentRunning)

            // Píldora de texto flotante moderna (rounded capsule)
            VStack(alignment: .leading, spacing: 6) {
                if !attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(attachments) { att in
                                HStack(spacing: 5) {
                                    if let img = att.image {
                                        #if os(iOS)
                                        Image(uiImage: img)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 22, height: 22)
                                            .clipShape(RoundedRectangle(cornerRadius: 4))
                                        #else
                                        Image(nsImage: img)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 22, height: 22)
                                            .clipShape(RoundedRectangle(cornerRadius: 4))
                                        #endif
                                    } else {
                                        Image(systemName: att.iconName)
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(att.name)
                                        .font(.caption2)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .frame(maxWidth: 100)
                                    Button {
                                        withAnimation {
                                            attachments.removeAll { $0.id == att.id }
                                        }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(tertiaryBackground)
                                .clipShape(Capsule())
                            }
                        }
                        .padding(.top, 4)
                        .padding(.horizontal, 4)
                    }
                }

                HStack(alignment: .bottom, spacing: 6) {
                    TextField(dictationManager.state == .recording ? "Escuchando…" : "Mensaje a Gemma…", text: $input, axis: .vertical)
                        .lineLimit(1...5)
                        .textFieldStyle(.plain)
                        .padding(.leading, 10)
                        .padding(.vertical, 8)
                        .disabled(model.agentRunning || !serverReady)
                        .onSubmit {
                            send()
                        }

                    // Micrófono metido dentro de la píldora para dictado directo
                    Button(action: toggleDictation) {
                        Image(systemName: dictationManager.state == .recording ? "stop.circle.fill" : "mic.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(dictationManager.state == .recording ? .white : .secondary)
                            .frame(width: 32, height: 32)
                            .background(dictationManager.state == .recording ? Color.red : Color.clear)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.agentRunning)
                    .help(dictationManager.state == .recording ? "Detener dictado" : "Dictar mensaje")

                    // Botón circular de Enviar o Cancelar dentro de la píldora
                    if model.agentRunning {
                        Button(action: { model.cancelAgentTurn() }) {
                            ZStack {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 32, height: 32)
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Detener generación")
                    } else {
                        let canSend = serverReady && (!input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
                        Button(action: send) {
                            ZStack {
                                Circle()
                                    .fill(canSend ? Color.accentColor : buttonFillBackground)
                                    .frame(width: 32, height: 32)
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(canSend ? .white : Color.secondary.opacity(0.4))
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSend)
                        .keyboardShortcut(.return, modifiers: [])
                    }
                }
                .padding(.trailing, 4)
                .padding(.bottom, 2)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 4)
        }
    }

    private func send() {
        if dictationManager.state == .recording {
            dictationManager.stopDictation()
        }

        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !attachments.isEmpty), !model.agentRunning, serverReady else { return }
        input = ""

        var promptToSend = text
        if !attachments.isEmpty {
            var attNotes: [String] = []
            for att in attachments {
                if let content = att.textContent, !content.isEmpty {
                    let preview = content.count > 2500 ? String(content.prefix(2500)) + "\n...[contenido truncado]..." : content
                    attNotes.append("[Documento adjunto: \(att.name)]:\n\(preview)")
                } else if att.image != nil {
                    attNotes.append("[Foto adjunta: \(att.name)]")
                } else {
                    attNotes.append("[Archivo adjunto: \(att.name)]")
                }
            }
            if !attNotes.isEmpty {
                let header = attNotes.joined(separator: "\n\n")
                promptToSend = text.isEmpty ? header : "\(header)\n\n\(text)"
            }
            attachments.removeAll()
        }

        model.startAgentTurn(promptToSend)
    }
}

struct ChatLogRow: View {
    @Binding var entry: ChatLogEntry
    /// Estado del panel de navegador de esta fila; `nil` si no es una fila de panel o ya no existe.
    let panel: BrowserPanelState?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch entry.role {
            case "you":
                HStack {
                    Spacer()
                    Text(entry.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .textSelection(.enabled)
                }

            case "tool":
                ToolLogRow(entry: $entry)

            case "browserPanel":
                if let panel { BrowserPanelView(state: panel) }

            case "system":
                HStack {
                    Text(entry.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .italic()
                    Spacer()
                }

            case "error":
                HStack {
                    Text(entry.text)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding(8)
                        .background(Color.red.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .textSelection(.enabled)
                    Spacer()
                }

            case "gemma":
                VStack(alignment: .leading, spacing: 6) {
                    if let thought = entry.thought, !thought.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    entry.isThoughtExpanded.toggle()
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: entry.isThoughtExpanded ? "chevron.up" : "chevron.down")
                                        .font(.caption2.weight(.bold))
                                    Text("thinking")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                }
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.secondary.opacity(0.12))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)

                            if entry.isThoughtExpanded {
                                Text(thought.trimmingCharacters(in: .whitespacesAndNewlines))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.secondary.opacity(0.06))
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .textSelection(.enabled)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                    }

                    if !entry.text.isEmpty {
                        Text(entry.text)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if entry.thought != nil {
                        Text("Pensando…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .italic()
                    }
                }

            default:
                Text(entry.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
