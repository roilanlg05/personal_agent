import Foundation
import Combine

#if os(macOS)
import AppKit

@MainActor
final class AtoZBrowserAuthenticator: ObservableObject {
    static let shared = AtoZBrowserAuthenticator()

    @Published var isRunning: Bool = false
    @Published var statusMessage: String = ""

    private var currentProcess: Process?

    func startBrowserLogin(onSuccess: (@Sendable () -> Void)? = nil) {
        guard !isRunning else { return }
        isRunning = true
        statusMessage = "Iniciando navegador (Firefox/Chrome)..."

        Task.detached {
            let venvPython = "/Users/hashdown/Projects/personal_agent/venv/bin/python"
            let scriptPath = "/Users/hashdown/Projects/personal_agent/amazon_scheduler.py"
            let cookieFilePath = "/Users/hashdown/Projects/personal_agent/cookies.json"

            guard FileManager.default.fileExists(atPath: venvPython),
                  FileManager.default.fileExists(atPath: scriptPath) else {
                await MainActor.run {
                    self.isRunning = false
                    self.statusMessage = "No se encontró el entorno Python o amazon_scheduler.py."
                }
                return
            }

            // Remove stale cookies.json so old credentials are never re-used accidentally
            try? FileManager.default.removeItem(atPath: cookieFilePath)

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: venvPython)
            proc.arguments = ["-u", scriptPath, "--auth-only"]
            proc.currentDirectoryURL = URL(fileURLWithPath: "/Users/hashdown/Projects/personal_agent")

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
            env["PYTHONUNBUFFERED"] = "1"
            proc.environment = env

            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe

            var accumulatedData = Data()
            let readHandle = pipe.fileHandleForReading
            readHandle.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty {
                    accumulatedData.append(chunk)
                }
            }

            await MainActor.run {
                self.currentProcess = proc
                self.statusMessage = "Navegador abierto. Inicia sesión en Amazon A to Z..."
            }

            do {
                try proc.run()
                proc.waitUntilExit()

                readHandle.readabilityHandler = nil
                let remaining = readHandle.readDataToEndOfFile()
                accumulatedData.append(remaining)

                let outputStr = String(data: accumulatedData, encoding: .utf8) ?? ""

                await MainActor.run {
                    self.isRunning = false

                    // 1. Check stdout delimited JSON
                    if let startRange = outputStr.range(of: "GEMMA_COOKIES_START"),
                       let endRange = outputStr.range(of: "GEMMA_COOKIES_END") {
                        let jsonStr = String(outputStr[startRange.upperBound..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                        let (cookie, empId) = AtoZSessionParser.parse(text: jsonStr)
                        if let c = cookie, let e = empId {
                            let meta = AtoZSessionParser.extractTokenMetadata(from: c)
                            if meta?.isExpired != true {
                                AtoZSessionManager.shared.setSession(cookie: c, employeeId: e)
                                self.statusMessage = "✅ ¡Nueva sesión capturada con éxito!"
                                onSuccess?()
                                return
                            }
                        }
                    }

                    // 2. Check newly written cookies.json (only if valid and not expired)
                    if FileManager.default.fileExists(atPath: cookieFilePath),
                       let data = try? Data(contentsOf: URL(fileURLWithPath: cookieFilePath)),
                       let s = String(data: data, encoding: .utf8) {
                        let (cookie, empId) = AtoZSessionParser.parse(text: s)
                        if let c = cookie, let e = empId {
                            let meta = AtoZSessionParser.extractTokenMetadata(from: c)
                            if meta?.isExpired != true {
                                AtoZSessionManager.shared.setSession(cookie: c, employeeId: e)
                                self.statusMessage = "✅ ¡Nueva sesión capturada con éxito!"
                                onSuccess?()
                                return
                            }
                        }
                    }

                    self.statusMessage = "El navegador se cerró sin completar el inicio de sesión."
                }
            } catch {
                readHandle.readabilityHandler = nil
                await MainActor.run {
                    self.isRunning = false
                    self.statusMessage = "Error al lanzar el navegador: \(error.localizedDescription)"
                }
            }
        }
    }

    func cancel() {
        currentProcess?.terminate()
        currentProcess = nil
        isRunning = false
        statusMessage = "Inicio de sesión cancelado."
    }
}
#endif
