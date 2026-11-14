import SwiftUI
import UniformTypeIdentifiers

/// macOS Settings (⌘,). M2c-1 hosts the "keep model resident" toggle; later M2c slices add
/// host/port/model and image options here.
/// Un campo de ajustes con botón de borrar. Existe por una avería concreta: en el iPhone
/// no había forma de vaciar la URL ni el token del servicio de memoria. Dos causas, y las
/// dos están cerradas aquí y en `HarnessModel.ensureMemory()`:
///
///  1. `ensureMemory()` reescribía el ajuste cuando lo encontraba vacío, y Ajustes lo llama
///     en cada pulsación de tecla, así que el valor viejo se volvía a escribir completo.
///     Eso se arregló allí: un ajuste solo se escribe donde el usuario lo escribe.
///  2. Un `SecureField` es, para iOS, un campo de contraseña: el relleno automático se
///     ofrece a repoblarlo y el teclado le aplica mayúsculas y autocorrección. De ahí que
///     un token pegado llegara con una mayúscula de más o con un espacio al final.
///
/// El botón de borrar, además de ser la vía rápida, es la que no depende del teclado:
/// pone la cadena vacía de una vez, sin pasar por el relleno automático.
private struct SettingsCredentialField: View {
    let titulo: String
    /// `true` para un secreto (se pinta con puntos y se puede revelar).
    let esSecreto: Bool
    @Binding var texto: String
    /// Se muestra debajo del campo cuando está vacío y vacío significa algo.
    var avisoSiVacio: String? = nil
    @State private var revelado = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                campo
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    // Sin esto el teclado mete una mayúscula inicial y la autocorrección
                    // cambia lo pegado: un token hexadecimal no sobrevive a ninguna de las dos.
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(esSecreto ? .asciiCapable : .URL)
                    // `.none` apaga el relleno automático de contraseñas, que es lo que
                    // repoblaba el campo en cuanto se quedaba vacío.
                    .textContentType(.none)
                    #endif
                if esSecreto {
                    Button {
                        revelado.toggle()
                    } label: {
                        Image(systemName: revelado ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(revelado ? "Ocultar" : "Mostrar")
                    .accessibilityLabel(revelado ? "Ocultar \(titulo)" : "Mostrar \(titulo)")
                }
                Button {
                    texto = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(texto.isEmpty)
                .help("Borrar \(titulo)")
                .accessibilityLabel("Borrar \(titulo)")
            }
            if let avisoSiVacio, texto.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(avisoSiVacio)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder private var campo: some View {
        if esSecreto && !revelado {
            SecureField(titulo, text: $texto)
        } else {
            TextField(titulo, text: $texto)
        }
    }
}

struct SettingsView: View {
    let model: HarnessModel
    @AppStorage(SettingsKeys.keepModelResident) private var keepResident = false
    @AppStorage("memoryBaseURL") private var memoryBaseURL: String = "http://localhost:8081"
    /// NO es `@AppStorage`, y ésa es la Tarea 6b. Con este token se lee y se escribe la memoria
    /// personal entera del usuario en el i3, y la voz comparte el mismo secreto, así que vive en
    /// el llavero (`TokenDeMemoria`) y no en `UserDefaults`. El campo de abajo ya se pintaba como
    /// secreto; antes de esto el almacén mentía. Y su valor por omisión **era el placeholder
    /// débil** `replace-me-with-a-long-random-string`: se va con el `@AppStorage`. Se carga al
    /// aparecer (lo que además dispara la migración del sitio viejo) y se guarda en cada cambio.
    @State private var memoryBearerToken: String = ""
    @AppStorage(SettingsKeys.browserBaseURL) private var browserBaseURL: String = ""
    /// NO es `@AppStorage`, y ésa es la Tarea 6. Este token autoriza al agente a conducir el
    /// navegador y al panel a verlo, así que vive en el llavero (`TokenDeConducir`) y no en
    /// `UserDefaults`. El campo de abajo ya se pintaba como secreto; antes de esto el almacén
    /// mentía. Se carga al aparecer (lo que además dispara la migración del sitio viejo) y se
    /// guarda en cada cambio.
    @State private var browserBearerToken: String = ""
    @AppStorage("voiceBaseURL") private var voiceBaseURL: String = ""
    #if os(iOS)
    @AppStorage(SettingsKeys.chatProvider) private var chatProvider = "onDevice"
    #else
    @AppStorage(SettingsKeys.chatProvider) private var chatProvider = "local"
    #endif
    @AppStorage(SettingsKeys.chatModel) private var chatModel = ""
    @AppStorage(SettingsKeys.consolidationProvider) private var consolidationProvider = "local"
    @AppStorage(SettingsKeys.consolidationModel) private var consolidationModel = ""
    @AppStorage("useWakeWord") private var useWakeWord = false
    @AppStorage("useCustomWakeWord") private var useCustomWakeWord = false
    @AppStorage("modelTemperature") private var temperature: Double = 0.2
    @AppStorage("modelMaxTokens") private var maxOutputTokens: Int = 2048
    @AppStorage(AtoZSettingsKeys.enabled) private var atozEnabled = true
    @AppStorage(AtoZSettingsKeys.dryRun) private var atozDryRun = false
    @AppStorage(AtoZSettingsKeys.addShiftAuthorized) private var atozAddShiftAuthorized = true
    @AppStorage(AtoZSettingsKeys.suspended) private var atozSuspended = false
    @AppStorage(AtoZSettingsKeys.suspendedReason) private var atozSuspendedReason = ""
    @ObservedObject private var atozSession = AtoZSessionManager.shared
    @State private var showEnrollment = false
    @State private var showAtoZLogin = false

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
            Section("Parámetros del Modelo") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Temperatura")
                        Spacer()
                        Text(String(format: "%.2f", temperature))
                            .monospacedDigit()
                            .fontWeight(.medium)
                            .foregroundStyle(.tint)
                    }
                    Slider(value: $temperature, in: 0.05...1.0, step: 0.05) {
                        Text("Temperatura")
                    } minimumValueLabel: {
                        Text("0.05 (Preciso)").font(.caption2).foregroundStyle(.secondary)
                    } maximumValueLabel: {
                        Text("1.0 (Creativo)").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(temperature <= 0.35 ? "Baja: respuestas exactas, directas y sin invenciones." :
                         temperature <= 0.7 ? "Equilibrada: conversación natural y fluida." :
                         "Alta: máxima creatividad y variedad (puede inventar más).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                Picker("Longitud máxima de respuesta", selection: $maxOutputTokens) {
                    Text("Corta (~512)").tag(512)
                    Text("Media (~1024)").tag(1024)
                    Text("Larga (~2048)").tag(2048)
                    Text("Máxima (~4096)").tag(4096)
                }
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
                SettingsCredentialField(titulo: "Base URL", esSecreto: false, texto: $memoryBaseURL,
                                        avisoSiVacio: "Sin URL no hay memoria: el agente no recuerda nada entre turnos.")
                    .help("URL del servicio de memoria en el i3, p. ej. http://100.x.y.z:8081.")
                SettingsCredentialField(titulo: "Bearer token", esSecreto: true, texto: $memoryBearerToken,
                                        avisoSiVacio: "Sin token el servidor responde 401 a todo.")
                    .help("Mismo valor que MEMORY_BEARER_TOKEN en el .env del docker-compose.")
                Text("La app reconecta al cambiar estos valores. Puerto del servicio de memoria: 8081 "
                     + "(la voz es 8082 y el navegador 8083 — son tres servicios distintos en la misma máquina).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: memoryBaseURL) { _, _ in model.ensureMemory() }
            // El token del servicio de memoria se lee del llavero al abrir Ajustes, NO de
            // `UserDefaults`. Esta primera lectura es además la que dispara la migración: un
            // usuario que ya tenía el token escrito en claro lo ve seguir en el campo, y el sitio
            // viejo queda vacío.
            .onAppear {
                TokenDeMemoria.migrar()
                memoryBearerToken = TokenDeMemoria.leer()
            }
            // UN SOLO `onChange` para este token, y el orden importa: primero se GUARDA en el
            // llavero y solo después se reconstruyen los clientes, porque los dos leen de ahí. Con
            // los tres efectos en `onChange` separados (como estaban, uno por sección) el orden
            // entre ellos no está garantizado y `ensureMemory()` podía reconstruir el cliente con
            // el token ANTERIOR.
            .onChange(of: memoryBearerToken) { _, nuevo in
                TokenDeMemoria.guardar(nuevo)
                model.ensureMemory()
                model.ensureVoice()
            }
            Section("Navegador (i3)") {
                SettingsCredentialField(titulo: "URL base del navegador (opcional)",
                                        esSecreto: false, texto: $browserBaseURL)
                    .help("Servicio del navegador en el i3, p. ej. http://100.x.y.z:8083.")
                SettingsCredentialField(titulo: "Token de acceso", esSecreto: true, texto: $browserBearerToken)
                    .help("Token del servicio del navegador en el i3.")
                #if os(macOS)
                Text("Vacío → el agente usa agent-browser en este Mac. Con URL, conduce el navegador del i3. Se aplica en el siguiente turno.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                #else
                Text("Pon aquí la URL del navegador del i3 para que el agente pueda navegar. Vacío → el agente no tiene navegador. Se aplica en el siguiente turno.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                #endif
            }
            // El token de conducir se lee del llavero al abrir Ajustes, NO de `UserDefaults`.
            // Esta primera lectura es además la que dispara la migración: un usuario que ya tenía
            // el token escrito en claro lo ve seguir en el campo, y el sitio viejo queda vacío.
            .onAppear {
                TokenDeConducir.migrar()
                browserBearerToken = TokenDeConducir.leer()
            }
            .onChange(of: browserBearerToken) { _, nuevo in TokenDeConducir.guardar(nuevo) }

            Section("Voice Service") {
                SettingsCredentialField(titulo: "Voice base URL (opcional)",
                                        esSecreto: false, texto: $voiceBaseURL)
                    .help("Override del servicio de voz. Vacío = usa el host de Memory en el puerto 8082.")
                Text("Vacío → deriva del Memory Service en :8082 (mismo i3). Usa el mismo bearer token.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: voiceBaseURL) { _, _ in model.ensureVoice() }
            .onChange(of: memoryBaseURL) { _, _ in model.ensureVoice() }
            // El `onChange` del token vive arriba, junto al `guardar`, para que el guardado pase
            // antes que los dos `ensure*`. Ver el comentario de la sección "Memory Service".
            
            Section("Wake Word (Activación por voz)") {
                Toggle("Habilitar activación por voz", isOn: $useWakeWord)
                    .onChange(of: useWakeWord) { _, enabled in
                        Task {
                            if enabled {
                                await model.wake?.enable()
                            } else {
                                model.wake?.disable()
                            }
                        }
                    }
                
                if let detector = model.wakeDetector {
                    Toggle("Usar frase y voz personalizada", isOn: $useCustomWakeWord)
                        .disabled(!detector.useCustomWakeWord)
                        .onChange(of: useCustomWakeWord) { _, val in
                            detector.loadCustomWakeWord()
                        }
                    
                    Button(detector.useCustomWakeWord ? "Volver a entrenar voz" : "Configurar frase y voz propia") {
                        showEnrollment = true
                    }
                    
                    if detector.useCustomWakeWord {
                        Button("Restablecer a default (Hey Jarvis)") {
                            detector.clearCustomWakeWord()
                            useCustomWakeWord = false
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                    }
                }
            }

            Section("Amazon A to Z") {
                Toggle("Habilitar integración", isOn: $atozEnabled)

                if atozEnabled {
                    HStack {
                        Text("Estado de sesión:")
                        Spacer()
                        if atozSession.isLoggedIn {
                            VStack(alignment: .trailing, spacing: 2) {
                                Label("Activa", systemImage: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                if let msg = atozSession.syncStatusMessage {
                                    Text(msg).font(.caption2).foregroundColor(.secondary)
                                }
                            }
                        } else {
                            HStack(spacing: 8) {
                                if atozSession.isSyncing {
                                    ProgressView().controlSize(.small)
                                }
                                Label("No iniciada", systemImage: "xmark.circle")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    if atozSession.isLoggedIn {
                        Button("Cerrar sesión (Borrar de memoria y servidor)") {
                            atozSession.clearSession()
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                    } else {
                        HStack {
                            Button("Iniciar sesión en A to Z...") {
                                showAtoZLogin = true
                            }
                            Spacer()
                            Button("Sincronizar del Servidor") {
                                Task {
                                    await atozSession.syncSessionFromServer()
                                }
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                    }

                    Toggle("Modo simulado (Dry Run)", isOn: $atozDryRun)
                    Text("En modo simulado, Gemma valida los turnos pero no envía mutaciones de aceptación a Amazon.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Toggle("Autorización de aceptación de turnos", isOn: $atozAddShiftAuthorized)
                    Text("Solo habilitar si tienes autorización expresa para solicitar turnos automáticamente. Requiere confirmación explícita antes de cualquier acción.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if atozSuspended {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Acceso suspendido: \(atozSuspendedReason)", systemImage: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.caption)
                            Button("Reactivar acceso") {
                                AtoZSettings.clearSuspension()
                            }
                            .font(.caption)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showAtoZLogin) {
            AtoZLoginSheet()
        }
        .sheet(isPresented: $showEnrollment) {
            if let detector = model.wakeDetector {
                WakeWordEnrollmentView(detector: detector)
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(width: 420)
        #endif
        .padding()
        .onAppear {
            #if os(iOS)
            if memoryBaseURL == "http://localhost:8081" || memoryBaseURL == "http://192.168.1.50:8081" {
                memoryBaseURL = "http://100.91.174.81:8081"
            }
            #endif
            Task {
                if !atozSession.isLoggedIn {
                    await atozSession.syncSessionFromServer()
                }
            }
        }
    }
}

private struct ProviderPicker: View {
    let title: String
    @Binding var providerRaw: String
    @Binding var model: String
    let onChange: () -> Void
    @State private var apiKey: String = ""
    @State private var showFilePicker: Bool = false
    @State private var importError: String?
    @FocusState private var keyFocused: Bool

    private var kind: ModelProvider.Kind { ModelProvider.Kind(rawValue: providerRaw) ?? .defaultKind }
    /// Persist the typed key (whitespace/newline-trimmed) to the Keychain and rebuild. Called on
    /// Enter AND on focus-loss, so the user doesn't have to remember to press Return — relying on
    /// `.onSubmit` alone silently dropped pasted keys (sent no auth → provider 403).
    private func commitKey() {
        let k = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // Al llavero del dispositivo, y NUNCA a `UserDefaults`: el almacén viejo escribía además
        // una copia en claro (`keychain_fallback.<cuenta>`) de la que la lectura tiraba, así que
        // el llavero era decorativo. Ver `ClaveDeProveedor`.
        if !k.isEmpty { ClaveDeProveedor.guardar(k, proveedor: kind.rawValue); apiKey = "" }
        onChange()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(title, selection: $providerRaw) {
                ForEach(ModelProvider.Kind.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            .onChange(of: providerRaw) { _, newRaw in
                if let newKind = ModelProvider.Kind(rawValue: newRaw) {
                    model = newKind.defaultModel
                }
                apiKey = ""
                onChange()
            }

            if kind == .onDevice {
                let detected = LlamaCppRuntime.defaultModelURL()
                HStack(spacing: 8) {
                    Image(systemName: detected != nil ? "cpu" : "exclamationmark.triangle")
                        .foregroundStyle(detected != nil ? .green : .orange)
                    Text(detected?.lastPathComponent ?? "Ningún modelo .gguf cargado")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Elegir .gguf") {
                        showFilePicker = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .fileImporter(
                    isPresented: $showFilePicker,
                    allowedContentTypes: [.data, UTType(filenameExtension: "gguf") ?? .data]
                ) { result in
                    switch result {
                    case .success(let url):
                        do {
                            let imported = try LlamaCppRuntime.importModel(from: url)
                            model = imported.lastPathComponent
                            onChange()
                        } catch {
                            importError = error.localizedDescription
                        }
                    case .failure(let err):
                        importError = err.localizedDescription
                    }
                }
                if let err = importError {
                    Text("Error al importar: \(err)").font(.caption2).foregroundStyle(.red)
                }
            } else {
                TextField("Modelo (\(kind.defaultModel))", text: $model)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(onChange)
                if !kind.isLocalMLX {
                    SecureField(ClaveDeProveedor.leer(proveedor: kind.rawValue) == nil
                                    ? "API key" : "•••• guardada",
                                text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .focused($keyFocused)
                        .onSubmit { commitKey() }
                        .onChange(of: keyFocused) { _, focused in if !focused { commitKey() } }
                }
            }
        }
    }
}
