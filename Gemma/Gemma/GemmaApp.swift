import SwiftUI

@main
struct GemmaApp: App {
    @State private var model = HarnessModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            HarnessView(model: model)
                .task {
                    // El token del navegador conduce un Chrome con la sesión de Google del
                    // usuario dentro, así que no puede seguir en claro en `UserDefaults`. Esto lo
                    // mueve al llavero y lo borra del sitio viejo, UNA vez y al arrancar: aquí y
                    // no en `leer`, porque leer no debe escribir, y no solo en Ajustes, porque un
                    // usuario que no vuelva a abrirlos se quedaría el fichero en claro para
                    // siempre. Es idempotente: a la segunda no hay nada que mover.
                    TokenDeConducir.migrar()
                    // Siembra los atajos que Gemma ya conoce. En iOS no hay forma de
                    // enumerarlos, así que sin esto el modelo tendría que adivinar
                    // nombres. Se aplica una sola vez y respeta las correcciones del
                    // usuario.
                    ShortcutSeed.apply(to: .shared)
                    // Recalcula el viaje de los recordatorios con sitio mientras la app
                    // está viva, para que la hora de salida siga siendo la correcta
                    // aunque el usuario se haya movido.
                    await ReminderMonitorDriver.shared.start()
                    await AtoZSessionManager.shared.syncSessionFromServer()
                }
                .onChange(of: scenePhase) { _, phase in
                    // Volver al primer plano es el momento con más probabilidad de que
                    // la posición haya cambiado desde la última revisión.
                    guard phase == .active else { return }
                    Task { await ReminderMonitorDriver.shared.refreshNow() }
                }
                .onOpenURL { url in
                    guard url.scheme == "gemma" else { return }

                    // Vuelta de la app Atajos tras ejecutar un atajo: se entrega al
                    // broker, que reanuda la llamada de `run_shortcut` que la espera.
                    if url.host == ShortcutCallback.host {
                        Task {
                            _ = await ShortcutCallbackBroker.shared.deliver(url: url)
                        }
                        return
                    }

                    Task {
                        await AtoZSessionManager.shared.syncSessionFromServer()
                    }
                }
        }
        #if os(macOS)
        Settings {
            SettingsView(model: model)
        }
        #endif
    }
}
