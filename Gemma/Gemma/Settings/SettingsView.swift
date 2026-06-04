import SwiftUI

/// macOS Settings (⌘,). M2c-1 hosts the "keep model resident" toggle; later M2c slices add
/// host/port/model and image options here.
struct SettingsView: View {
    let model: HarnessModel
    @AppStorage(SettingsKeys.keepModelResident) private var keepResident = false
    @AppStorage("memoryBaseURL") private var memoryBaseURL: String = "http://localhost:8081"
    @AppStorage("memoryBearerToken") private var memoryBearerToken: String = ""
    @AppStorage(SettingsKeys.chatProvider) private var chatProvider = "local"
    @AppStorage(SettingsKeys.chatModel) private var chatModel = ""
    @AppStorage(SettingsKeys.consolidationProvider) private var consolidationProvider = "local"
    @AppStorage(SettingsKeys.consolidationModel) private var consolidationModel = ""

    var body: some View {
        Form {
            Section("Modelos") {
                ProviderPicker(title: "Chat", providerRaw: $chatProvider, model: $chatModel,
                               onChange: { model.rebuildRuntime(); model.refreshLocalModelLifecycle() })
                ProviderPicker(title: "Consolidación", providerRaw: $consolidationProvider, model: $consolidationModel,
                               onChange: { model.pushConsolidationConfig(); model.refreshLocalModelLifecycle() })
                Text("El chat usa el modelo elegido en este Mac. La consolidación corre en el i3 con su propio modelo. Las API keys se guardan cifradas.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Servidor") {
                Toggle("Mantener el modelo en memoria", isOn: $keepResident)
                    .onChange(of: keepResident) { _, new in model.applyKeepModelResident(new) }
                Text("Cablea el modelo en RAM (~16 GB) para que nunca tenga arranque en frío. "
                     + "Bajo presión de memoria, otras apps irán más lento. "
                     + "Cambiarlo reinicia el servidor (~20 s).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Memory Service") {
                TextField("Base URL", text: $memoryBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .help("URL del servicio de memoria. Si lo movés al i3, cambia esto a la Tailscale IP.")
                SecureField("Bearer token", text: $memoryBearerToken)
                    .textFieldStyle(.roundedBorder)
                    .help("Mismo valor que MEMORY_BEARER_TOKEN en el .env del docker-compose.")
                Text("La app reconecta al cambiar estos valores. Default: http://localhost:8081.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: memoryBaseURL) { _, _ in model.ensureMemory() }
            .onChange(of: memoryBearerToken) { _, _ in model.ensureMemory() }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
    }
}

private struct ProviderPicker: View {
    let title: String
    @Binding var providerRaw: String
    @Binding var model: String
    let onChange: () -> Void
    @State private var apiKey: String = ""

    private var kind: ModelProvider.Kind { ModelProvider.Kind(rawValue: providerRaw) ?? .local }
    private var keyAccount: String { "apiKey.\(kind.rawValue)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(title, selection: $providerRaw) {
                ForEach(ModelProvider.Kind.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            .onChange(of: providerRaw) { _, _ in apiKey = ""; onChange() }
            TextField("Modelo (\(kind.defaultModel))", text: $model)
                .textFieldStyle(.roundedBorder)
                .onSubmit(onChange)
            if !kind.isLocalMLX {
                SecureField(KeychainStore.shared.get(account: keyAccount) == nil ? "API key" : "•••• guardada",
                            text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        if !apiKey.isEmpty { KeychainStore.shared.set(apiKey, account: keyAccount); apiKey = "" }
                        onChange()
                    }
            }
        }
    }
}
