import Foundation

/// Atajos que Gemma conoce de salida.
///
/// Existe porque en iOS no hay API para enumerar los atajos del usuario: sin esta
/// siembra, el modelo tendría que adivinar nombres, y un nombre con una mayúscula
/// distinta es un atajo que no se ejecuta. Fue lo que hizo fallar la primera prueba de
/// `Paga mi tarjeta de chase`.
///
/// La siembra se aplica una sola vez por dispositivo. Después manda el registro: lo que
/// el usuario enseñe o corrija no se sobrescribe en el siguiente arranque.
public enum ShortcutSeed {

    /// Nombre exacto, propósito y sensibilidad de los atajos ya existentes.
    ///
    /// Los nombres vienen de `shortcuts list` en el Mac del usuario, y iCloud los
    /// sincroniza con el iPhone, así que sirven en ambas plataformas.
    public static let entries: [ShortcutEntry] = [
        ShortcutEntry(
            name: "Create Note",
            purpose: "Crea una nota en Notas de Apple. Atención: este atajo pregunta el texto por pantalla, así que ignora el que se le pase.",
            inputDescription: nil,
            outputDescription: nil
        ),
        ShortcutEntry(
            name: "Nueva nota con fecha",
            purpose: "Crea una nota en Notas encabezada con la fecha de hoy.",
            inputDescription: "Texto de la nota",
            outputDescription: nil
        ),
        ShortcutEntry(
            name: "Add File to Note",
            purpose: "Añade un archivo a una nota existente.",
            inputDescription: "Archivo a adjuntar"
        ),
        ShortcutEntry(
            name: "Total de ventas de hoy",
            purpose: "Consulta el total de ventas del día.",
            outputDescription: "Importe total de ventas de hoy"
        ),
        ShortcutEntry(
            name: "Total de ventas de esta semana",
            purpose: "Consulta el total de ventas de la semana en curso.",
            outputDescription: "Importe total de ventas de la semana"
        ),
        ShortcutEntry(
            name: "Total de visitantes en hoy",
            purpose: "Consulta cuántos visitantes ha habido hoy.",
            outputDescription: "Número de visitantes de hoy"
        ),
        ShortcutEntry(
            name: "Paga mi tarjeta de chase",
            purpose: "Paga la tarjeta de crédito de Chase.",
            isSensitive: true
        ),
        ShortcutEntry(
            name: "Open Song",
            purpose: "Abre una canción.",
            inputDescription: "Nombre de la canción"
        ),
        ShortcutEntry(
            name: "Atajo de Shazam",
            purpose: "Identifica la canción que está sonando con Shazam.",
            outputDescription: "Título y artista de la canción reconocida"
        ),
        ShortcutEntry(
            name: "Oye Siri abre Uber para comenzar",
            purpose: "Abre Uber para pedir un viaje."
        ),
        ShortcutEntry(
            name: "Pídeme un café de caramelo",
            purpose: "Pide un café de caramelo.",
            isSensitive: true
        ),
        ShortcutEntry(
            name: "Open TikTok Inbox",
            purpose: "Abre la bandeja de entrada de TikTok."
        ),
        ShortcutEntry(
            name: "enciende la cámara",
            purpose: "Enciende la cámara de vigilancia."
        ),
        ShortcutEntry(
            name: "apaga la cámara",
            purpose: "Apaga la cámara de vigilancia."
        ),
        ShortcutEntry(
            name: "Muéstrame la cámara",
            purpose: "Muestra la imagen de la cámara de vigilancia."
        ),
        ShortcutEntry(
            name: "Enviar última imagen por mensaje",
            purpose: "Envía la última foto del carrete por mensaje.",
            isSensitive: true
        ),
        ShortcutEntry(
            name: "Mostrar capturas de pantalla",
            purpose: "Muestra las capturas de pantalla recientes."
        ),
        ShortcutEntry(
            name: "Tomar un descanso",
            purpose: "Inicia una pausa."
        )
    ]

    private static let appliedKey = "gemma.shortcuts.seed.applied.v1"

    /// Siembra el registro si no se había hecho. Devuelve cuántas fichas añadió.
    ///
    /// No pisa lo que ya exista: si el usuario corrigió un propósito o marcó algo como
    /// sensible, su versión gana.
    @discardableResult
    public static func apply(to registry: ShortcutRegistry, defaults: UserDefaults = .standard) -> Int {
        guard !defaults.bool(forKey: appliedKey) else { return 0 }

        var added = 0
        for entry in entries where registry.entry(named: entry.name) == nil {
            registry.remember(entry)
            added += 1
        }
        defaults.set(true, forKey: appliedKey)
        return added
    }
}
