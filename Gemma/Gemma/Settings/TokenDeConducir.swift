import Foundation
import Security

/// Un almacén de secretos del dispositivo, detrás de un protocolo.
///
/// POR QUÉ UN PROTOCOLO Y NO EL LLAVERO A PELO. Dos razones, y la segunda es de medición.
///
/// La primera: ni la vista de Ajustes ni los dos lectores de `HarnessModel` tienen que saber qué
/// hay detrás. Lo único que necesitan es «dame el token» y «guarda este token».
///
/// La segunda: **el llavero no es seguro de usar desde una suite de pruebas.** Según cómo esté
/// firmado el binario de pruebas, `SecItemAdd` puede fallar con un error de autorización
/// (`errSecMissingEntitlement`, `-34018`) o —peor— abrir un diálogo del sistema que cuelga la
/// corrida entera. Y la lógica que de verdad importa de esta tarea no es lógica de llavero: es
/// lógica de almacén (mover el token del sitio viejo, borrarlo de allí, qué se lee cuando no hay
/// nada en ninguno de los dos sitios). Con el protocolo, esa lógica se prueba contra un doble en
/// memoria, que es donde viven las propiedades que importan, y el camino del llavero de verdad se
/// mide aparte, en su propia prueba, sobre un nombre de servicio propio de las pruebas.
///
/// `escribir` devuelve si el almacén aceptó el secreto. No es cosmético: un llavero que rechaza la
/// escritura por firma se traga el token en silencio, el usuario lo vuelve a escribir y tampoco se
/// queda, y nadie se enteraría nunca. Quien llame puede decidir qué hacer con el `false`.
public protocol AlmacenDeSecretos: Sendable {
    func leer(cuenta: String) -> String?
    @discardableResult func escribir(_ valor: String, cuenta: String) -> Bool
    func borrar(cuenta: String)
}

/// El llavero del sistema, con la clase de accesibilidad que esta tarea existe para conseguir.
///
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` **y** `kSecAttrSynchronizable: false`, y la
/// elección es exactamente el defecto que se está arreglando. El plan dice que `UserDefaults` «se
/// respalda, se sincroniza y se lee sin desbloquear nada»: son tres defectos, no uno.
///
/// - `ThisDeviceOnly` quita los dos primeros de golpe: un elemento de esa familia **no entra en
///   las copias de seguridad** (ni en iCloud ni en una copia local cifrada) y **no se restaura en
///   otro dispositivo**. Guardarlo con la clase sincronizable arreglaría solo el tercero y el
///   informe diría «hecho».
/// - `WhenUnlocked` quita el tercero: con el dispositivo bloqueado el elemento no se puede leer.
/// - `Synchronizable: false` explícito, aunque `ThisDeviceOnly` ya lo implique, porque también
///   gobierna la BÚSQUEDA: una consulta sin este atributo solo encuentra elementos no
///   sincronizables, así que dejarlo fuera haría que leer y escribir pudieran hablar de elementos
///   distintos si alguien cambiara la clase de accesibilidad más adelante.
///
/// El servicio es PROPIO, separado del de `KeychainStore`, y eso es deliberado: `KeychainStore`
/// escribe una copia en claro de todo lo que guarda en `UserDefaults`
/// (`keychain_fallback.<cuenta>`), que es justo el defecto que esta tarea arregla. Compartir su
/// servicio invitaría a usarlo por error.
public struct LlaveroDelSistema: AlmacenDeSecretos {
    public static let compartido = LlaveroDelSistema()

    private let servicio: String

    public init(servicio: String = "lambert-dev-group.Gemma.secretos") {
        self.servicio = servicio
    }

    /// Los atributos que identifican el elemento. Se usan igual para buscar, borrar y añadir, así
    /// que una consulta nunca puede apuntar a un elemento distinto del que se escribió.
    ///
    /// 🔴 `kSecUseDataProtectionKeychain: true` NO es un adorno, y esto se midió, no se leyó. Sin
    /// él, en **macOS** el elemento va al llavero de ficheros de siempre, que **no tiene clases de
    /// accesibilidad**: `kSecAttrAccessible` se ignora en silencio, `SecItemAdd` devuelve
    /// `errSecSuccess`, y leer los atributos del elemento guardado devuelve `pdmn` = `nil`. Es
    /// decir: sin esta línea, `WhenUnlockedThisDeviceOnly` no se aplica, el elemento SÍ entra en
    /// las copias de seguridad, y el informe diría «hecho». Lo cazó
    /// `test_la_clase_de_accesibilidad_es_la_del_dispositivo_solo_y_sin_respaldo`, que lee la
    /// clase del elemento ESCRITO en vez de confiar en el código que lo escribe. En iOS el llavero
    /// con protección de datos es el único que hay y la bandera no cambia nada.
    private func clave(_ cuenta: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: servicio,
         kSecAttrAccount as String: cuenta,
         kSecAttrSynchronizable as String: false,
         kSecUseDataProtectionKeychain as String: true]
    }

    public func leer(cuenta: String) -> String? {
        var consulta = clave(cuenta)
        consulta[kSecReturnData as String] = true
        consulta[kSecMatchLimit as String] = kSecMatchLimitOne
        var salida: CFTypeRef?
        guard SecItemCopyMatching(consulta as CFDictionary, &salida) == errSecSuccess,
              let datos = salida as? Data,
              let texto = String(data: datos, encoding: .utf8),
              !texto.isEmpty
        else { return nil }
        return texto
    }

    @discardableResult
    public func escribir(_ valor: String, cuenta: String) -> Bool {
        // Borrar y añadir en vez de `SecItemUpdate`: así una sobrescritura no puede heredar la
        // clase de accesibilidad de un elemento viejo escrito con otra.
        SecItemDelete(clave(cuenta) as CFDictionary)
        var nuevo = clave(cuenta)
        nuevo[kSecValueData as String] = Data(valor.utf8)
        nuevo[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(nuevo as CFDictionary, nil) == errSecSuccess
    }

    public func borrar(cuenta: String) {
        SecItemDelete(clave(cuenta) as CFDictionary)
    }
}

/// El token del servicio del navegador del i3: dónde vive y cómo se sale del sitio donde vivía.
///
/// POR QUÉ EXISTE ESTE FICHERO. Hasta ahora este token servía para **mirar** una pantalla, y vivía
/// en `UserDefaults` vía `@AppStorage`, en claro, mientras el campo de Ajustes se pintaba como
/// secreto (`esSecreto: true`). O sea: la interfaz decía la verdad y el almacén mentía, que es
/// peor que no decir nada, porque el usuario cree que está a salvo. Y con el mando compartido ese
/// token pasa a servir para **conducir** un Chrome real —teclas y clics— que en cuanto el usuario
/// inicie sesión una vez tendrá su sesión de Google dentro.
///
/// LO QUE ESTE FICHERO NO HACE, y son dos cosas, las dos a propósito:
///
/// - **No toca el token del servicio de memoria.** Tiene el mismo defecto y este almacén le
///   serviría igual, pero ampliarlo no es decisión de esta tarea.
/// - **No cambia por dónde viaja el token.** Hoy el visor *web* del relé se autentica con
///   `?token=` en la query; es una restricción aparte del spec, con una excepción firmada por el
///   usuario, y no se toca aquí. Medido en este cliente: los dos consumidores del token
///   (`HTTPAgentBrowserInvoker` y `BrowserRelayClient`) lo mandan en la cabecera `Authorization`
///   y **nunca** en la URL, así que la fuga que nombra esa excepción —«cualquier descripción de
///   error que imprima la URL imprime el token»— no es alcanzable desde la app nativa. Hay una
///   prueba que lo fija, para que no deje de ser verdad sin que nadie se entere.
public enum TokenDeConducir {
    /// La cuenta dentro del llavero. Coincide con el nombre de la clave vieja a propósito: es el
    /// mismo secreto, cambiado de sitio.
    public static let cuenta = "browserBearerToken"

    /// El token, o la cadena vacía si no hay ninguno. **Solo lee el almacén**: no mira
    /// `UserDefaults` ni migra nada.
    ///
    /// POR QUÉ LEER NO MIGRA, y es una decisión medida, no de estilo. La primera versión migraba
    /// dentro de `leer`, y eso convertía cada lectura en una ESCRITURA sobre la configuración de
    /// verdad del usuario. Los dos lectores del token se alcanzan desde
    /// `HarnessModel.browserToolRegistry()`, que cinco pruebas de esta suite llaman con
    /// `UserDefaults.standard` (el host de las pruebas es la propia app, así que su dominio es el
    /// del usuario): una corrida de la suite le habría movido el token a un almacén de pega y
    /// **se lo habría borrado del sitio viejo**, dejándole sin token. Separar las dos cosas quita
    /// la clase entera de accidente: leer no tiene efectos, y migrar se llama una vez, desde
    /// `GemmaApp` y desde Ajustes.
    public static func leer(almacen: any AlmacenDeSecretos = LlaveroDelSistema.compartido) -> String {
        (almacen.leer(cuenta: cuenta) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Guarda el token en el almacén y **se asegura de que no quede nada en el sitio viejo**.
    ///
    /// Un token vacío es «no hay token»: se borra el elemento en vez de guardar una cadena vacía,
    /// para no dejar un secreto fantasma en el llavero.
    ///
    /// Devuelve si el almacén aceptó la escritura. El borrado del sitio viejo es incondicional,
    /// incluso si el almacén la rechaza: dejar el token en claro «por si acaso» es exactamente el
    /// defecto que esto arregla, y el precio de un rechazo es que el usuario lo vuelva a escribir.
    @discardableResult
    public static func guardar(_ valor: String,
                               almacen: any AlmacenDeSecretos = LlaveroDelSistema.compartido,
                               defaults: UserDefaults = .standard) -> Bool {
        let limpio = valor.trimmingCharacters(in: .whitespacesAndNewlines)
        let aceptado: Bool
        if limpio.isEmpty {
            almacen.borrar(cuenta: cuenta)
            aceptado = true
        } else {
            aceptado = almacen.escribir(limpio, cuenta: cuenta)
        }
        defaults.removeObject(forKey: SettingsKeys.browserBearerToken)
        return aceptado
    }

    /// Mueve el token del sitio viejo al almacén y **lo borra del sitio viejo**. Idempotente: a la
    /// segunda llamada ya no hay nada en `UserDefaults` y no hace nada.
    ///
    /// LAS DOS MITADES SON OBLIGATORIAS, Y LA SEGUNDA ES LA QUE SE OLVIDA. Si la migración mueve
    /// el token pero no borra el original, esta tarea no arregla nada para el usuario que ya tiene
    /// el suyo guardado en claro: el fichero de preferencias sigue teniéndolo y ahora hay dos
    /// copias. Por eso `defaults.removeObject` corre **siempre** que había algo escrito, incluso
    /// si no se movió nada (porque estaba vacío, o porque el almacén ya tenía un token más nuevo).
    ///
    /// Devuelve `true` solo si movió un token. Un `false` no distingue «no había nada» de «ya
    /// estaba migrado», y no hace falta que lo distinga.
    @discardableResult
    public static func migrar(almacen: any AlmacenDeSecretos = LlaveroDelSistema.compartido,
                              defaults: UserDefaults = .standard) -> Bool {
        guard let viejo = defaults.string(forKey: SettingsKeys.browserBearerToken) else { return false }
        let limpio = viejo.trimmingCharacters(in: .whitespacesAndNewlines)
        var movido = false
        // El almacén manda si ya tiene algo: lo que hay en el llavero es más nuevo que lo que
        // quedó en el sitio viejo, porque al guardar se escribe primero el llavero.
        if !limpio.isEmpty, almacen.leer(cuenta: cuenta) == nil {
            movido = almacen.escribir(limpio, cuenta: cuenta)
        }
        defaults.removeObject(forKey: SettingsKeys.browserBearerToken)
        return movido
    }
}
