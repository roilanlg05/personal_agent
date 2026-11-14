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
    /// Cierra el Chrome de NUESTRO perfil dedicado, lo haya abierto esta instancia de la app u
    /// otra (una anterior que murió o se reinstaló). Un Chrome de otro perfil (el del usuario)
    /// no se toca nunca. Devuelve si quedó cerrado DE VERDAD (el puerto ya no contesta): quien lo
    /// llama no puede decirle al usuario «cerrado» si esto devuelve `false`.
    func cierra() async -> Bool
}

/// Un proceso del sistema tal como lo ve la búsqueda: su pid y su `argv`.
public struct ProcesoDelSistema: Sendable, Equatable {
    public let pid: pid_t
    public let argumentos: [String]
    public init(pid: pid_t, argumentos: [String]) {
        self.pid = pid
        self.argumentos = argumentos
    }
}

/// Lista los procesos del usuario con sus argumentos usando `sysctl` (sin shell, sin `ps`, sin
/// interpolar rutas en ningún comando).
public enum ProcesosDelSistema {
    /// Todos los procesos del usuario actual cuyos argumentos se pueden leer. Los de otros
    /// usuarios, o los que mueren entre el listado y la lectura, simplemente no aparecen.
    public static func todos() -> [ProcesoDelSistema] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        var tam = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &tam, nil, 0) == 0, tam > 0 else { return [] }
        // Margen por si aparecen procesos entre las dos llamadas.
        let capacidad = tam / MemoryLayout<kinfo_proc>.stride + 16
        var lista = [kinfo_proc](repeating: kinfo_proc(), count: capacidad)
        tam = capacidad * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &lista, &tam, nil, 0) == 0 else { return [] }
        let n = tam / MemoryLayout<kinfo_proc>.stride
        return lista.prefix(n).compactMap { info in
            let pid = info.kp_proc.p_pid
            guard pid > 0, let args = argumentos(de: pid) else { return nil }
            return ProcesoDelSistema(pid: pid, argumentos: args)
        }
    }

    /// El `argv` de un proceso vía `KERN_PROCARGS2`, o `nil` si no se puede leer.
    static func argumentos(de pid: pid_t) -> [String]? {
        var mibMax: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argmax: Int32 = 0
        var tamMax = MemoryLayout<Int32>.size
        guard sysctl(&mibMax, 2, &argmax, &tamMax, nil, 0) == 0, argmax > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var buffer = [UInt8](repeating: 0, count: Int(argmax))
        var tam = buffer.count
        guard sysctl(&mib, 3, &buffer, &tam, nil, 0) == 0 else { return nil }
        return argumentos(deProcArgs2: Data(buffer.prefix(tam)))
    }

    /// Interpreta el búfer de `KERN_PROCARGS2`: `argc` (Int32), la ruta del ejecutable, relleno de
    /// NUL y después `argc` cadenas terminadas en NUL (luego viene el entorno, que se ignora).
    static func argumentos(deProcArgs2 datos: Data) -> [String]? {
        let bytes = [UInt8](datos)
        guard bytes.count >= 4 else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int32.self) }
        guard argc >= 0 else { return nil }
        var i = 4
        while i < bytes.count, bytes[i] != 0 { i += 1 }   // ruta del ejecutable
        while i < bytes.count, bytes[i] == 0 { i += 1 }   // relleno
        var args: [String] = []
        while args.count < Int(argc), i < bytes.count {
            let inicio = i
            while i < bytes.count, bytes[i] != 0 { i += 1 }
            args.append(String(decoding: bytes[inicio..<i], as: UTF8.self))
            i += 1
        }
        return args.count == Int(argc) ? args : nil
    }
}

public final class ChromeRealDeLaMac: NavegadorReal, @unchecked Sendable {
    public static let rutaDeChrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    public static let puertoPorDefecto = 9222

    public let puertoCDP: Int
    private let rutaDeChrome: String
    private let perfil: URL
    private let espera: TimeInterval
    private let esperaCierre: TimeInterval
    private let listaProcesos: @Sendable () -> [ProcesoDelSistema]
    private let senal: @Sendable (pid_t, Int32) -> Bool
    private let contestaPuerto: (@Sendable (Int) async -> Bool)?
    private let lock = NSLock()
    private var lanzado: Process?

    /// - Parameters:
    ///   - esperaCierre: cuánto se espera, tras el SIGTERM, a que el puerto deje de contestar.
    ///   - listaProcesos, senal, contestaPuerto: puntos de sustitución para las pruebas (que
    ///     nunca deben mandar señales a procesos reales del usuario). `contestaPuerto == nil`
    ///     usa la consulta HTTP real a `/json/version`.
    public init(puerto: Int = ChromeRealDeLaMac.puertoPorDefecto,
                rutaDeChrome: String = ChromeRealDeLaMac.rutaDeChrome,
                perfil: URL = ChromeRealDeLaMac.perfilPorDefecto,
                espera: TimeInterval = 20,
                esperaCierre: TimeInterval = 5,
                listaProcesos: @escaping @Sendable () -> [ProcesoDelSistema] = { ProcesosDelSistema.todos() },
                senal: @escaping @Sendable (pid_t, Int32) -> Bool = { kill($0, $1) == 0 },
                contestaPuerto: (@Sendable (Int) async -> Bool)? = nil) {
        self.puertoCDP = puerto
        self.rutaDeChrome = rutaDeChrome
        self.perfil = perfil
        self.espera = espera
        self.esperaCierre = esperaCierre
        self.listaProcesos = listaProcesos
        self.senal = senal
        self.contestaPuerto = contestaPuerto
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

    /// Los pids de los procesos RAÍZ de Chrome de este perfil: los que llevan
    /// `--user-data-dir=<perfil>` con la ruta EXACTA (se tolera una barra final) y ningún
    /// `--type=` (los ayudantes: renderer, gpu-process...). Un Chrome de otro perfil, uno cuya
    /// ruta solo EMPIEZA igual, o el Chrome normal sin `--user-data-dir`, no aparece.
    static func pidsRaiz(delPerfil perfil: URL, en procesos: [ProcesoDelSistema]) -> [pid_t] {
        let nuestro = sinBarraFinal(perfil.path)
        let prefijo = "--user-data-dir="
        return procesos.filter { p in
            guard !p.argumentos.contains(where: { $0.hasPrefix("--type=") }) else { return false }
            return p.argumentos.contains { arg in
                arg.hasPrefix(prefijo) && sinBarraFinal(String(arg.dropFirst(prefijo.count))) == nuestro
            }
        }.map(\.pid)
    }

    private static func sinBarraFinal(_ ruta: String) -> String {
        var r = ruta
        while r.count > 1, r.hasSuffix("/") { r.removeLast() }
        return r
    }

    /// POR QUÉ NO BASTA CON EL PROCESO PROPIO (síntoma medido el 2026-11-11): si el Chrome del
    /// perfil lo abrió otra instancia de la app (reinicio, reinstalación, una que murió),
    /// `asegura()` lo encontró contestando y no guardó proceso; el `cierra()` de antes no hacía
    /// nada y el agente decía «cerrado» con Chrome abierto. Ahora se busca por el perfil.
    public func cierra() async -> Bool {
        lock.lock(); let proceso = lanzado; lanzado = nil; lock.unlock()
        var propio: pid_t?
        if let proceso, proceso.isRunning {
            propio = proceso.processIdentifier
            proceso.terminate()   // SIGTERM: Chrome cierra limpio y guarda el perfil
        }
        for pid in Self.pidsRaiz(delPerfil: perfil, en: listaProcesos()) where pid != propio {
            _ = senal(pid, SIGTERM)
        }
        let limite = ContinuousClock.now + .milliseconds(Int(esperaCierre * 1000))
        while true {
            let propioVivo = proceso?.isRunning ?? false
            if !propioVivo, !(await contesta()) { return true }
            if ContinuousClock.now >= limite { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func contesta() async -> Bool {
        if let contestaPuerto { return await contestaPuerto(puertoCDP) }
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
