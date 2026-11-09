import Foundation
import Security

/// El llavero VIEJO de las API keys de los proveedores de modelo: el que `KeychainStore` usaba
/// hasta la Tarea 6c. Existe por un único motivo —ser el **origen de la migración**— y por eso
/// solo sabe **leer y borrar**.
///
/// POR QUÉ ESTE FICHERO EXISTE EN VEZ DE HABER PARCHEADO `KeychainStore`. El almacén viejo tenía
/// tres defectos a la vez, y el tercero es el que convierte esto en una migración y no en un
/// parche:
///
/// 1. **Escribía una copia EN CLARO** de cada secreto en `UserDefaults`
///    (`keychain_fallback.<cuenta>`) y al leer **caía a esa copia**. O sea que el llavero era
///    decorativo: bastaba con que la consulta fallara para que la API key de pago del usuario
///    saliera de un fichero de preferencias sin cifrar, respaldado y sincronizado.
/// 2. **No pasaba `kSecUseDataProtectionKeychain`**, así que en macOS el elemento iba al llavero
///    de ficheros, que **no tiene clases de accesibilidad**: `kSecAttrAccessible` se ignoraba en
///    silencio y `SecItemAdd` devolvía éxito igual. Medido por la Tarea 6 y vuelto a medir aquí:
///    el `pdmn` del elemento guardado por este camino vale `nil`.
/// 3. **La clase que pedía no era `ThisDeviceOnly`** (`AfterFirstUnlock` a secas), así que en iOS
///    —donde el llavero con protección de datos es el único que hay y la clase **sí** se
///    aplica— esas API keys **entran en las copias de seguridad y se restauran en otro aparato**.
///
/// Y añadir la bandera del punto 2 **cambia de llavero**: las consultas dejan de ver lo ya
/// escrito en el de ficheros. Lo que pasaría con un parche es peor que un error visible: la
/// lectura no encontraría la key, caería a la copia en claro del punto 1, todo seguiría
/// funcionando, el usuario no notaría nada y **la migración de verdad no se haría nunca**. Por eso
/// el camino viejo se conserva aquí, intacto y aislado, hasta que la migración lo vacíe.
///
/// 🔴 **ESTE TIPO NO SABE ESCRIBIR, Y ES A PROPÓSITO.** Conforma `AlmacenSoloDeLectura`, no
/// `AlmacenDeSecretos`, así que **ningún camino de producción puede volver a guardar un secreto
/// en el sitio viejo**: no compila. La prueba que planta un elemento «como lo plantaba el código
/// viejo» lo hace con `SecItemAdd` a pelo, en su propio fichero y sobre un servicio propio de las
/// pruebas, nunca por aquí.
public struct LlaveroViejoDeApiKeys: AlmacenSoloDeLectura {
    /// El nombre del servicio del llavero que `KeychainStore` usaba. **No se puede tocar**: es el
    /// nombre con el que están escritas las keys que el usuario tiene guardadas hoy, y cambiarlo
    /// no rompería nada visible —simplemente no encontraría nada y la migración diría «no había
    /// nada»— que es el fallo silencioso que esta tarea existe para no cometer.
    public static let servicioDeLasApiKeys = "lambert-dev-group.Gemma.apiKeys"

    public static let compartido = LlaveroViejoDeApiKeys()

    private let servicio: String

    public init(servicio: String = LlaveroViejoDeApiKeys.servicioDeLasApiKeys) {
        self.servicio = servicio
    }

    /// Los atributos con los que `KeychainStore.query` identificaba el elemento, **copiados tal
    /// cual** (incluido el `kSecAttrAccessible` dentro de la consulta de búsqueda, que en el
    /// llavero de ficheros no filtra nada pero estaba ahí) y **sin**
    /// `kSecUseDataProtectionKeychain`, que es lo que hace que esta consulta mire el llavero de
    /// ficheros y encuentre lo que el código viejo escribió.
    ///
    /// Si esto se desvía de lo que escribió el código viejo, la migración no encuentra nada y no
    /// dice nada. Por eso hay una prueba que planta un elemento con la consulta del código viejo
    /// escrita a mano y comprueba que **este** tipo lo encuentra.
    private func clave(_ cuenta: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: servicio,
         kSecAttrAccount as String: cuenta,
         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
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

    public func borrar(cuenta: String) {
        SecItemDelete(clave(cuenta) as CFDictionary)
    }
}
