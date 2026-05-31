import SwiftUI

/// macOS Settings (⌘,). M2c-1 hosts the "keep model resident" toggle; later M2c slices add
/// host/port/model and image options here.
struct SettingsView: View {
    let model: HarnessModel
    @AppStorage(SettingsKeys.keepModelResident) private var keepResident = false

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
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
    }
}
