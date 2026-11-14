import Foundation

/// Lo que la bóveda dice de un secreto **sin decir el secreto**: el nombre con que el agente lo
/// pide, cómo se le enseña al usuario y la página a la que está atado. Es lo único que puede
/// llegar al modelo, a la interfaz de lista o a un log; el valor nunca viaja en este tipo.
public struct SecretoGuardado: Codable, Equatable, Sendable {
    public let name: String
    public let etiqueta: String
    public let origen: String

    public init(name: String, etiqueta: String, origen: String) {
        self.name = name
        self.etiqueta = etiqueta
        self.origen = origen
    }
}

/// La bóveda de secretos del agente: guarda contraseñas y claves por **nombre** para que el
/// modelo pueda usarlas (`browser_fill_secret`) sin verlas jamás.
///
/// POR QUÉ SOBRE `AlmacenDeSecretos` Y NO SOBRE EL LLAVERO. Es el mismo motivo que fijó
/// `TokenDeConducir`: la lógica que importa aquí (índice, reemplazo, atadura al origen) es lógica
/// de almacén, y se prueba contra un doble en memoria; las pruebas nunca tocan el Keychain real.
///
/// DISEÑO DE ALMACENAMIENTO. `AlmacenDeSecretos` solo sabe leer, escribir y borrar por cuenta; no
/// sabe listar. Por eso hay dos clases de cuenta:
///   - `secreto.<name>`: JSON `{value, etiqueta, origen}` de UN secreto;
///   - `indice`: JSON con la lista de nombres, para poder enumerar.
/// El índice es la ÚNICA forma de enumerar secretos, y por eso no se puede tratar un índice ilegible
/// como «vacío»: con este protocolo no se pueden escanear cuentas para reconstruirlo, así que
/// reescribirlo con solo el nombre nuevo dejaría los demás secretos en el Keychain pero fuera de
/// `lista()` (sin poder borrarlos) y, peor, fuera de `valoresActuales()`, de modo que el redactor
/// dejaría de enmascararlos y la contraseña podría filtrarse a logs o transcript. Se distingue
/// «no hay índice» (vacío legítimo) de «hay algo ilegible» (corrupción o fallo transitorio de
/// lectura, p. ej. Keychain bloqueado): en el segundo caso `guarda` se NIEGA y no toca nada.
/// Una entrada del índice cuyo secreto no se pueda decodificar se omite.
///
/// ATADURA AL ORIGEN. Cada secreto lleva el host de la página para la que se guardó. Sin esto, un
/// modelo engañado por una página maliciosa podría pedir «teclea gmail_pass» en `evil.com`. La
/// comparación vive en `origenPermite` y es estricta por diseño (ver allí).
public final class SecretVault: Sendable {
    /// Servicio del Keychain de la bóveda. Propio y distinto del de los tokens de dispositivo, para
    /// que un secreto del usuario y un token de la app nunca compartan espacio de cuentas.
    public static let servicioDelLlavero = "lambert-dev-group.Gemma.boveda"

    private static let cuentaDelIndice = "indice"
    private static let nombreValido = try! NSRegularExpression(pattern: "^[a-z0-9_]{1,40}$")

    private let almacen: any AlmacenDeSecretos
    /// El índice se actualiza leyendo y reescribiendo: dos `guarda` concurrentes pisarían uno al
    /// otro. La clase es `Sendable` y la usan el agente y la interfaz a la vez, así que se serializa.
    private let cerrojo = NSLock()

    public init(almacen: any AlmacenDeSecretos = LlaveroDelSistema(servicio: SecretVault.servicioDelLlavero)) {
        self.almacen = almacen
    }

    /// Lo que se escribe en la cuenta `secreto.<name>`. Privado: el valor no sale de esta clase
    /// salvo por `valor(de:)`.
    private struct Registro: Codable {
        let value: String
        let etiqueta: String
        let origen: String
    }

    /// Interno (no privado) para que `browser_fill_secret` valide el nombre con la MISMA regla
    /// antes de tocar la bóveda.
    static func esNombreValido(_ name: String) -> Bool {
        // `NSRegularExpression` con `^…$` deja pasar un salto de línea final ("a\n"), así que se
        // comprueba el rango entero en vez de buscar una coincidencia suelta.
        let rango = NSRange(name.startIndex..., in: name)
        guard let m = nombreValido.firstMatch(in: name, range: rango) else { return false }
        return m.range == rango && !name.contains("\n")
    }

    private static func cuenta(_ name: String) -> String { "secreto.\(name)" }

    // MARK: escritura

    /// Guarda (o reemplaza) un secreto. Devuelve `false` si el nombre no cumple la regla, si el
    /// valor está vacío o si el almacén rechaza la escritura.
    ///
    /// Un `false` es información, no cosmética: un llavero mal firmado acepta el diálogo y se
    /// traga el secreto. Quien llama debe decirle al usuario que NO se guardó.
    ///
    /// Orden: primero el secreto, luego el índice. Si el índice falla, se retira el secreto: un
    /// secreto fuera del índice sería invisible a `lista()` y no se podría borrar desde la interfaz.
    @discardableResult
    public func guarda(name: String, value: String, etiqueta: String, origen: String) -> Bool {
        guard Self.esNombreValido(name), !value.isEmpty else { return false }
        cerrojo.lock(); defer { cerrojo.unlock() }
        // Con el índice ilegible no se escribe NADA, ni siquiera el secreto: quedaría fuera del índice.
        guard leerIndice() != nil else { return false }

        guard let datos = try? JSONEncoder().encode(Registro(value: value, etiqueta: etiqueta, origen: origen)),
              let json = String(data: datos, encoding: .utf8),
              almacen.escribir(json, cuenta: Self.cuenta(name))
        else { return false }

        guard var nombres = leerIndice() else { return false }
        if !nombres.contains(name) {
            nombres.append(name)
            guard escribirIndice(nombres) else {
                // Si ya existía un secreto con ese nombre su valor viejo ya se perdió al
                // sobrescribir; en el caso común (nombre nuevo) esto deja el almacén como estaba.
                almacen.borrar(cuenta: Self.cuenta(name))
                return false
            }
        }
        return true
    }

    /// Quita el valor y el nombre del índice. Un nombre inválido o inexistente no hace nada.
    public func borra(name: String) {
        guard Self.esNombreValido(name) else { return }
        cerrojo.lock(); defer { cerrojo.unlock() }
        almacen.borrar(cuenta: Self.cuenta(name))
        // Índice ilegible: el valor ya se borró y el índice no se toca (no se puede reescribir sin perder nombres).
        if let nombres = leerIndice(), nombres.contains(name) { _ = escribirIndice(nombres.filter { $0 != name }) }
    }

    // MARK: lectura

    /// El valor en claro. Solo debe llamarlo quien TECLEA el secreto (`browser_fill_secret`) o
    /// quien lo necesita para redactarlo; nunca se devuelve al modelo.
    public func valor(de name: String) -> String? {
        registro(de: name)?.value
    }

    /// La página (host) a la que el secreto está atado.
    public func origen(de name: String) -> String? {
        registro(de: name)?.origen
    }

    /// ¿Se puede leer el índice? `true` si no existe (bóveda vacía) o se leyó bien; `false` si existe
    /// y está corrupto o no se pudo leer. Con `false` la bóveda no puede enumerar sus secretos: el
    /// redactor falla cerrado y quien guarda o teclea secretos debe negarse.
    public var indiceLegible: Bool {
        cerrojo.lock(); defer { cerrojo.unlock() }
        return leerIndice() != nil
    }

    /// Los secretos guardados, sin valores, en el orden en que se guardaron.
    public func lista() -> [SecretoGuardado] {
        cerrojo.lock(); defer { cerrojo.unlock() }
        return (leerIndice() ?? []).compactMap { name in
            registro(de: name).map { SecretoGuardado(name: name, etiqueta: $0.etiqueta, origen: $0.origen) }
        }
    }

    /// Todos los valores no vacíos, para el redactor que los tacha de transcripts y logs.
    public func valoresActuales() -> [String] {
        cerrojo.lock(); defer { cerrojo.unlock() }
        return (leerIndice() ?? []).compactMap { registro(de: $0)?.value }.filter { !$0.isEmpty }
    }

    // MARK: origen

    /// ¿Puede un secreto atado a `guardado` teclearse en la página `paginaActual`? Ambos son
    /// **hosts**, ya sin esquema.
    ///
    /// Permite el host igual o un subdominio real (`mail.google.com` para `google.com`). Se compara
    /// con el punto delante (`.google.com`) y no con un simple `hasSuffix("google.com")`: así
    /// `evilgoogle.com` no pasa. `google.com.evil.com` no pasa porque se exige que TERMINE en el
    /// origen, no que lo contenga. Y el padre no hereda del hijo.
    ///
    /// Se normaliza antes de comparar porque son diferencias que el navegador no considera
    /// distintas: mayúsculas (`Google.COM`), el punto final de un host absoluto (`google.com.`) y
    /// el puerto (`google.com:8443`). Un host vacío nunca autoriza nada: un origen vacío
    /// aceptaría cualquier página.
    public static func origenPermite(guardado: String, paginaActual: String) -> Bool {
        guard let g = normalizaHost(guardado), let p = normalizaHost(paginaActual) else { return false }
        return p == g || p.hasSuffix("." + g)
    }

    private static func normalizaHost(_ crudo: String) -> String? {
        var h = crudo.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Puerto: solo si lo que sigue a los dos puntos son dígitos (un host con otro ":" es basura
        // y se deja tal cual para que no coincida con nada).
        if let i = h.lastIndex(of: ":"), h[h.index(after: i)...].allSatisfy(\.isNumber) {
            h = String(h[..<i])
        }
        // Un solo punto final (host absoluto); más de uno dejaría una etiqueta vacía y se rechaza abajo.
        if h.hasSuffix(".") { h.removeLast() }
        // Juego de caracteres: ESTA es la defensa contra «evil.com/.google.com», «evil.com#.google.com»
        // o «evil.com\n.google.com», que terminan en «.google.com» sin ser un subdominio. Cada etiqueta
        // debe ser [a-z0-9-]+ (punycode «xn--» incluido) y no vacía. Si el llamador pasara una URL en
        // vez de un host, esto la rechaza en lugar de interpretarla.
        let etiquetas = h.split(separator: ".", omittingEmptySubsequences: false)
        let valido = !etiquetas.isEmpty && etiquetas.allSatisfy { e in
            !e.isEmpty && e.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
        }
        return valido ? h : nil
    }

    // MARK: internos

    private func registro(de name: String) -> Registro? {
        guard Self.esNombreValido(name),
              let json = almacen.leer(cuenta: Self.cuenta(name)),
              let r = try? JSONDecoder().decode(Registro.self, from: Data(json.utf8))
        else { return nil }
        return r
    }

    /// `[]` si no hay índice todavía; `nil` si existe pero no se puede leer como lista de nombres.
    private func leerIndice() -> [String]? {
        guard let json = almacen.leer(cuenta: Self.cuentaDelIndice) else { return [] }
        return try? JSONDecoder().decode([String].self, from: Data(json.utf8))
    }

    private func escribirIndice(_ nombres: [String]) -> Bool {
        guard let d = try? JSONEncoder().encode(nombres), let s = String(data: d, encoding: .utf8) else { return false }
        return almacen.escribir(s, cuenta: Self.cuentaDelIndice)
    }
}
