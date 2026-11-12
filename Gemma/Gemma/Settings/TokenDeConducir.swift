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
/// Lo que un almacén de secretos sabe hacer **sin poder escribir**: leer y borrar.
///
/// POR QUÉ ESTÁ PARTIDO EN DOS. No es taxonomía: es que la Tarea 6c necesita un almacén que
/// producción **no pueda** usar para guardar. La migración de las API keys tiene que leer del
/// llavero viejo de `KeychainStore` y vaciarlo, y nada más; si ese tipo supiera escribir, un
/// camino futuro podría volver a guardar un secreto allí —sin clase de accesibilidad y con la
/// copia en claro al lado— y compilaría igual. Con la capacidad fuera del tipo, ese error no
/// existe. Ver `LlaveroViejoDeApiKeys`.
public protocol AlmacenSoloDeLectura: Sendable {
    func leer(cuenta: String) -> String?
    func borrar(cuenta: String)
}

public protocol AlmacenDeSecretos: AlmacenSoloDeLectura {
    @discardableResult func escribir(_ valor: String, cuenta: String) -> Bool
}

/// El llavero del sistema, con la clase de accesibilidad que esta tarea existe para conseguir.
///
/// El plan dice que `UserDefaults` «se respalda, se sincroniza y se lee sin desbloquear nada»: son
/// **tres** defectos, no uno, y la clase de accesibilidad es lo que los quita. `ThisDeviceOnly`
/// quita los dos primeros de golpe —un elemento de esa familia **no entra en las copias de
/// seguridad**, ni en iCloud ni en una copia local cifrada, y **no se restaura en otro
/// dispositivo**—. Guardarlo con la clase sincronizable arreglaría solo el tercero y el informe
/// diría «hecho».
///
/// `Synchronizable: false` va explícito aunque `ThisDeviceOnly` ya lo implique, porque ese atributo
/// también gobierna la **BÚSQUEDA**: una consulta sin él solo encuentra elementos no
/// sincronizables, así que dejarlo fuera haría que leer y escribir pudieran hablar de elementos
/// distintos si alguien cambiara la clase más adelante.
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

    /// La clase de accesibilidad con la que se escribe, y **no es la que el plan pedía**. El plan
    /// decidió la familia `WhenUnlockedThisDeviceOnly`; ésta es
    /// `AfterFirstUnlockThisDeviceOnly`, y el motivo es una medición, no una preferencia.
    ///
    /// MEDIDO el 2026-11-09 en este Mac (macOS 27.2, binario de pruebas firmado con el equipo
    /// `ST54FK4W4X`, entitlement `com.apple.application-identifier` presente), escribiendo un
    /// elemento y leyendo después su atributo `pdmn` **del elemento guardado**:
    ///
    /// | llavero | clase pedida | `SecItemAdd` | clase guardada |
    /// |---|---|---|---|
    /// | de ficheros (sin `kSecUseDataProtectionKeychain`) | `WhenUnlockedThisDeviceOnly` | `0` | **`nil`** |
    /// | de ficheros | `AfterFirstUnlockThisDeviceOnly` | `0` | **`nil`** |
    /// | con protección de datos | `WhenUnlockedThisDeviceOnly` | **`-25308`** | `nil` |
    /// | con protección de datos | `AfterFirstUnlockThisDeviceOnly` | `0` | **`cku`** ✅ |
    /// | con protección de datos | (ninguna → `WhenUnlocked`) | **`-25308`** | `nil` |
    ///
    /// Dos cosas salen de ahí, y las dos importan:
    ///
    /// 1. En el llavero **de ficheros** la clase se ignora en silencio: `SecItemAdd` dice
    ///    `errSecSuccess` y el elemento no tiene clase ninguna. O sea que sin
    ///    `kSecUseDataProtectionKeychain` la elección del plan **no se aplicaba**, el elemento SÍ
    ///    entraba en las copias de seguridad, y el informe habría dicho «hecho». De ahí la bandera.
    /// 2. En el llavero con protección de datos, `WhenUnlocked*` falla con `-25308`
    ///    (`errSecInteractionNotAllowed`): macOS no da esa clase a este proceso. La que funciona y
    ///    sigue siendo de la familia **sin respaldo y sin sincronización** es
    ///    `AfterFirstUnlockThisDeviceOnly`.
    ///
    /// Lo que se pierde y lo que no, dicho sin adornos: de los tres defectos, el respaldo y la
    /// sincronización se van **enteros** (es `ThisDeviceOnly`). El tercero —«se lee sin desbloquear
    /// nada»— se queda a medias: hace falta **un** desbloqueo desde el arranque, no uno en el
    /// momento de leer. `UserDefaults` no pedía ninguno, así que sigue siendo estrictamente mejor,
    /// pero no es lo que el plan pedía y por eso está escrito aquí.
    ///
    /// Y hay un motivo de función, además del de medición, que apunta al mismo sitio: esta app es
    /// un asistente que corre mientras el usuario no está delante. Un elemento `WhenUnlocked` se
    /// volvería ilegible al bloquearse la pantalla y el navegador del i3 dejaría de funcionar a
    /// mitad de un turno, sin decir por qué.
    public static let claseDeAccesibilidad = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

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
        nuevo[kSecAttrAccessible as String] = Self.claseDeAccesibilidad
        return SecItemAdd(nuevo as CFDictionary, nil) == errSecSuccess
    }

    public func borrar(cuenta: String) {
        SecItemDelete(clave(cuenta) as CFDictionary)
    }
}

/// Un secreto del dispositivo que **vivía en `UserDefaults` y ahora vive en el llavero**, con la
/// migración que lo mueve y lo borra del sitio viejo.
///
/// POR QUÉ UN PROTOCOLO CON IMPLEMENTACIÓN POR OMISIÓN Y NO DOS COPIAS. La Tarea 6 escribió esta
/// lógica para el token del navegador y dejó anotado que servía igual para el token del servicio
/// de memoria, de dos formas posibles: «`TokenDeConducir` con otra `cuenta`, o mejor un `enum`
/// hermano sobre el mismo `AlmacenDeSecretos`». La Tarea 6b elige **el `enum` hermano**, y por un
/// motivo concreto de cada alternativa:
///
/// - Una sola `enum` con la `cuenta` como parámetro de cada llamada convierte el nombre de la
///   cuenta en algo que el llamante tiene que acordarse de pasar, y **pasar el equivocado no se
///   puede detectar**: `leer(cuenta: "memoryBearerToken")` desde el camino del navegador
///   compilaría y devolvería el token de memoria. Con dos `enum` el tipo lleva la cuenta dentro y
///   el error deja de existir.
/// - Dos copias del cuerpo de `migrar` serían **lo que no se puede probar**: la mutación que
///   borra el `defaults.removeObject` de una de las dos la mataría la prueba de esa, y la otra
///   copia podría divergir en silencio. La lógica está una sola vez, aquí.
///
/// Lo que cada conformidad aporta son los **dos** nombres que la distinguen: la `cuenta` dentro
/// del llavero y la `claveVieja` de `UserDefaults` de la que se migra. Nada más.
public protocol SecretoDelDispositivo {
    /// La cuenta dentro del llavero, bajo el servicio de `LlaveroDelSistema`.
    static var cuenta: String { get }
    /// La clave de `UserDefaults` donde este secreto vivía en claro. **Solo se lee para migrar y
    /// se borra**: nadie vuelve a escribir ahí.
    static var claveVieja: String { get }
}

extension SecretoDelDispositivo {
    /// El token, o la cadena vacía si no hay ninguno. **Solo lee el almacén**: no mira
    /// `UserDefaults` ni migra nada.
    ///
    /// POR QUÉ LEER NO MIGRA, y es una decisión medida, no de estilo. La primera versión migraba
    /// dentro de `leer`, y eso convertía cada lectura en una ESCRITURA sobre la configuración de
    /// verdad del usuario. Los lectores del token se alcanzan desde sitios que varias pruebas de
    /// esta suite llaman con `UserDefaults.standard` (el host de las pruebas es la propia app, así
    /// que su dominio es el del usuario): una corrida de la suite le habría movido el token a un
    /// almacén de pega y **se lo habría borrado del sitio viejo**, dejándole sin token. Separar
    /// las dos cosas quita la clase entera de accidente: leer no tiene efectos, y migrar se llama
    /// una vez, al arrancar y al abrir Ajustes.
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
        defaults.removeObject(forKey: claveVieja)
        return aceptado
    }

    /// Mueve el token del sitio viejo al almacén y **lo borra del sitio viejo**. Idempotente: a la
    /// segunda llamada ya no hay nada en `UserDefaults` y no hace nada.
    ///
    /// LAS DOS MITADES SON OBLIGATORIAS, Y LA SEGUNDA ES LA QUE SE OLVIDA. Si la migración mueve
    /// el token pero no borra el original, esto no arregla nada para el usuario que ya tiene el
    /// suyo guardado en claro: el fichero de preferencias sigue teniéndolo y ahora hay dos copias.
    ///
    /// 🔴 PERO EL ORIGEN SOLO SE BORRA CUANDO YA NO ES LA ÚNICA COPIA (ronda 8, hallazgo de la
    /// revisión adversarial de Codex). Antes `defaults.removeObject` corría **siempre**, también
    /// cuando el llavero rechazaba la escritura: un rechazo borraba el único token que había, los
    /// servicios se quedaban sin autenticación y el arranque siguiente ya no tenía nada que
    /// reintentar. Ahora se borra en exactamente tres casos:
    ///
    ///   1. lo que había estaba en blanco (no hay token que perder);
    ///   2. el almacén ya tenía un token (es más nuevo: al guardar se escribe primero el llavero);
    ///   3. la escritura devolvió `true` **y** leerlo de vuelta da **el mismo** valor.
    ///
    /// En cualquier otro caso el origen **se queda** y la función devuelve `false`: el arranque
    /// siguiente y la apertura de Ajustes, que vuelven a llamar aquí, lo reintentan. Es la misma
    /// regla que ya cumple `ClaveDeProveedor.migrar`, y por el mismo motivo: un llavero que dice
    /// «sí» al escribir y no devuelve nada al leer (medido en la Tarea 6 con el llavero de
    /// ficheros de macOS) no puede convertirse en un token perdido.
    ///
    /// DOS HUECOS QUE ESTO NO CIERRA, declarados:
    ///   - `leer` devuelve `nil` tanto si no hay elemento como si `SecItemCopyMatching` falla, y
    ///     `escribir` **borra primero** el elemento existente. Un error de lectura confundido con
    ///     ausencia puede llevar a escribir encima —y, si esa escritura falla, a dejar el llavero
    ///     sin el token bueno—, aunque el origen ya no se borra en ese caso.
    ///   - Un llavero que falla **siempre** deja el token en claro en `UserDefaults`
    ///     indefinidamente. Conservar la copia permite reintentar; no garantiza autenticación.
    ///
    /// Devuelve `true` solo si movió un token. Un `false` no distingue «no había nada», «ya
    /// estaba migrado» ni «no se pudo»; el último se distingue porque el origen sigue ahí.
    @discardableResult
    public static func migrar(almacen: any AlmacenDeSecretos = LlaveroDelSistema.compartido,
                              defaults: UserDefaults = .standard) -> Bool {
        guard let viejo = defaults.string(forKey: claveVieja) else { return false }
        let limpio = viejo.trimmingCharacters(in: .whitespacesAndNewlines)
        var movido = false
        // El almacén manda si ya tiene algo: lo que hay en el llavero es más nuevo que lo que
        // quedó en el sitio viejo, porque al guardar se escribe primero el llavero.
        if !limpio.isEmpty, almacen.leer(cuenta: cuenta) == nil {
            // Escribir y VERIFICAR leyendo de vuelta; si cualquiera de las dos falla, el origen
            // se queda intacto para el reintento. No se borra nada antes de saber que hay otra
            // copia buena.
            guard almacen.escribir(limpio, cuenta: cuenta),
                  almacen.leer(cuenta: cuenta) == limpio
            else { return false }
            movido = true
        }
        defaults.removeObject(forKey: claveVieja)
        return movido
    }
}

/// El token del servicio del navegador del i3: dónde vive y cómo se sale del sitio donde vivía.
///
/// POR QUÉ EXISTE ESTE FICHERO. Hasta ahora este token servía para **mirar** una pantalla, y vivía
/// en `UserDefaults` vía `@AppStorage`, en claro, mientras el campo de Ajustes se pintaba como
/// secreto (`esSecreto: true`). O sea: la interfaz decía la verdad y el almacén mentía, que es
/// peor que no decir nada, porque el usuario cree que está a salvo. Y es el token con el que el agente
/// conduce el navegador (`HTTPAgentBrowserInvoker`) y con el que el visor del panel abre el stream
/// (`BrowserRelayClient`).
///
/// LO QUE ESTE FICHERO NO HACE, y es a propósito:
///
/// - **No cambia por dónde viaja el token.** Hoy el visor *web* del relé se autentica con
///   `?token=` en la query; es una restricción aparte del spec, con una excepción firmada por el
///   usuario, y no se toca aquí. Medido en este cliente: los dos consumidores del token
///   (`HTTPAgentBrowserInvoker` y `BrowserRelayClient`) lo mandan en la cabecera `Authorization`
///   y **nunca** en la URL, así que la fuga que nombra esa excepción —«cualquier descripción de
///   error que imprima la URL imprime el token»— no es alcanzable desde la app nativa. Hay una
///   prueba que lo fija, para que no deje de ser verdad sin que nadie se entere.
public enum TokenDeConducir: SecretoDelDispositivo {
    /// La cuenta dentro del llavero. Coincide con el nombre de la clave vieja a propósito: es el
    /// mismo secreto, cambiado de sitio.
    public static let cuenta = "browserBearerToken"

    /// De dónde se migra. Ver `SettingsKeys.browserBearerToken`: ese sitio ya solo existe para
    /// que la migración lo vacíe.
    public static let claveVieja = SettingsKeys.browserBearerToken
}
