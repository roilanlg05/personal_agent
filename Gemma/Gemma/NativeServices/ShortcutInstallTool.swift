import Foundation

/// Un atajo que Gemma puede ofrecer instalar con un toque.
public struct ShortcutInstallOption: Sendable, Equatable {
    /// Nombre exacto con el que quedará en la app Atajos.
    public let name: String
    public let purpose: String
    /// Nombre del `.shortcut` firmado que viaja dentro de la app, si viaja.
    public let bundledFile: String?
    /// Enlace iCloud del atajo, si lo hay. Alternativa al fichero del bundle.
    public let link: URL?

    public init(name: String, purpose: String, bundledFile: String? = nil, link: URL? = nil) {
        self.name = name
        self.purpose = purpose
        self.bundledFile = bundledFile
        self.link = link
    }
}

/// Catálogo de atajos instalables de Gemma.
///
/// ## Por qué esto y no generar el atajo en código
///
/// No existe forma de que una app cree un atajo. Se comprobó contra la documentación de
/// Apple y contra el comportamiento real del sistema:
///
/// - **App Intents / AppShortcutsProvider** solo expone acciones *de la propia app*. No
///   puede componer un atajo con acciones del sistema como "Enviar mensaje".
/// - **Firmar** un `.shortcut` es obligatorio desde iOS 15 y solo se puede hacer en un
///   Mac (`shortcuts sign`), nunca en el dispositivo ni en tiempo de ejecución.
/// - **`shortcuts://import-shortcut?url=…`** rechaza cualquier URL que no sea un enlace
///   `icloud.com/shortcuts/…`: un fichero servido por HTTPS propio da "the specified
///   shortcut URL is invalid".
///
/// Lo que sí funciona es firmar el atajo **una vez, fuera de la app**, y meterlo en el
/// bundle. Gemma se lo entrega al sistema, Atajos muestra su ficha y el usuario pulsa
/// "Añadir atajo". A partir de ahí el atajo es suyo y Gemma lo ejecuta siempre. El
/// enlace iCloud queda como segunda vía para atajos que no convenga empaquetar.
///
/// Añadir un atajo nuevo al catálogo es firmarlo, dejarlo en `NativeServices/Shortcuts/`
/// y añadir una línea aquí: ninguna otra pieza cambia.
public enum ShortcutInstallCatalog {
    /// El primer candidato fue un atajo para enviar mensajes sin confirmación. Se
    /// construyó, se firmó y se empaquetó, y se descartó: añadir el atajo cuesta al
    /// usuario los mismos toques que pulsar enviar en el compositor del sistema, así
    /// que no compraba nada. La maquinaria se queda para los atajos donde sí hay
    /// ganancia, como pedir un coche o consultar el saldo de una tarjeta.
    ///
    /// Mientras no entre el primero de esos, el catálogo lleva un atajo de prueba que
    /// solo muestra una notificación. Está para comprobar el mecanismo de instalación
    /// en un dispositivo real; se puede quitar borrando esta entrada y su fichero.
    public static let options: [ShortcutInstallOption] = [
        ShortcutInstallOption(
            name: "Prueba de Gemma",
            purpose: "Atajo de prueba: solo muestra una notificación. Sirve para comprobar que Gemma puede instalar atajos.",
            bundledFile: "Prueba de Gemma"
        )
    ]

    public static func option(named name: String) -> ShortcutInstallOption? {
        let key = ShortcutRegistry.normalize(name)
        return options.first { ShortcutRegistry.normalize($0.name) == key }
    }
}

/// Ofrece al usuario añadir un atajo del catálogo de Gemma.
public final class InstallShortcutTool: AgentTool, Sendable {
    public static let name = "install_shortcut"
    public static let description = """
    Añade al dispositivo del usuario un atajo del catálogo de Gemma: abre su ficha para \
    que la acepte. Úsala cuando otra herramienta devuelva 'install_required' o \
    'install_shortcut', o cuando el usuario pida algo que necesite un atajo que aún no \
    tiene. Lee 'status': 'install_presented' = se abrió la ficha; el atajo NO está \
    instalado todavía, así que dile los pasos de 'next_step', pregúntale si lo añadió y, \
    cuando confirme, guárdalo con remember_shortcut usando el 'name' exacto. \
    'not_in_catalog' = Gemma no puede instalar ese atajo: pídele al usuario que lo cree \
    él y guárdalo luego con remember_shortcut. 'failed' = el sistema no abrió la ficha. \
    Repítele al usuario el texto de 'next_step' tal cual.
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(
            name: "name",
            type: .string,
            description: "Nombre del atajo del catálogo a instalar",
            required: true
        )
    ]

    private let fileSharer: (any ShortcutFileSharing)?
    private let opener: any AppURLOpening
    private let catalog: [ShortcutInstallOption]
    /// Dónde está el `.shortcut` firmado de un atajo. Inyectable para las pruebas.
    private let locateFile: @Sendable (String) -> URL?

    public init(
        fileSharer: (any ShortcutFileSharing)? = ShortcutFileSharerFactory.make(),
        opener: any AppURLOpening = SystemAppURLOpener(),
        catalog: [ShortcutInstallOption] = ShortcutInstallCatalog.options,
        locateFile: @escaping @Sendable (String) -> URL? = { BundledShortcutFiles.url(named: $0) }
    ) {
        self.fileSharer = fileSharer
        self.opener = opener
        self.catalog = catalog
        self.locateFile = locateFile
    }

    public func run(argsJSON: String) async -> String {
        guard let requested = CreateNoteTool.parseString(named: "name", from: argsJSON),
              !requested.isEmpty else {
            return ToolJSONOutput.error("Se requiere 'name' con el nombre del atajo a instalar.")
        }

        let key = ShortcutRegistry.normalize(requested)
        guard let option = catalog.first(where: { ShortcutRegistry.normalize($0.name) == key }) else {
            return notInCatalog(requested: requested)
        }

        // El fichero firmado que viaja con la app es la vía normal: no depende de
        // iCloud ni de que un enlace siga vivo.
        if let fileName = option.bundledFile,
           let fileURL = locateFile(fileName),
           let fileSharer,
           await fileSharer.present(fileURL: fileURL) {
            return presented(option, method: "bundled_file")
        }

        // Para los atajos que no convenga empaquetar queda el enlace de iCloud.
        if let link = option.link, await opener.openURL(link) {
            return presented(option, method: "icloud_link")
        }

        return ToolJSONOutput.object([
            "status": "failed",
            "name": option.name,
            "message": "No se pudo abrir la ficha del atajo '\(option.name)' en este dispositivo."
        ])
    }

    /// Abrir la ficha no es instalar: instalar lo hace el usuario al pulsar. Decir lo
    /// contrario dejaría a Gemma ejecutando un atajo que no existe.
    private func presented(_ option: ShortcutInstallOption, method: String) -> String {
        let nextStep = method == "bundled_file"
            ? "En la hoja que acaba de salir, elige «Atajos» y luego pulsa «Añadir atajo»."
            : "En la ficha que acaba de salir, pulsa «Añadir atajo»."
        return ToolJSONOutput.object([
            "status": "install_presented",
            "name": option.name,
            "purpose": option.purpose,
            "method": method,
            "next_step": nextStep,
            "message": "Se abrió la ficha de '\(option.name)'. \(nextStep) Pregúntale al usuario cuando haya terminado y guárdalo con remember_shortcut."
        ])
    }

    private func notInCatalog(requested: String) -> String {
        ToolJSONOutput.object([
            "status": "not_in_catalog",
            "requested": requested,
            "available": catalog.map(\.name),
            "message": "Gemma no puede instalar '\(requested)'. Pídele al usuario que lo cree él en la app Atajos y guárdalo después con remember_shortcut."
        ])
    }
}

/// Lista lo que Gemma puede instalar, para que el modelo pueda ofrecerlo.
public final class ListInstallableShortcutsTool: AgentTool, Sendable {
    public static let name = "list_installable_shortcuts"
    public static let description = """
    Lista los atajos que Gemma puede añadir al dispositivo del usuario, con para qué \
    sirve cada uno. Úsala cuando el usuario pregunte qué le falta para que Gemma haga \
    algo, o antes de install_shortcut si no sabes el nombre exacto.
    """
    public static let parameters: [AgentToolParam] = []

    private let catalog: [ShortcutInstallOption]

    public init(catalog: [ShortcutInstallOption] = ShortcutInstallCatalog.options) {
        self.catalog = catalog
    }

    public func run(argsJSON: String) async -> String {
        ToolJSONOutput.object([
            "status": "ok",
            "count": catalog.count,
            "shortcuts": catalog.map { ["name": $0.name, "purpose": $0.purpose] },
            "message": catalog.isEmpty
                ? "Gemma todavía no trae ningún atajo instalable."
                : "\(catalog.count) atajos instalables."
        ])
    }
}
