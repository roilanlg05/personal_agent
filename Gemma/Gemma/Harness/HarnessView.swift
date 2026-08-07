import SwiftUI

struct HarnessView: View {
    @Bindable var model: HarnessModel
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showSettingsSheet: Bool = false
    #endif

    var body: some View {
        #if os(iOS)
        if horizontalSizeClass == .regular {
            NavigationSplitView {
                IPadSidebarView(model: model, showSettingsSheet: $showSettingsSheet)
            } detail: {
                NavigationStack {
                    AgentChatView(model: model)
                }
            }
            .sheet(isPresented: $showSettingsSheet) {
                NavigationStack {
                    SettingsView(model: model)
                        .navigationTitle("Ajustes")
                        .toolbar { Button("Hecho") { showSettingsSheet = false } }
                }
            }
            .task { model.startServer() }
        } else {
            NavigationStack {
                AgentChatView(model: model)
            }
            .task { model.startServer() }
        }
        #else
        AgentChatView(model: model)
            .task { model.startServer() }
        #endif
    }
}

#if os(iOS)
private struct IPadSidebarView: View {
    @Bindable var model: HarnessModel
    @Binding var showSettingsSheet: Bool

    var body: some View {
        List {
            Section("Asistente Personal") {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.title2)
                        .foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Gemma").font(.headline)
                        Text("Modelo: \(model.currentProviderKind.displayName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            if model.isMissingApiKey {
                Section("Requerido") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Falta API Key", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.bold())
                            .foregroundStyle(.orange)
                        Text("Para usar \(model.currentProviderKind.displayName), ingresa tu API key en Ajustes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Ingresar API Key") {
                            showSettingsSheet = true
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Estado de Conexión") {
                HStack {
                    Label("Memory Service", systemImage: "brain")
                    Spacer()
                    Circle()
                        .fill(model.memory != nil ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                }
                HStack {
                    Label("Escucha Continua", systemImage: "mic.fill")
                    Spacer()
                    let wakeOn = model.wake != nil && model.wake?.state != .off
                    Text(wakeOn ? "Hey Jarvis" : "Manual")
                        .font(.caption)
                        .foregroundStyle(wakeOn ? .green : .secondary)
                }
            }

            Section("Herramientas") {
                Button {
                    model.showMemory = true
                } label: {
                    Label("Grafo de Memoria", systemImage: "point.3.connected.trianglepath.dotted")
                }

                Button {
                    model.consolidateNow()
                } label: {
                    Label("Consolidar Memoria", systemImage: "moon.zzz")
                }

                Button {
                    showSettingsSheet = true
                } label: {
                    Label("Ajustes del Sistema", systemImage: "gear")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Gemma")
    }
}
#endif
