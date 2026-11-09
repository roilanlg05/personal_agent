import Foundation

/// La API key de pago de un proveedor de modelo: dónde vive, y cómo se sale de los dos sitios
/// donde vivía.
///
/// QUÉ ES ESTE SECRETO. Es lo que el usuario paga. `apiKey.cerebras` es además la clave del
/// **proveedor de chat por omisión en macOS**, así que sin ella la app no contesta. Perder una
/// cuesta que el usuario la vuelva a pegar; perder las cuatro en silencio es el fallo que esta
/// tarea existe para no cometer.
///
/// LOS DOS SITIOS VIEJOS, Y POR QUÉ SON DOS. `KeychainStore` guardaba en el llavero de ficheros
/// (servicio `lambert-dev-group.Gemma.apiKeys`, sin `kSecUseDataProtectionKeychain`, con
/// `AfterFirstUnlock` a secas) **y además** escribía una copia en claro en `UserDefaults`
/// (`keychain_fallback.<cuenta>`) a la que la lectura caía. Así que el camino viejo son los dos, y
/// la migración tiene que mirar los dos. Los tres defectos están medidos y escritos en
/// `LlaveroViejoDeApiKeys`.
///
/// CÓMO SE REUSA LO QUE YA HABÍA. La escritura nueva va por `LlaveroDelSistema`, el mismo almacén
/// de las Tareas 6 y 6b, con la misma clase de accesibilidad
/// (`AfterFirstUnlockThisDeviceOnly` + `kSecAttrSynchronizable: false` +
/// `kSecUseDataProtectionKeychain: true`) y **sin `#if os(…)`**. No hay un almacén nuevo.
///
/// POR QUÉ LA CUENTA ES UN PARÁMETRO Y NO UN TIPO POR PROVEEDOR, QUE ES LO CONTRARIO DE LO QUE
/// DECIDIÓ LA TAREA 6b. La 6b descartó pasar la cuenta por parámetro porque allí la cuenta era un
/// **nombre fijo**: había dos secretos distintos, uno por servicio, y `leer(cuenta: "…")` con el
/// nombre del otro compilaba y devolvía el secreto equivocado. Aquí la cuenta **es un dato**: el
/// proveedor viene de un ajuste del usuario (`SettingsKeys.chatProvider`), cambia en tiempo de
/// ejecución y es el mismo secreto con distinto destinatario. Un `enum` por proveedor obligaría a
/// un `switch` en cada uno de los seis lectores y, peor, a tocar seis sitios cada vez que se añada
/// un proveedor, que es exactamente el sitio donde uno se queda olvidado. Lo que sí se fija con
/// pruebas es la **forma** de la cuenta y de la clave en claro, porque un nombre mal construido no
/// rompe nada visible: simplemente no encuentra la key, la migración dice «no había nada» y la del
/// usuario se queda en el sitio viejo.
enum ClaveDeProveedor {
    /// La cuenta dentro del llavero, construida a partir del proveedor. **Es el nombre con el que
    /// están escritas las keys que el usuario tiene guardadas hoy**, así que no se puede tocar.
    static func cuenta(_ proveedor: String) -> String { "apiKey.\(proveedor)" }

    /// La clave de `UserDefaults` donde `KeychainStore` dejaba la copia en claro. **Solo se lee
    /// para migrar y se borra**: nadie vuelve a escribir ahí, y la lectura normal no la mira.
    static func claveEnClaro(_ cuenta: String) -> String { "keychain_fallback.\(cuenta)" }

    /// Todos los proveedores que pueden tener key. Sale de `ModelProvider.Kind.allCases` a
    /// propósito: así un proveedor nuevo entra en la migración sin que nadie se acuerde de
    /// añadirlo a una lista. Los locales (`local`, `onDevice`) nunca tuvieron key y migrarlos es
    /// un no-op.
    static var todosLosProveedores: [String] { ModelProvider.Kind.allCases.map(\.rawValue) }

    /// La key del proveedor, o `nil` si no hay ninguna. **Solo lee el almacén nuevo.**
    ///
    /// 🔴 NO MIRA LA COPIA EN CLARO, y ésa es la mitad del arreglo que se puede perder sin que
    /// nada se ponga rojo. Mientras la lectura cayera a `keychain_fallback.<cuenta>`, todo
    /// funcionaría igual con el llavero cambiado debajo y **la migración de verdad no se haría
    /// nunca**: el usuario no notaría nada y sus keys seguirían en claro. El camino viejo solo
    /// existe dentro de `migrar`.
    ///
    /// Y **leer no migra**, por la misma razón medida en las Tareas 6 y 6b: los lectores se
    /// alcanzan desde sitios que las pruebas llaman con `UserDefaults.standard` (el host de las
    /// pruebas es la propia app, así que su dominio es el del usuario), y una lectura que escribe
    /// le movería las keys de verdad a un almacén de pega y se las borraría del sitio viejo.
    static func leer(proveedor: String,
                     almacen: any AlmacenDeSecretos = LlaveroDelSistema.compartido) -> String? {
        guard let bruto = almacen.leer(cuenta: cuenta(proveedor)) else { return nil }
        let limpio = bruto.trimmingCharacters(in: .whitespacesAndNewlines)
        return limpio.isEmpty ? nil : limpio
    }

    /// Guarda la key en el almacén nuevo y **se asegura de que no quede copia en claro**.
    ///
    /// Una key vacía es «no hay key»: se borra el elemento en vez de guardar una cadena vacía,
    /// para no dejar un secreto fantasma que haga creer al banner que hay key.
    ///
    /// Devuelve si el almacén aceptó la escritura. El borrado de la copia en claro es
    /// incondicional: dejarla «por si acaso» es exactamente el defecto que esto arregla.
    @discardableResult
    static func guardar(_ valor: String,
                        proveedor: String,
                        almacen: any AlmacenDeSecretos = LlaveroDelSistema.compartido,
                        defaults: UserDefaults = .standard) -> Bool {
        let nombre = cuenta(proveedor)
        let limpio = valor.trimmingCharacters(in: .whitespacesAndNewlines)
        let aceptado: Bool
        if limpio.isEmpty {
            almacen.borrar(cuenta: nombre)
            aceptado = true
        } else {
            aceptado = almacen.escribir(limpio, cuenta: nombre)
        }
        defaults.removeObject(forKey: claveEnClaro(nombre))
        return aceptado
    }

    /// Qué pasó al migrar una key. Importa que sean cinco casos y no un `Bool`: los dos últimos
    /// son «no se ha migrado **y el camino viejo sigue intacto**», que es lo que el usuario
    /// necesita que pase cuando el llavero nuevo dice no.
    enum Resultado: String, Equatable, Sendable {
        /// No había key en ninguno de los dos sitios viejos.
        case noHabiaNada
        /// Ya estaba en el almacén nuevo. Los sitios viejos se limpian igual.
        case yaEstaba
        /// Se movió, se verificó leyéndola de vuelta, y los sitios viejos quedaron vacíos.
        case migrada
        /// El almacén nuevo rechazó la escritura. **No se ha borrado nada.**
        case falloLaEscritura
        /// El almacén aceptó la escritura pero no devuelve el mismo valor al leerla de vuelta.
        /// **No se ha borrado nada.**
        case noSeLeyoDeVuelta
    }

    /// Mueve la key del camino viejo al almacén nuevo. Idempotente: a la segunda llamada ya está
    /// en el almacén nuevo y solo queda limpiar.
    ///
    /// 🔴 EL ORDEN NO ES NEGOCIABLE Y ES LO QUE PROTEGE LAS KEYS DEL USUARIO: leer del camino
    /// viejo → escribir por el nuevo → **verificar leyendo de vuelta** → y solo entonces borrar
    /// la copia en claro y el elemento viejo. Si la escritura nueva falla, o si lo que se lee de
    /// vuelta no es lo que se escribió, **no se borra nada**, el camino viejo se queda intacto y
    /// la función lo dice. Un borrado antes de la verificación convierte un llavero que dice no en
    /// una key perdida, y el usuario solo se enteraría al ver que el chat no contesta.
    ///
    /// EL LLAVERO VIEJO MANDA SOBRE LA COPIA EN CLARO cuando los dos tienen algo. No es
    /// arbitrario: `KeychainStore.get` prefería el llavero y solo caía a la copia si la consulta
    /// fallaba, así que respetar esa precedencia hace que la migración mueva **la key que la app
    /// estaba usando de verdad** y no una copia que pudiera haber quedado vieja.
    @discardableResult
    static func migrar(proveedor: String,
                       almacen: any AlmacenDeSecretos = LlaveroDelSistema.compartido,
                       viejo: any AlmacenSoloDeLectura = LlaveroViejoDeApiKeys.compartido,
                       defaults: UserDefaults = .standard) -> Resultado {
        let nombre = cuenta(proveedor)
        let enClaro = claveEnClaro(nombre)

        // Ya migrada: no se vuelve a escribir, pero los sitios viejos se vacían igual. Una copia
        // en claro que sobrevive «porque ya estaba migrada» es el mismo agujero.
        if almacen.leer(cuenta: nombre) != nil {
            defaults.removeObject(forKey: enClaro)
            viejo.borrar(cuenta: nombre)
            return .yaEstaba
        }

        let delLlaveroViejo = viejo.leer(cuenta: nombre)
        let deLaCopiaEnClaro = defaults.string(forKey: enClaro)
        guard let bruto = delLlaveroViejo ?? deLaCopiaEnClaro else { return .noHabiaNada }
        let limpio = bruto.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpio.isEmpty else {
            // Había algo y estaba en blanco: no hay key que mover, pero el sitio viejo se vacía.
            defaults.removeObject(forKey: enClaro)
            viejo.borrar(cuenta: nombre)
            return .noHabiaNada
        }

        guard almacen.escribir(limpio, cuenta: nombre) else { return .falloLaEscritura }
        guard almacen.leer(cuenta: nombre) == limpio else { return .noSeLeyoDeVuelta }

        defaults.removeObject(forKey: enClaro)
        viejo.borrar(cuenta: nombre)
        return .migrada
    }

    /// Migra las keys de todos los proveedores y devuelve qué pasó con cada una. Corre en cada
    /// arranque, **antes** de que se construya el `HarnessModel`, porque su `init` ya es uno de
    /// los lectores. Que corra siempre es lo que da el reintento: si un arranque no pudo escribir
    /// en el llavero, el camino viejo sigue intacto y el siguiente arranque lo vuelve a intentar.
    @discardableResult
    static func migrarTodas(proveedores: [String] = ClaveDeProveedor.todosLosProveedores,
                            almacen: any AlmacenDeSecretos = LlaveroDelSistema.compartido,
                            viejo: any AlmacenSoloDeLectura = LlaveroViejoDeApiKeys.compartido,
                            defaults: UserDefaults = .standard) -> [String: Resultado] {
        var resultados: [String: Resultado] = [:]
        for proveedor in proveedores {
            resultados[proveedor] = migrar(proveedor: proveedor, almacen: almacen,
                                           viejo: viejo, defaults: defaults)
        }
        return resultados
    }
}
