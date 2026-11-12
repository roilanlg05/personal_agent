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
/// El índice es solo un atajo para listar: si se corrompe, se trata como vacío y se reconstruye con
/// el siguiente `guarda`, y una entrada del índice cuyo secreto no se pueda decodificar se omite.
/// Nunca se lanza ni se devuelve basura.
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

    private static func esNombreValido(_ name: String) -> Bool {
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

        guard let datos = try? JSONEncoder().encode(Registro(value: value, etiqueta: etiqueta, origen: origen)),
              let json = String(data: datos, encoding: .utf8),
              almacen.escribir(json, cuenta: Self.cuenta(name))
        else { return false }

        var nombres = leerIndice()
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
        let nombres = leerIndice()
        if nombres.contains(name) { _ = escribirIndice(nombres.filter { $0 != name }) }
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

    /// Los secretos guardados, sin valores, en el orden en que se guardaron.
    public func lista() -> [SecretoGuardado] {
        cerrojo.lock(); defer { cerrojo.unlock() }
        return leerIndice().compactMap { name in
            registro(de: name).map { SecretoGuardado(name: name, etiqueta: $0.etiqueta, origen: $0.origen) }
        }
    }

    /// Todos los valores no vacíos, para el redactor que los tacha de transcripts y logs.
    public func valoresActuales() -> [String] {
        cerrojo.lock(); defer { cerrojo.unlock() }
        return leerIndice().compactMap { registro(de: $0)?.value }.filter { !$0.isEmpty }
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
        while h.hasSuffix(".") { h.removeLast() }
        return h.isEmpty ? nil : h
    }

    // MARK: internos

    private func registro(de name: String) -> Registro? {
        guard Self.esNombreValido(name),
              let json = almacen.leer(cuenta: Self.cuenta(name)),
              let r = try? JSONDecoder().decode(Registro.self, from: Data(json.utf8))
        else { return nil }
        return r
    }

    private func leerIndice() -> [String] {
        guard let json = almacen.leer(cuenta: Self.cuentaDelIndice),
              let nombres = try? JSONDecoder().decode([String].self, from: Data(json.utf8))
        else { return [] }
        return nombres
    }

    private func escribirIndice(_ nombres: [String]) -> Bool {
        guard let d = try? JSONEncoder().encode(nombres), let s = String(data: d, encoding: .utf8) else { return false }
        return almacen.escribir(s, cuenta: Self.cuentaDelIndice)
    }
}
