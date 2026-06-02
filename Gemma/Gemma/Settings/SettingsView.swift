import SwiftUI

/// macOS Settings (⌘,). M2c-1 hosts the "keep model resident" toggle; later M2c slices add
/// host/port/model and image options here.
struct SettingsView: View {
    let model: HarnessModel
    @AppStorage(SettingsKeys.keepModelResident) private var keepResident = false
    @AppStorage("memoryBaseURL") private var memoryBaseURL: String = "http://localhost:8081"
    @AppStorage("memoryBearerToken") private var memoryBearerToken: String = ""

    var body: some View {
        Form {
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
