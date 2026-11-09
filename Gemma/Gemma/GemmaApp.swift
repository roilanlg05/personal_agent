import SwiftUI

@main
struct GemmaApp: App {
    /// LA MIGRACIÓN DEL TOKEN DE MEMORIA CORRE AQUÍ, Y TIENE QUE SER AQUÍ: antes de construir el
    /// `HarnessModel`.
    ///
    /// No es estilo, es orden de ejecución medido en el fuente. `HarnessModel.init` llama a
    /// `ensureVoice()`, que **ya lee el token del llavero**. Si la migración se hiciera en el
    /// `.task` de abajo —que es donde la hace `TokenDeConducir`, y allí está bien porque nadie lo
    /// lee en `init`— el primer arranque tras la actualización construiría el cliente de voz con
    /// el token vacío: el usuario se quedaría sin voz hasta reiniciar la app, sin saber por qué.
    /// Un valor por omisión de una propiedad almacenada se evalúa antes del cuerpo de cualquier
    /// `init` de este `App`, así que el único sitio estrictamente anterior a `HarnessModel()` es
    /// la propia expresión que lo construye.
    ///
    /// **Y no puede ir en `HarnessModel.init`**, que sería el sitio obvio (ahí ya vive
    /// `migrateMemoryBaseURLIfNeeded`): tres ficheros de prueba construyen un `HarnessModel`, el
    /// host de las pruebas es la propia app, y una corrida de la suite le habría ESCRITO la
    /// entrada de producción del llavero y borrado el token del sitio viejo. Migrar es una
    /// escritura; las pruebas no la hacen.
    ///
    /// Es idempotente: a la segunda no hay nada que mover.
    ///
    /// LAS API KEYS DE PAGO MIGRAN EN EL MISMO SITIO Y POR EL MISMO MOTIVO (Tarea 6c). El `init`
    /// del `HarnessModel` construye el runtime de chat, que **ya lee la key del proveedor**
    /// (`clavesDelAlmacen`), así que si la migración fuera después, el primer arranque tras la
    /// actualización arrancaría sin key: el banner «Falta la API Key» sobre la key que el usuario
    /// sí tiene. `migrarTodas` es idempotente y corre en cada arranque, lo que además da el
    /// reintento: si un arranque no pudo escribir en el llavero, no borró nada del camino viejo y
    /// el siguiente lo vuelve a intentar.
    @State private var model: HarnessModel = {
        TokenDeMemoria.migrar()
        ClaveDeProveedor.migrarTodas()
        return HarnessModel()
    }()
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
