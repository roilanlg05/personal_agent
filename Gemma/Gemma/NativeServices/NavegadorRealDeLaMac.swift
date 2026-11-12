import Foundation

#if os(macOS)

/// Un navegador REAL (no el de pruebas de `agent-browser`) que la app abre y cierra por el agente.
///
/// POR QUÉ EXISTE. El Chrome que lanza `agent-browser` por su cuenta lleva banderas de
/// automatización (`--enable-automation`, `navigator.webdriver == true`) y Google no deja iniciar
/// sesión en él. Un Chrome lanzado a mano, con un perfil propio y un puerto de depuración, se ve
/// como un Chrome normal (medido el 2026-11-11: `webdriver == false`, 5 plugins, y el inicio de
/// sesión con Google funcionó). `agent-browser` se conecta a ese Chrome por CDP.
///
/// Para el agente todo esto es invisible: solo llama a `browser_open` y `browser_close`. Esta
/// pieza es la que abre el Chrome antes del primer `open` y lo cierra tras el `close`.
public protocol NavegadorReal: Sendable {
    /// Puerto de depuración (CDP) al que tiene que conectarse `agent-browser`.
    var puertoCDP: Int { get }
    /// Deja el navegador listo: si ya contesta no hace nada, si no lo abre y espera a que conteste.
    func asegura() async -> Result<Void, AgentBrowserInvocationFailure>
    /// Cierra el navegador SI LO ABRIÓ ESTA APP. Uno que ya estaba abierto (el del usuario) no se toca.
    func cierra() async
}

public final class ChromeRealDeLaMac: NavegadorReal, @unchecked Sendable {
    public static let rutaDeChrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    public static let puertoPorDefecto = 9222

    public let puertoCDP: Int
    private let rutaDeChrome: String
    private let perfil: URL
    private let espera: TimeInterval
    private let lock = NSLock()
    private var lanzado: Process?

    public init(puerto: Int = ChromeRealDeLaMac.puertoPorDefecto,
                rutaDeChrome: String = ChromeRealDeLaMac.rutaDeChrome,
                perfil: URL = ChromeRealDeLaMac.perfilPorDefecto,
                espera: TimeInterval = 20) {
        self.puertoCDP = puerto
        self.rutaDeChrome = rutaDeChrome
        self.perfil = perfil
        self.espera = espera
    }

    /// `~/Library/Application Support/Gemma/chrome-real`: el perfil persistente con las sesiones.
    public static var perfilPorDefecto: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Gemma/chrome-real", isDirectory: true)
    }

    /// Las banderas con las que se lanza. NINGUNA es de automatización, y es a propósito.
    /// `--remote-debugging-address=127.0.0.1`: el CDP sin autenticación da control total del
    /// navegador, así que no se abre a la red.
    static func argumentos(puerto: Int, perfil: URL) -> [String] {
        ["--remote-debugging-port=\(puerto)",
         "--remote-debugging-address=127.0.0.1",
         "--user-data-dir=\(perfil.path)",
         "--no-first-run",
         "--no-default-browser-check"]
    }

    public func asegura() async -> Result<Void, AgentBrowserInvocationFailure> {
        if await contesta() { return .success(()) }
        guard FileManager.default.isExecutableFile(atPath: rutaDeChrome) else {
            return .failure(.launchFailed("No encuentro Google Chrome en \(rutaDeChrome)."))
        }
        try? FileManager.default.createDirectory(at: perfil, withIntermediateDirectories: true)
        let proceso = Process()
        proceso.executableURL = URL(fileURLWithPath: rutaDeChrome)
        proceso.arguments = Self.argumentos(puerto: puertoCDP, perfil: perfil)
        proceso.standardOutput = FileHandle.nullDevice
        proceso.standardError = FileHandle.nullDevice
        do { try proceso.run() } catch {
            return .failure(.launchFailed("No pude abrir Google Chrome: \(error.localizedDescription)"))
        }
        lock.lock(); lanzado = proceso; lock.unlock()

        let limite = ContinuousClock.now + .seconds(espera)
        while ContinuousClock.now < limite {
            if await contesta() { return .success(()) }
            // Chrome con el perfil YA abierto (otra instancia) cede el control a esa y sale: el
            // proceso nuestro muere, pero si el puerto contesta, el navegador está listo igual.
            if !proceso.isRunning {
                if await contesta() { return .success(()) }
                break
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return .failure(.launchFailed("Google Chrome se abrió pero no contesta en el puerto \(puertoCDP)."))
    }

    public func cierra() async {
        lock.lock(); let proceso = lanzado; lanzado = nil; lock.unlock()
        guard let proceso, proceso.isRunning else { return }
        proceso.terminate()   // SIGTERM: Chrome cierra limpio y guarda el perfil
        let limite = ContinuousClock.now + .seconds(5)
        while proceso.isRunning, ContinuousClock.now < limite {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func contesta() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(puertoCDP)/json/version") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 1
        guard let (_, resp) = try? await URLSession(configuration: cfg).data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// El subcomando de una llamada a `agent-browser`: lo primero que no es `--session <nombre>`.
    /// Las herramientas construyen `["--session", s, "open", url, "--json"]`.
    static func subcomando(de argumentos: [String]) -> String? {
        var i = 0
        while i < argumentos.count {
            if argumentos[i] == "--session" { i += 2; continue }
            return argumentos[i]
        }
        return nil
    }
}

#endif
