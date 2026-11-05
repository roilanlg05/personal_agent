import SwiftUI
import WebKit
import Combine

#if os(macOS)
import AppKit
typealias PlatformViewRepresentable = NSViewRepresentable
#else
import UIKit
typealias PlatformViewRepresentable = UIViewRepresentable
#endif

/// In-app WebKit login view and cURL/Cookie importer for Amazon A to Z.
///
/// Captures cookies and employee ID strictly in volatile memory.
/// Cookies are never written to disk, UserDefaults, or Keychain, and never exposed to the LLM.
final class AtoZWebViewController: ObservableObject {
    weak var webView: WKWebView?
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var currentURL: URL? = nil
    @Published var isLoading: Bool = false
    @Published var estimatedProgress: Double = 0.0

    var checkCookiesAction: (() -> Void)?

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
    func loadHome() {
        let req = URLRequest(url: AtoZConstants.loginURL)
        webView?.load(req)
    }
    func checkCookiesNow() {
        checkCookiesAction?()
    }
}

struct AtoZLoginSheet: View {
    @ObservedObject private var sessionManager = AtoZSessionManager.shared
    @Environment(\.dismiss) private var dismiss

    enum LoginTab: Int {
        case safari = 0
        case webview = 1
        case paste = 2
    }

    #if os(macOS)
    @State private var selectedTab: LoginTab = .paste
    #else
    @State private var selectedTab: LoginTab = .safari
    #endif

    @State private var isPollingSafari: Bool = false
    @State private var safariPollTimer: Task<Void, Never>? = nil

    @StateObject private var webController = AtoZWebViewController()
    @State private var statusText: String = "Inicia sesión en Amazon A to Z..."
    @State private var manualEmployeeId: String = ""
    @State private var showManualEmployeeInput: Bool = false
    @State private var capturedCookies: String = ""

    // Manual / cURL import states
    @State private var rawInputText: String = ""
    @State private var detectedCookie: String = ""
    @State private var detectedEmployeeId: String = ""
    @State private var tokenMetadata: AtoZTokenMetadata? = nil
    @State private var isVerifying: Bool = false
    @State private var verifyResult: String?
    @State private var verifyOK: Bool = false

    #if os(macOS)
    @ObservedObject private var browserAuth = AtoZBrowserAuthenticator.shared
    #endif

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Conectar Amazon A to Z")
                        .font(.headline)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cerrar") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()
            .background(.bar)

            Picker("Modo de conexión", selection: $selectedTab) {
                #if os(iOS)
                Text("Safari (Face ID)").tag(LoginTab.safari)
                Text("Navegador WebKit").tag(LoginTab.webview)
                Text("Pegar cURL").tag(LoginTab.paste)
                #else
                Text("Pegar cURL o Cookie").tag(LoginTab.paste)
                Text("Navegador Integrado").tag(LoginTab.webview)
                #endif
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            switch selectedTab {
            case .safari:
                safariLoginView
            case .paste:
                pasteImportView
            case .webview:
                inAppWebView
            }
        }
        #if os(macOS)
        .frame(minWidth: 700, minHeight: 650)
        #endif
        .onChange(of: sessionManager.isLoggedIn) { _, loggedIn in
            if loggedIn {
                dismiss()
            }
        }
        .onDisappear {
            safariPollTimer?.cancel()
            isPollingSafari = false
        }
        .onAppear {
            #if os(macOS)
            if hasLocalCookiesFile && rawInputText.isEmpty {
                loadLocalCookiesFile()
            } else {
                tryAutoReadClipboard()
            }
            #else
            tryAutoReadClipboard()
            #endif
            Task {
                if !sessionManager.isLoggedIn {
                    await sessionManager.syncSessionFromServer()
                    if let s = sessionManager.currentSession {
                        detectedCookie = s.cookie
                        detectedEmployeeId = s.employeeId
                        processPastedInput(s.cookie)
                    }
                }
            }
        }
    }

    // MARK: - Safari + Face ID Login View

    private var safariLoginView: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header Banner
                VStack(spacing: 12) {
                    Image(systemName: "safari.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.blue)

                    Text("Iniciar con Safari y Face ID")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("Safari tiene soporte nativo de iOS para Passkeys y Face ID de Amazon.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding(.top, 16)

                // How it works card
                VStack(alignment: .leading, spacing: 14) {
                    Text("CÓMO FUNCIONA")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.secondary)

                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "1.circle.fill")
                            .foregroundColor(.blue)
                        Text("Toca el botón **Abrir Safari** abajo para ir a Amazon A to Z.")
                            .font(.callout)
                    }

                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "2.circle.fill")
                            .foregroundColor(.blue)
                        Text("Inicia sesión normalmente con **Face ID** o tu **Passkey**.")
                            .font(.callout)
                    }

                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "3.circle.fill")
                            .foregroundColor(.blue)
                        Text("La extensión **Gemma A to Z Sync** detectará las cookies y las enviará al servidor automáticamente.")
                            .font(.callout)
                    }
                }
                .padding()
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(12)
                .padding(.horizontal)

                // Action Button
                VStack(spacing: 10) {
                    Button(action: openSafariAndPoll) {
                        HStack(spacing: 10) {
                            if isPollingSafari {
                                ProgressView()
                                    .tint(.white)
                                Text("Esperando inicio en Safari…")
                                    .fontWeight(.semibold)
                            } else {
                                Image(systemName: "arrow.up.forward.app.fill")
                                Text("Abrir Safari en Amazon A to Z")
                                    .fontWeight(.semibold)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isPollingSafari)

                    if isPollingSafari {
                        HStack(spacing: 8) {
                            Button("Comprobar ahora") {
                                Task {
                                    await sessionManager.syncSessionFromServer()
                                }
                            }
                            .buttonStyle(.bordered)

                            Button("Cancelar") {
                                safariPollTimer?.cancel()
                                isPollingSafari = false
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(.horizontal)

                if isPollingSafari {
                    Text("Gemma está consultando el servidor cada 2 segundos. Cuando termines en Safari, esta pantalla se cerrará automáticamente.")
                        .font(.caption)
                        .foregroundColor(.blue)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer(minLength: 20)
            }
        }
    }

    private func openSafariAndPoll() {
        isPollingSafari = true
        #if os(iOS)
        if let url = URL(string: "https://atoz.amazon.work/schedule") {
            UIApplication.shared.open(url)
        }
        #elseif os(macOS)
        if let url = URL(string: "https://atoz.amazon.work/schedule") {
            NSWorkspace.shared.open(url)
        }
        #endif

        safariPollTimer?.cancel()
        safariPollTimer = Task {
            for _ in 0..<60 {
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { break }
                await sessionManager.syncSessionFromServer()
                if sessionManager.isLoggedIn {
                    await MainActor.run {
                        isPollingSafari = false
                        statusText = "✅ ¡Sesión sincronizada con éxito!"
                        #if os(iOS)
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        #endif
                    }
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    await MainActor.run {
                        dismiss()
                    }
                    return
                }
            }
            await MainActor.run {
                isPollingSafari = false
            }
        }
    }

    // MARK: - cURL / Cookie Paste View

    private var pasteImportView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                #if os(macOS)
                // 1-Click Browser Authentication with Passkey
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "globe.badge.chevron.backward")
                            .foregroundColor(.blue)
                            .font(.title2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Inicio de sesión automático con Navegador")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Text("Abre Firefox o Chrome directamente desde Gemma para usar tu Passkey y capturar la sesión sin usar la terminal.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if browserAuth.isRunning {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Button("Cancelar") {
                                    browserAuth.cancel()
                                }
                                .buttonStyle(.bordered)
                            }
                        } else {
                            Button(action: {
                                browserAuth.startBrowserLogin {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                        dismiss()
                                    }
                                }
                            }) {
                                Label("Abrir Navegador", systemImage: "arrow.up.forward.app.fill")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }

                    if !browserAuth.statusMessage.isEmpty {
                        Text(browserAuth.statusMessage)
                            .font(.caption)
                            .foregroundColor(browserAuth.statusMessage.contains("✅") ? .green : .blue)
                            .fontWeight(browserAuth.statusMessage.contains("✅") ? .semibold : .regular)
                    }
                }
                .padding()
                .background(Color.blue.opacity(0.08))
                .cornerRadius(10)
                #endif

                // Info banner explaining the Passkey situation
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "key.fill")
                        .foregroundColor(.blue)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Cómo conectar con Passkey:")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Text("Como Amazon A to Z exige Passkey, inicia sesión en tu navegador habitual (Safari, Chrome o Firefox). Luego copia cualquier petición de A to Z como cURL (o copia la Cookie) y pégala aquí:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding()
                .background(Color.blue.opacity(0.08))
                .cornerRadius(8)

                HStack(spacing: 10) {
                    Button(action: openInSafari) {
                        Label("Abrir A to Z en Safari", systemImage: "safari")
                    }
                    .buttonStyle(.bordered)

                    Button(action: readClipboard) {
                        Label("Pegar del Portapapeles", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.borderedProminent)

                    #if os(macOS)
                    if hasLocalCookiesFile {
                        Button(action: loadLocalCookiesFile) {
                            Label("Cargar cookies.json", systemImage: "arrow.triangle.2.circlepath.doc.on.clipboard")
                        }
                        .buttonStyle(.bordered)
                    }
                    #endif

                    Button(action: {
                        Task {
                            await sessionManager.syncSessionFromServer()
                            if let s = sessionManager.currentSession {
                                detectedCookie = s.cookie
                                detectedEmployeeId = s.employeeId
                                processPastedInput(s.cookie)
                            }
                        }
                    }) {
                        if sessionManager.isSyncing {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Obtener del Servidor", systemImage: "arrow.triangle.2.circlepath.icloud")
                        }
                    }
                    .buttonStyle(.bordered)
                }

                if let syncMsg = sessionManager.syncStatusMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "icloud.fill")
                            .foregroundColor(.blue)
                        Text(syncMsg)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Pega aquí el comando cURL completo, o el header Cookie:")
                        .font(.caption)
                        .fontWeight(.medium)

                    TextEditor(text: $rawInputText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 120, maxHeight: 180)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                        .onChange(of: rawInputText) { _, newVal in
                            processPastedInput(newVal)
                        }
                }

                // Extracted values preview
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("ID de empleado:")
                            .font(.caption)
                            .frame(width: 110, alignment: .leading)
                        TextField("ej. 204193941", text: $detectedEmployeeId)
                            .textFieldStyle(.roundedBorder)
                    }

                    if let meta = tokenMetadata {
                        HStack(alignment: .top) {
                            Text("Estado del token:")
                                .font(.caption)
                                .frame(width: 110, alignment: .leading)
                            Text(meta.statusMessage)
                                .font(.caption)
                                .foregroundColor(meta.isExpired ? .red : .green)
                                .fontWeight(meta.isExpired ? .semibold : .regular)
                        }
                    }

                    HStack {
                        Text("Cookie detectada:")
                            .font(.caption)
                            .frame(width: 110, alignment: .leading)
                        if detectedCookie.isEmpty {
                            Text("Ninguna cookie detectada aún")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            let names = AtoZSessionParser.cookieNames(detectedCookie)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(names.count) cookies (\(detectedCookie.count) caracteres)")
                                    .font(.caption)
                                    .foregroundColor(.green)
                                // Names only — values are never displayed.
                                Text(names.joined(separator: ", "))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                if !names.contains(where: { $0.hasPrefix("atoz-oauth-token") || $0.hasPrefix("atoz-auth") }) {
                                    Text("⚠️ No veo cookies atoz-oauth-token / atoz-auth-session. Copia una petición a atoz-apps.amazon.work (ScheduleManagementAssociateGateway).")
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                }
                            }
                        }
                    }
                }
                .padding()
                .background(Color.secondary.opacity(0.06))
                .cornerRadius(8)

                Button(action: saveManualSession) {
                    HStack {
                        Spacer()
                        if isVerifying { ProgressView().controlSize(.small) }
                        Text(isVerifying ? "Verificando con A to Z…" : "Guardar y Verificar Sesión")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isVerifying || detectedCookie.isEmpty || detectedEmployeeId.trimmingCharacters(in: .whitespaces).isEmpty || (tokenMetadata?.isExpired == true))

                if let verifyResult {
                    Text(verifyResult)
                        .font(.caption)
                        .foregroundColor(verifyOK ? .green : .red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }

                Text("Esta sesión vivirá únicamente en la memoria RAM de Gemma y se eliminará al cerrar la app.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding()
        }
    }

    // MARK: - In-App WebView View

    private var inAppWebView: some View {
        VStack(spacing: 0) {
            // Browser toolbar
            HStack(spacing: 12) {
                Button(action: { webController.goBack() }) {
                    Image(systemName: "chevron.backward")
                }
                .disabled(!webController.canGoBack)

                Button(action: { webController.goForward() }) {
                    Image(systemName: "chevron.forward")
                }
                .disabled(!webController.canGoForward)

                Button(action: { webController.reload() }) {
                    Image(systemName: "arrow.clockwise")
                }

                Button(action: { webController.loadHome() }) {
                    Image(systemName: "house")
                }

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundColor(.green)
                    Text(webController.currentURL?.host ?? "atoz.amazon.work")
                        .font(.caption)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)

                Spacer()

                Button(action: { webController.checkCookiesNow() }) {
                    Label("Detectar", systemImage: "sparkles")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.05))

            if webController.isLoading {
                ProgressView(value: webController.estimatedProgress)
                    .progressViewStyle(.linear)
            } else {
                Divider()
            }

            AtoZWebView(
                controller: webController,
                onStatusChange: { status in
                    statusText = status
                },
                onSessionCaptured: { cookie, empId in
                    #if os(iOS)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    #endif
                    if let empId, !empId.isEmpty {
                        sessionManager.setSession(cookie: cookie, employeeId: empId)
                        statusText = "✅ ¡Sesión capturada y sincronizada!"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            dismiss()
                        }
                    } else {
                        capturedCookies = cookie
                        showManualEmployeeInput = true
                        statusText = "Sesión detectada. Confirma tu ID de empleado:"
                    }
                }
            )

            if showManualEmployeeInput {
                Divider()
                HStack {
                    Text("ID de empleado:")
                        .font(.subheadline)
                    TextField("ej. 204193941", text: $manualEmployeeId)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                    Button("Guardar en memoria") {
                        let trimmed = manualEmployeeId.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty && !capturedCookies.isEmpty {
                            sessionManager.setSession(cookie: capturedCookies, employeeId: trimmed)
                            dismiss()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(manualEmployeeId.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding()
                .background(.background)
            }
        }
    }

    // MARK: - Actions

    private var hasLocalCookiesFile: Bool {
        #if os(macOS)
        let candidates = [
            FileManager.default.currentDirectoryPath + "/cookies.json",
            NSHomeDirectory() + "/Projects/personal_agent/cookies.json"
        ]
        for p in candidates {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: p)),
               let s = String(data: data, encoding: .utf8) {
                let meta = AtoZSessionParser.extractTokenMetadata(from: s)
                if meta != nil && meta?.isExpired == false {
                    return true
                }
            }
        }
        return false
        #else
        return false
        #endif
    }

    private func loadLocalCookiesFile() {
        #if os(macOS)
        let candidates = [
            FileManager.default.currentDirectoryPath + "/cookies.json",
            NSHomeDirectory() + "/Projects/personal_agent/cookies.json"
        ]
        for p in candidates {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: p)),
               let s = String(data: data, encoding: .utf8) {
                let meta = AtoZSessionParser.extractTokenMetadata(from: s)
                if meta != nil && meta?.isExpired == false {
                    rawInputText = s
                    processPastedInput(s)
                    break
                }
            }
        }
        #endif
    }

    private func openInSafari() {
        #if os(macOS)
        NSWorkspace.shared.open(AtoZConstants.loginURL)
        #else
        UIApplication.shared.open(AtoZConstants.loginURL)
        #endif
    }

    private func tryAutoReadClipboard() {
        let clip = getClipboardString()
        if clip.contains("atoz") || clip.contains("ScheduleManagement") || clip.contains("employeeId") {
            readClipboard()
        }
    }

    private func getClipboardString() -> String {
        #if os(macOS)
        return NSPasteboard.general.string(forType: .string) ?? ""
        #else
        return UIPasteboard.general.string ?? ""
        #endif
    }

    private func readClipboard() {
        let clip = getClipboardString()
        guard !clip.isEmpty else { return }
        rawInputText = clip
        processPastedInput(clip)
    }

    private func processPastedInput(_ text: String) {
        let (cookie, empId) = AtoZSessionParser.parse(text: text)
        self.detectedCookie = cookie ?? ""
        self.tokenMetadata = AtoZSessionParser.extractTokenMetadata(from: cookie ?? text)
        if let empId, !empId.isEmpty {
            self.detectedEmployeeId = empId
        } else if let sub = tokenMetadata?.employeeId, !sub.isEmpty {
            self.detectedEmployeeId = sub
        }
        verifyResult = nil
    }

    private func saveManualSession() {
        let c = detectedCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        let e = detectedEmployeeId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty && !e.isEmpty else { return }
        sessionManager.setSession(cookie: c, employeeId: e)
        isVerifying = true
        verifyResult = nil
        Task {
            // Single read-only query (no modification) to confirm Amazon accepts the session.
            do {
                let now = Date()
                let shifts = try await AtoZClient.shared.listAvailableShifts(start: now, end: now.addingTimeInterval(86400))
                verifyOK = true
                verifyResult = "✅ Sesión válida. A to Z respondió (\(shifts.count) oportunidades en las próximas 24 h)."
                isVerifying = false
                try? await Task.sleep(for: .seconds(1.2))
                dismiss()
            } catch let f as AtoZFailure {
                verifyOK = false
                isVerifying = false
                if f == .sessionExpired { sessionManager.clearSession() }
                verifyResult = "❌ " + f.userMessage
            } catch {
                verifyOK = false
                isVerifying = false
                verifyResult = "❌ Error de red: \(error.localizedDescription)"
            }
        }
    }
}

struct AtoZWebView: PlatformViewRepresentable {
    @ObservedObject var controller: AtoZWebViewController
    let onStatusChange: (String) -> Void
    let onSessionCaptured: (String, String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView {
        createWebView(context: context)
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
    #else
    func makeUIView(context: Context) -> WKWebView {
        createWebView(context: context)
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
    #endif

    private func createWebView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: .zero, configuration: config)

        #if os(macOS)
        let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15"
        webView.customUserAgent = ua
        #else
        let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Mobile/15E148 Safari/604.1"
        webView.customUserAgent = ua
        #endif

        if #available(iOS 16.4, macOS 13.3, *) {
            webView.isInspectable = true
        }

        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator

        context.coordinator.attach(webView: webView)
        controller.webView = webView
        let coord = context.coordinator
        controller.checkCookiesAction = { [weak coord] in
            coord?.checkCookiesNow()
        }

        let req = URLRequest(url: AtoZConstants.loginURL)
        webView.load(req)
        return webView
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
        let parent: AtoZWebView
        private var hasExtracted = false
        private weak var webView: WKWebView?
        private weak var cookieStore: WKHTTPCookieStore?
        private var progressObservation: NSKeyValueObservation?
        private var urlObservation: NSKeyValueObservation?
        private var loadingObservation: NSKeyValueObservation?
        private var detectedEmployeeId: String?

        init(_ parent: AtoZWebView) {
            self.parent = parent
        }

        deinit {
            cookieStore?.remove(self)
            progressObservation?.invalidate()
            urlObservation?.invalidate()
            loadingObservation?.invalidate()
        }

        func attach(webView: WKWebView) {
            self.webView = webView
            let store = webView.configuration.websiteDataStore.httpCookieStore
            self.cookieStore = store
            store.add(self)

            progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                DispatchQueue.main.async {
                    self?.parent.controller.estimatedProgress = wv.estimatedProgress
                }
            }
            urlObservation = webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
                DispatchQueue.main.async {
                    self?.parent.controller.currentURL = wv.url
                    self?.parent.controller.canGoBack = wv.canGoBack
                    self?.parent.controller.canGoForward = wv.canGoForward
                }
            }
            loadingObservation = webView.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
                DispatchQueue.main.async {
                    self?.parent.controller.isLoading = wv.isLoading
                }
            }
        }

        // MARK: - WKHTTPCookieStoreObserver

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            checkCookies(in: cookieStore)
        }

        func checkCookiesNow() {
            if let store = cookieStore {
                checkCookies(in: store)
            }
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.onStatusChange("Cargando página...")
            parent.controller.canGoBack = webView.canGoBack
            parent.controller.canGoForward = webView.canGoForward
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let url = webView.url else { return }
            parent.onStatusChange("Página cargada (\(url.host ?? ""))")
            parent.controller.canGoBack = webView.canGoBack
            parent.controller.canGoForward = webView.canGoForward

            let urlStr = url.absoluteString.lowercased()
            if urlStr.contains("atoz.amazon.work") || urlStr.contains("amazon.com") {
                if let store = cookieStore {
                    checkCookies(in: store)
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url {
                checkForEmployeeId(in: url.absoluteString)
            }
            decisionHandler(.allow)
        }

        // MARK: - WKUIDelegate

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            // Handle popups / window.open inline so Passkey or federation sheets don't get lost
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            completionHandler()
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            completionHandler(true)
        }

        // MARK: - Cookie and ID Extraction

        private func checkForEmployeeId(in str: String) {
            let pattern = #"(?:employeeId=|/apis/[^/]+/)([0-9]{6,12})"#
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: str, range: NSRange(str.startIndex..., in: str)),
               let range = Range(match.range(at: 1), in: str) {
                detectedEmployeeId = String(str[range])
            }
        }

        private func checkCookies(in cookieStore: WKHTTPCookieStore) {
            cookieStore.getAllCookies { [weak self] cookies in
                guard let self, !self.hasExtracted else { return }
                let relevantCookies = cookies.filter {
                    $0.domain.contains("amazon.work") || $0.domain.contains("amazon.com")
                }
                guard !relevantCookies.isEmpty else { return }

                let oauthCookie = relevantCookies.first { $0.name == "atoz-oauth-token" }
                let sessionCookie = relevantCookies.first { $0.name == "atoz_frl" || $0.name == "anonymous-session-id" || $0.name == "atoz-person-hint" }

                guard oauthCookie != nil || sessionCookie != nil else { return }

                let cookieHeader = relevantCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                let tokenMeta = AtoZSessionParser.extractTokenMetadata(from: cookieHeader)

                var empId = self.detectedEmployeeId
                if let metaEmp = tokenMeta?.employeeId, !metaEmp.isEmpty {
                    empId = metaEmp
                }
                if empId == nil || empId?.isEmpty == true {
                    empId = AtoZSessionParser.extractEmployeeId(cookieHeader, cookie: cookieHeader)
                }

                if let validEmp = empId, !validEmp.isEmpty, oauthCookie != nil {
                    self.hasExtracted = true
                    DispatchQueue.main.async {
                        self.parent.onSessionCaptured(cookieHeader, validEmp)
                    }
                } else if sessionCookie != nil && oauthCookie != nil {
                    self.webView?.evaluateJavaScript("""
                    (() => {
                        for (let i = 0; i < localStorage.length; i++) {
                            const val = localStorage.getItem(localStorage.key(i));
                            if (val && typeof val === 'string') {
                                const m = val.match(/["']?employeeId["']?\\s*:\\s*["']?([0-9]{6,12})["']?/);
                                if (m && m[1]) return m[1];
                            }
                        }
                        return null;
                    })()
                    """) { [weak self] result, _ in
                        guard let self, !self.hasExtracted else { return }
                        let jsEmp = result as? String ?? self.detectedEmployeeId
                        self.hasExtracted = true
                        DispatchQueue.main.async {
                            self.parent.onSessionCaptured(cookieHeader, jsEmp)
                        }
                    }
                }
            }
        }
    }
}
