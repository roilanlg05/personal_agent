import Foundation

/// El token del servicio de memoria del i3: dónde vive y cómo se sale del sitio donde vivía.
///
/// POR QUÉ ES EL SECRETO QUE MÁS IMPORTA DE ESTA APP. El token del navegador (`TokenDeConducir`)
/// conduce un Chrome con la sesión de Google del usuario dentro. Éste es peor: con él se **lee y
/// se escribe la memoria personal entera** del usuario en el i3 —todas sus conversaciones, su
/// identidad, su agenda, sus contactos, sus tareas— y además el servicio de voz comparte el mismo
/// token, así que vale igual para el audio. Vivía en `UserDefaults` vía `@AppStorage`, en claro,
/// respaldado y sincronizado, mientras el campo de Ajustes se pintaba como secreto: la interfaz
/// decía la verdad y el almacén mentía.
///
/// Y había una segunda mitad del defecto, que es la que hacía urgente moverlo: su valor por
/// omisión era el **placeholder débil y conocido** `replace-me-with-a-long-random-string`, el
/// mismo que el `.env` del compose del i3 trae de fábrica. El usuario va a rotarlo a una cadena
/// larga y aleatoria, y ese valor nuevo no puede acabar en claro.
///
/// CÓMO SE REUSA LA TAREA 6 SIN DUPLICARLA. Toda la lógica —leer, guardar, migrar— vive una sola
/// vez, en `SecretoDelDispositivo` (`TokenDeConducir.swift`), sobre el mismo `AlmacenDeSecretos` y
/// el mismo `LlaveroDelSistema`, con la misma clase de accesibilidad
/// (`AfterFirstUnlockThisDeviceOnly` + `kSecAttrSynchronizable: false` +
/// `kSecUseDataProtectionKeychain: true`) y **sin `#if os(…)`**. Lo único propio de este token son
/// los dos nombres de abajo. Hay una prueba que lee la clase **del elemento guardado** bajo esta
/// cuenta, no el código que lo guarda, porque eso es lo que cazó el defecto de la Tarea 6:
/// `SecItemAdd` devolvía éxito ignorando la clase pedida y el secreto entraba en las copias de
/// seguridad con todo verde.
///
/// Comparte servicio del llavero con `TokenDeConducir` y se distingue por la `cuenta`. Eso es
/// deliberado: son dos secretos del mismo proceso con la misma clase de accesibilidad, y un
/// servicio por secreto solo multiplicaría los sitios donde algo puede derivar. Lo que **no** se
/// comparte es el servicio de `KeychainStore`, que escribe una copia en claro de todo lo que
/// guarda en `UserDefaults` (`keychain_fallback.<cuenta>`), que es justo el defecto que esto
/// arregla.
public enum TokenDeMemoria: SecretoDelDispositivo {
    /// La cuenta dentro del llavero. Coincide con el nombre de la clave vieja a propósito: es el
    /// mismo secreto, cambiado de sitio.
    public static let cuenta = "memoryBearerToken"

    /// De dónde se migra. Ver `SettingsKeys.memoryBearerToken`: ese sitio ya solo existe para que
    /// la migración lo vacíe.
    public static let claveVieja = SettingsKeys.memoryBearerToken
}
