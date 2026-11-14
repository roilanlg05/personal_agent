import XCTest
@testable import Gemma

/// Abridor que decide por esquema, para distinguir la vía directa de Atajos del enlace
/// web de iCloud.
final class SchemeAwareOpener: AppURLOpening, @unchecked Sendable {
    /// Esquemas que este dispositivo acepta abrir.
    var openableSchemes: Set<String>
    private(set) var openedURLs: [URL] = []

    init(openableSchemes: Set<String>) {
        self.openableSchemes = openableSchemes
    }

    func canOpenURL(_ url: URL) async -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return openableSchemes.contains(scheme)
    }

    func openURL(_ url: URL) async -> Bool {
        guard let scheme = url.scheme?.lowercased(), openableSchemes.contains(scheme) else {
            return false
        }
        openedURLs.append(url)
        return true
    }
}

/// Instalar un atajo lo hace el usuario al aceptar la ficha. La herramienta solo la
/// abre, y no debe dar por hecho lo que todavía no ha pasado.
///
/// El catálogo real está vacío hoy, así que estas pruebas usan catálogos propios: lo que
/// se fija aquí es el mecanismo, para cuando entre el primer atajo que valga la pena.
final class ShortcutInstallToolTests: XCTestCase {

    private let link = URL(string: "https://www.icloud.com/shortcuts/0123456789abcdef")!
    private let fileURL = URL(fileURLWithPath: "/tmp/gemma-tests/Pedir un Uber.shortcut")

    private func uber(bundledFile: String? = "Pedir un Uber", link: URL? = nil) -> ShortcutInstallOption {
        ShortcutInstallOption(
            name: "Pedir un Uber",
            purpose: "Pide un coche a la dirección que le pases.",
            bundledFile: bundledFile,
            link: link
        )
    }

    private func json(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    }



    // MARK: - Vías de instalación




    func test_entregaElFicheroCuandoNoHayEnlaceICloud() async throws {
        let sharer = MockShortcutFileSharer()
        let tool = InstallShortcutTool(
            fileSharer: sharer,
            opener: SchemeAwareOpener(openableSchemes: ["shortcuts", "https"]),
            catalog: [uber()],
            locateFile: { [fileURL] _ in fileURL }
        )

        let result = try json(await tool.run(argsJSON: #"{"name": "Pedir un Uber"}"#))

        XCTAssertEqual(result["status"] as? String, "install_presented")
        XCTAssertEqual(result["method"] as? String, "bundled_file")
        XCTAssertEqual(sharer.presented, [fileURL])
    }

    func test_prefiereElFicheroAlEnlaceICloud() async throws {
        // El fichero no depende de que el enlace de iCloud siga vivo.
        let sharer = MockShortcutFileSharer()
        let opener = SchemeAwareOpener(openableSchemes: ["https"])
        let tool = InstallShortcutTool(
            fileSharer: sharer,
            opener: opener,
            catalog: [uber(link: link)],
            locateFile: { [fileURL] _ in fileURL }
        )

        let result = try json(await tool.run(argsJSON: #"{"name": "Pedir un Uber"}"#))

        XCTAssertEqual(result["method"] as? String, "bundled_file")
        XCTAssertEqual(sharer.presented, [fileURL])
        XCTAssertTrue(opener.openedURLs.isEmpty)
    }

    func test_caeAlEnlaceICloudSiLaHojaNoSeAbre() async throws {
        let opener = SchemeAwareOpener(openableSchemes: ["https"])
        let tool = InstallShortcutTool(
            fileSharer: MockShortcutFileSharer(shouldSucceed: false),
            opener: opener,
            catalog: [uber(link: link)],
            locateFile: { [fileURL] _ in fileURL }
        )

        let result = try json(await tool.run(argsJSON: #"{"name": "Pedir un Uber"}"#))

        XCTAssertEqual(result["method"] as? String, "icloud_link")
        XCTAssertEqual(opener.openedURLs.last, link)
        let next = try XCTUnwrap(result["next_step"] as? String)
        XCTAssertTrue(next.contains("Añadir atajo"))
    }

    // MARK: - Resolución de nombre y fallos

    func test_resuelveElNombreIgnorandoMayusculasYAcentos() async throws {
        let tool = InstallShortcutTool(
            fileSharer: MockShortcutFileSharer(),
            opener: SchemeAwareOpener(openableSchemes: ["shortcuts"]),
            catalog: [uber(link: link)],
            locateFile: { [fileURL] _ in fileURL }
        )

        let result = try json(await tool.run(argsJSON: #"{"name": "pedir un uber"}"#))
        XCTAssertEqual(result["status"] as? String, "install_presented")
    }

    func test_fallaCuandoNoQuedaNingunaVia() async throws {
        let tool = InstallShortcutTool(
            fileSharer: MockShortcutFileSharer(),
            opener: SchemeAwareOpener(openableSchemes: []),
            catalog: [uber(bundledFile: nil, link: link)],
            locateFile: { _ in nil }
        )

        let result = try json(await tool.run(argsJSON: #"{"name": "Pedir un Uber"}"#))
        XCTAssertEqual(result["status"] as? String, "failed")
    }

    func test_fueraDelCatalogoLoDiceYNoInventaNada() async throws {
        let tool = InstallShortcutTool(
            fileSharer: MockShortcutFileSharer(),
            opener: SchemeAwareOpener(openableSchemes: ["shortcuts", "https"]),
            catalog: [uber()],
            locateFile: { [fileURL] _ in fileURL }
        )

        let result = try json(await tool.run(argsJSON: #"{"name": "Pagar la hipoteca"}"#))

        XCTAssertEqual(result["status"] as? String, "not_in_catalog")
        XCTAssertEqual(result["available"] as? [String], ["Pedir un Uber"])
    }

    func test_exigeNombre() async throws {
        let tool = InstallShortcutTool(
            fileSharer: MockShortcutFileSharer(),
            opener: SchemeAwareOpener(openableSchemes: ["shortcuts"]),
            catalog: [uber()],
            locateFile: { _ in nil }
        )
        let out = await tool.run(argsJSON: "{}")
        XCTAssertNotNil(try json(out)["error"])
    }

    // MARK: - El catálogo real

    func test_todoEnlaceDelCatalogoRealEsDeICloud() {
        // El sistema solo acepta importar atajos desde icloud.com: un enlace propio
        // daría "shortcut URL is invalid" y el usuario se quedaría sin atajo.
        for option in ShortcutInstallCatalog.options {
            guard let link = option.link else { continue }
            XCTAssertEqual(link.host, "www.icloud.com", "Enlace inválido en '\(option.name)'")
            XCTAssertTrue(link.path.hasPrefix("/shortcuts/"), "Enlace inválido en '\(option.name)'")
        }
    }

    func test_todoFicheroDelCatalogoRealViajaEnElBundle() throws {
        // Un nombre de fichero mal escrito deja el atajo sin camino de instalación, y
        // el fallo solo saldría en el dispositivo del usuario.
        let bundle = Bundle(for: InstallShortcutTool.self)
        for option in ShortcutInstallCatalog.options {
            guard let fileName = option.bundledFile else { continue }
            XCTAssertNotNil(
                BundledShortcutFiles.url(named: fileName, bundle: bundle),
                "Falta '\(fileName).shortcut' en el bundle de la app."
            )
        }
    }

    // MARK: - Lista

    func test_listaDeInstalables() async throws {
        let tool = ListInstallableShortcutsTool(catalog: [uber()])
        let result = try json(await tool.run(argsJSON: "{}"))

        XCTAssertEqual(result["count"] as? Int, 1)
        let shortcuts = try XCTUnwrap(result["shortcuts"] as? [[String: Any]])
        XCTAssertEqual(shortcuts.first?["name"] as? String, "Pedir un Uber")
    }

    func test_listaVaciaLoDiceSinFingir() async throws {
        let out = await ListInstallableShortcutsTool(catalog: []).run(argsJSON: "{}")
        let result = try json(out)
        XCTAssertEqual(result["count"] as? Int, 0)
        XCTAssertEqual(result["shortcuts"] as? [[String: String]], [])
    }
}
