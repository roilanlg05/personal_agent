# In-App Voice Recorder (Gemma macOS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a microphone button to the Gemma macOS chat that records the user's speech, sends it to the i3 voice service (`POST /v1/voice/turn`), plays the spoken reply, and shows the transcript + reply inline in the chat.

**Architecture:** A self-contained `Gemma/Gemma/Voice/` module — `AudioRecorder` (16 kHz mono WAV via `AVAudioRecorder`), `VoiceClient` (multipart POST to the i3, mirrors `MemoryClient`), and a `@MainActor @Observable VoiceController` state machine (`idle→recording→sending→playing`). `HarnessModel` owns the controller and feeds it the current chat thread id + a log-append closure. A mic button in `AgentChatView.inputBar` drives `toggleRecording()`. Voice turns go through the i3 gateway brain; typed chat is unchanged.

**Tech Stack:** Swift 6, SwiftUI, AVFoundation (`AVAudioRecorder`/`AVAudioPlayer`), `URLSession` multipart. macOS 15 target. Xcode project uses **synchronized folders** (objectVersion 77) so new files under `Gemma/Gemma/…` and `GemmaTests/` auto-compile — **no `project.pbxproj` file-reference edits needed** (the only pbxproj edit is one build-setting key in Task 1).

**Repo / branch:** `Gemma` app repo (`/Users/hashdown/Projects/personal_agent/Gemma`). Create and work on branch `sp-voice-inapp`. The i3 backend is unchanged + already deployed.

**Spec:** `docs/superpowers/specs/2026-06-06-voice-in-app-recorder-design.md`.

**Build/test:** `xcodebuild -scheme Gemma -project Gemma.xcodeproj -destination 'platform=macOS' build` and `… test`. Focused tests: `xcodebuild test -scheme Gemma -destination 'platform=macOS' -only-testing:GemmaTests/<Suite>`. Known pre-existing failure `HarnessModelTests.test_defaultBaseURL` is unrelated — ignore it; no NEW failures allowed.

---

## File Structure

| File | Responsibility |
|---|---|
| `Gemma/Gemma/Voice/VoiceClient.swift` | `VoiceReply`, `VoiceError`, `VoiceTurning` protocol, `VoiceClient` (multipart POST → i3). |
| `Gemma/Gemma/Voice/AudioRecorder.swift` | `Recording` protocol + `AudioRecorder` (mic permission, 16 kHz mono WAV). |
| `Gemma/Gemma/Voice/VoiceController.swift` | `@MainActor @Observable` state machine + orchestration (record→send→append→play). |
| `Gemma/GemmaTests/VoiceClientTests.swift` | `VoiceClient` networking tests (URLProtocol stub). |
| `Gemma/GemmaTests/VoiceControllerTests.swift` | controller logic tests (fake `Recording` + fake `VoiceTurning`). |
| `Gemma/Gemma/Harness/HarnessModel.swift` (modify) | own `voice: VoiceController`, `ensureVoice()`, `currentThreadId`. |
| `Gemma/Gemma/Harness/AgentChatView.swift` (modify) | mic button + state visuals in `inputBar`. |
| `Gemma/Gemma/Settings/SettingsView.swift` (modify) | "Voice Service" section (`voiceBaseURL`). |
| `Gemma/Gemma/Gemma.entitlements` (modify) | `com.apple.security.device.audio-input`. |
| `Gemma/Gemma.xcodeproj/project.pbxproj` (modify) | `INFOPLIST_KEY_NSMicrophoneUsageDescription` on the app target (Debug+Release). |

---

## Task 1: Capability — mic permission string + entitlement

**Files:** Modify `Gemma/Gemma/Gemma.entitlements`, `Gemma/Gemma.xcodeproj/project.pbxproj`.

- [ ] **Step 1: Add the audio-input entitlement.** Replace the empty `<dict></dict>` in `Gemma/Gemma/Gemma.entitlements` so the file reads:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>com.apple.security.device.audio-input</key>
	<true/>
</dict></plist>
```
(The app is currently unsandboxed, so this isn't strictly required today, but it's harmless and makes mic access work if sandbox/hardened-runtime is later enabled.)

- [ ] **Step 2: Add the mic usage string build setting.** Info.plist is auto-generated (`GENERATE_INFOPLIST_FILE = YES`), so the usage string is a build setting. In `Gemma/Gemma.xcodeproj/project.pbxproj`, find the **two** `XCBuildConfiguration` blocks for the **Gemma app target** — they are the ones containing `CODE_SIGN_ENTITLEMENTS = Gemma/Gemma.entitlements;` (around lines 358 and 385). In EACH of those two blocks, add this line inside the `buildSettings = { … }` dictionary (e.g. right after the `GENERATE_INFOPLIST_FILE = YES;` line):

```
				INFOPLIST_KEY_NSMicrophoneUsageDescription = "Gemma graba tu voz para enviarla al asistente.";
```
Match the surrounding tab indentation exactly. Do NOT touch the test target's build configs (the ones without `CODE_SIGN_ENTITLEMENTS`).

- [ ] **Step 3: Verify the project still builds and the key lands in the Info.plist.**

Run: `cd /Users/hashdown/Projects/personal_agent/Gemma && xcodebuild -scheme Gemma -project Gemma.xcodeproj -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.
Then confirm the key is present:
Run: `find ~/Library/Developer/Xcode/DerivedData -name 'Gemma.app' -maxdepth 6 2>/dev/null | head -1 | xargs -I{} /usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "{}/Contents/Info.plist"`
Expected: prints `Gemma graba tu voz para enviarla al asistente.`

- [ ] **Step 4: Commit**

```bash
cd /Users/hashdown/Projects/personal_agent/Gemma
git add Gemma/Gemma.entitlements Gemma.xcodeproj/project.pbxproj
git commit -m "feat(voice): mic entitlement + NSMicrophoneUsageDescription"
```

---

## Task 2: `VoiceClient` (multipart POST to the i3) + tests

**Files:** Create `Gemma/Gemma/Voice/VoiceClient.swift`, `Gemma/GemmaTests/VoiceClientTests.swift`.

- [ ] **Step 1: Write the failing test — `Gemma/GemmaTests/VoiceClientTests.swift`:**

```swift
import XCTest
@testable import Gemma

@MainActor
final class VoiceClientTests: XCTestCase {
    final class StubProtocol: URLProtocol {
        nonisolated(unsafe) static var stub: (URLRequest) -> (HTTPURLResponse, Data) = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let (res, data) = Self.stub(request)
            client?.urlProtocol(self, didReceive: res, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func makeClient() -> VoiceClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return VoiceClient(baseURL: URL(string: "http://localhost:8082")!, bearerToken: "test-token",
                           session: URLSession(configuration: cfg))
    }

    func test_turn_posts_multipart_and_decodes_headers() async throws {
        StubProtocol.stub = { req in
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.url?.path, "/v1/voice/turn")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertTrue(req.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data;") ?? false)
            let headers = ["Content-Type": "audio/wav",
                           "X-STT-Text": "%C2%BFQu%C3%A9%20hora%20es%3F",   // "¿Qué hora es?"
                           "X-Reply-Text": "Son%20las%203."]
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!,
                    Data([0x52, 0x49, 0x46, 0x46]))  // "RIFF" — stand-in WAV bytes
        }
        let reply = try await makeClient().turn(wav: Data([1, 2, 3]), threadId: "T", timezone: "America/Havana")
        XCTAssertEqual(reply.sttText, "¿Qué hora es?")
        XCTAssertEqual(reply.replyText, "Son las 3.")
        XCTAssertEqual(reply.audio, Data([0x52, 0x49, 0x46, 0x46]))
    }

    func test_turn_400_throws_silence() async {
        StubProtocol.stub = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data())
        }
        do {
            _ = try await makeClient().turn(wav: Data([1]), threadId: "T", timezone: "tz")
            XCTFail("expected throw")
        } catch let e as VoiceError {
            XCTAssertEqual(e, .silence)
        } catch { XCTFail("wrong error: \(error)") }
    }

    func test_turn_502_throws_http() async {
        StubProtocol.stub = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 502, httpVersion: nil,
                             headerFields: ["X-Reply-Text": "boom"])!, Data())
        }
        do {
            _ = try await makeClient().turn(wav: Data([1]), threadId: "T", timezone: "tz")
            XCTFail("expected throw")
        } catch let VoiceError.http(status, reply) {
            XCTAssertEqual(status, 502)
            XCTAssertEqual(reply, "boom")
        } catch { XCTFail("wrong error: \(error)") }
    }
}
```

- [ ] **Step 2: Run → FAIL** (no `VoiceClient`).

Run: `cd /Users/hashdown/Projects/personal_agent/Gemma && xcodebuild test -scheme Gemma -project Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/VoiceClientTests 2>&1 | tail -8`
Expected: compile failure — `cannot find 'VoiceClient' in scope`.

- [ ] **Step 3: Create `Gemma/Gemma/Voice/VoiceClient.swift`:**

```swift
import Foundation

/// One voice turn's result: the spoken reply WAV plus the recognized text and the reply text
/// (decoded from the i3's percent-encoded X-STT-Text / X-Reply-Text headers).
struct VoiceReply: Sendable {
    let audio: Data
    let sttText: String
    let replyText: String
}

enum VoiceError: Error, Equatable {
    case silence                              // HTTP 400 — nothing transcribed
    case http(status: Int, reply: String?)    // non-2xx
    case invalidResponse
}

/// Abstraction so VoiceController can be unit-tested with a fake.
protocol VoiceTurning: Sendable {
    func turn(wav: Data, threadId: String, timezone: String) async throws -> VoiceReply
}

/// HTTP client to the i3 voice service. Mirrors MemoryClient (baseURL + bearer + injectable session).
/// Sends a multipart/form-data POST to /v1/voice/turn (audio in -> audio out).
struct VoiceClient: VoiceTurning {
    let baseURL: URL
    let bearerToken: String
    let session: URLSession

    init(baseURL: URL, bearerToken: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.session = session
    }

    func turn(wav: Data, threadId: String, timezone: String) async throws -> VoiceReply {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }
        // audio part
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"audio\"; filename=\"u.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        append("\r\n")
        // text fields
        for (name, value) in [("threadId", threadId), ("timezone", timezone)] {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append(value)
            append("\r\n")
        }
        append("--\(boundary)--\r\n")

        var req = URLRequest(url: baseURL.appendingPathComponent("v1/voice/turn"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 180

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw VoiceError.invalidResponse }
        func header(_ key: String) -> String {
            (http.value(forHTTPHeaderField: key)?.removingPercentEncoding) ?? ""
        }
        if http.statusCode == 400 { throw VoiceError.silence }
        guard (200..<300).contains(http.statusCode) else {
            throw VoiceError.http(status: http.statusCode, reply: header("X-Reply-Text"))
        }
        return VoiceReply(audio: data, sttText: header("X-STT-Text"), replyText: header("X-Reply-Text"))
    }
}
```

- [ ] **Step 4: Run → PASS.**

Run: `cd /Users/hashdown/Projects/personal_agent/Gemma && xcodebuild test -scheme Gemma -project Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/VoiceClientTests 2>&1 | tail -8`
Expected: `Test Suite 'VoiceClientTests' passed`.

- [ ] **Step 5: Commit**

```bash
git add Gemma/Gemma/Voice/VoiceClient.swift Gemma/GemmaTests/VoiceClientTests.swift
git commit -m "feat(voice): VoiceClient — multipart POST /v1/voice/turn + VoiceReply/VoiceError/VoiceTurning"
```

---

## Task 3: `AudioRecorder` (16 kHz mono WAV) + `Recording` protocol

**Files:** Create `Gemma/Gemma/Voice/AudioRecorder.swift`.

This file is hardware-bound (mic), so it has no unit test; the `Recording` protocol exists so `VoiceController` (Task 4) is testable with a fake. Verification here is just that it compiles.

- [ ] **Step 1: Create `Gemma/Gemma/Voice/AudioRecorder.swift`:**

```swift
import Foundation
import AVFoundation

/// Mic capture abstraction. Real impl records 16 kHz mono PCM16 WAV; a fake backs VoiceController tests.
protocol Recording: AnyObject, Sendable {
    func requestPermission() async -> Bool
    func start() throws
    func stop() -> Data?
}

/// Records the microphone to a temp 16 kHz mono PCM16 WAV (the format the i3 STT requires — it
/// assumes 16 kHz; sending 44.1/48 kHz would garble transcription). macOS needs no AVAudioSession.
final class AudioRecorder: Recording, @unchecked Sendable {
    private var recorder: AVAudioRecorder?
    private var fileURL: URL?

    func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemma-voice-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let rec = try AVAudioRecorder(url: url, settings: settings)
        rec.record()
        recorder = rec
        fileURL = url
    }

    func stop() -> Data? {
        recorder?.stop()
        recorder = nil
        defer { fileURL = nil }
        guard let url = fileURL else { return nil }
        let data = try? Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)
        return data
    }
}
```

- [ ] **Step 2: Verify it compiles** (full build; the file auto-joins via the synchronized folder).

Run: `cd /Users/hashdown/Projects/personal_agent/Gemma && xcodebuild -scheme Gemma -project Gemma.xcodeproj -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Gemma/Gemma/Voice/AudioRecorder.swift
git commit -m "feat(voice): AudioRecorder (16kHz mono WAV) + Recording protocol"
```

---

## Task 4: `VoiceController` state machine + tests

**Files:** Create `Gemma/Gemma/Voice/VoiceController.swift`, `Gemma/GemmaTests/VoiceControllerTests.swift`.

`beginRecording()` and `send(_:)` are `internal` (not private) so the test target can drive them directly and `await` them (the public `toggleRecording()` just dispatches into them).

- [ ] **Step 1: Write the failing test — `Gemma/GemmaTests/VoiceControllerTests.swift`:**

```swift
import XCTest
@testable import Gemma

@MainActor
final class VoiceControllerTests: XCTestCase {
    final class FakeRecorder: Recording, @unchecked Sendable {
        var granted = true
        var wav = Data([0x52, 0x49, 0x46, 0x46])
        func requestPermission() async -> Bool { granted }
        func start() throws {}
        func stop() -> Data? { wav }
    }
    final class FakeTurning: VoiceTurning, @unchecked Sendable {
        var reply = VoiceReply(audio: Data(), sttText: "hola", replyText: "qué tal")  // empty audio → play() no-ops to idle
        var error: Error?
        func turn(wav: Data, threadId: String, timezone: String) async throws -> VoiceReply {
            if let error { throw error }
            return reply
        }
    }

    private func make(_ rec: FakeRecorder = FakeRecorder()) -> (VoiceController, FakeTurning, () -> [String]) {
        let c = VoiceController(recorder: rec)
        let t = FakeTurning()
        c.client = t
        var lines: [String] = []
        c.appendLine = { lines.append($0) }
        c.threadId = { "T" }
        return (c, t, { lines })
    }

    func test_happy_path_appends_you_and_gemma() async {
        let rec = FakeRecorder()
        let (c, _, lines) = make(rec)
        await c.beginRecording()
        XCTAssertEqual(c.state, .recording)
        await c.send(rec.wav)
        XCTAssertEqual(lines(), ["you: hola", "gemma: qué tal"])
        XCTAssertEqual(c.state, .idle)   // empty audio → AVAudioPlayer init fails → idle
    }

    func test_silence_does_not_append() async {
        let (c, t, lines) = make()
        t.error = VoiceError.silence
        await c.send(Data([1]))
        XCTAssertTrue(lines().isEmpty)
        XCTAssertEqual(c.state, .idle)
    }

    func test_generic_error_appends_voice_line() async {
        let (c, t, lines) = make()
        t.error = VoiceError.http(status: 502, reply: "boom")
        await c.send(Data([1]))
        XCTAssertTrue(lines().contains { $0.hasPrefix("voice:") })
        XCTAssertEqual(c.state, .idle)
    }

    func test_permission_denied_notice() async {
        let rec = FakeRecorder(); rec.granted = false
        let (c, _, lines) = make(rec)
        await c.beginRecording()
        XCTAssertEqual(c.state, .idle)
        XCTAssertTrue(lines().first?.localizedCaseInsensitiveContains("micrófono") ?? false)
    }
}
```

- [ ] **Step 2: Run → FAIL** (no `VoiceController`).

Run: `cd /Users/hashdown/Projects/personal_agent/Gemma && xcodebuild test -scheme Gemma -project Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/VoiceControllerTests 2>&1 | tail -8`
Expected: `cannot find 'VoiceController' in scope`.

- [ ] **Step 3: Create `Gemma/Gemma/Voice/VoiceController.swift`:**

```swift
import Foundation
import AVFoundation
import Observation

/// Drives one voice turn: record -> POST to the i3 -> append transcript+reply to the chat -> play.
/// `appendLine` and `threadId` are injected by HarnessModel (avoids an Observable retain cycle).
@MainActor
@Observable
final class VoiceController: NSObject, AVAudioPlayerDelegate {
    enum State: Equatable { case idle, recording, sending, playing }
    private(set) var state: State = .idle

    @ObservationIgnored private let recorder: Recording
    @ObservationIgnored var client: VoiceTurning?
    @ObservationIgnored var appendLine: (String) -> Void = { _ in }
    @ObservationIgnored var threadId: () -> String = { "voice" }
    @ObservationIgnored private var player: AVAudioPlayer?

    init(recorder: Recording) {
        self.recorder = recorder
        super.init()
    }

    /// Build the real client from settings (called by HarnessModel.ensureVoice()).
    func configure(baseURL: URL, token: String) {
        client = VoiceClient(baseURL: baseURL, bearerToken: token)
    }

    /// The single UI entry point (mic button).
    func toggleRecording() {
        switch state {
        case .idle: Task { await beginRecording() }
        case .recording: finishRecording()
        case .sending, .playing: break   // ignore taps mid-flight
        }
    }

    func beginRecording() async {
        guard await recorder.requestPermission() else {
            appendLine("voice: micrófono denegado (Ajustes → Privacidad → Micrófono).")
            return
        }
        do {
            try recorder.start()
            state = .recording
        } catch {
            appendLine("voice: no pude iniciar la grabación (\(error.localizedDescription))")
        }
    }

    private func finishRecording() {
        guard let wav = recorder.stop() else { state = .idle; return }
        state = .sending
        Task { await send(wav) }
    }

    func send(_ wav: Data) async {
        guard let client else {
            appendLine("voice: configura la URL del servicio de voz en Ajustes.")
            state = .idle
            return
        }
        do {
            let reply = try await client.turn(wav: wav, threadId: threadId(),
                                              timezone: TimeZone.current.identifier)
            appendLine("you: \(reply.sttText)")
            appendLine("gemma: \(reply.replyText)")
            play(reply.audio)
        } catch VoiceError.silence {
            state = .idle   // nothing heard — don't clutter the chat
        } catch {
            appendLine("voice: \(error)")
            state = .idle
        }
    }

    private func play(_ audio: Data) {
        do {
            let p = try AVAudioPlayer(data: audio)
            p.delegate = self
            player = p
            state = .playing
            p.play()
        } catch {
            state = .idle   // reply text is already shown; nothing to play
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.player = nil
            self.state = .idle
        }
    }
}
```

- [ ] **Step 4: Run → PASS.**

Run: `cd /Users/hashdown/Projects/personal_agent/Gemma && xcodebuild test -scheme Gemma -project Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/VoiceControllerTests 2>&1 | tail -8`
Expected: `Test Suite 'VoiceControllerTests' passed` (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Gemma/Gemma/Voice/VoiceController.swift Gemma/GemmaTests/VoiceControllerTests.swift
git commit -m "feat(voice): VoiceController state machine (record->send->append->play) + tests"
```

---

## Task 5: Wire `HarnessModel` + Settings (`voiceBaseURL`)

**Files:** Modify `Gemma/Gemma/Harness/HarnessModel.swift`, `Gemma/Gemma/Settings/SettingsView.swift`.

- [ ] **Step 1: Add the controller + thread accessor + `ensureVoice()` to `HarnessModel`.**

In `Gemma/Gemma/Harness/HarnessModel.swift`, add a stored property near `memory` (after line 19 `… private(set) var memory: MemoryClient?`):

```swift
    /// In-app voice: records mic audio, sends it to the i3 voice service, plays the reply.
    @ObservationIgnored let voice = VoiceController(recorder: AudioRecorder())
```

Add a read-only accessor for the current chat thread id (so voice turns share the conversation). Put it right after the `private var threadId = UUID().uuidString` line (line 36):

```swift
    /// The chat thread id voice turns join (same episode as typed chat).
    var currentThreadId: String { threadId }
```

At the END of `init()` (after the `NotificationCenter.default.addObserver(…)` block, before the closing `}` of `init` at line ~79), wire the controller's closures + build its client:

```swift
        voice.appendLine = { [weak self] line in self?.agentLog.append(line) }
        voice.threadId = { [weak self] in self?.currentThreadId ?? "voice" }
        ensureVoice()
```

Add the `ensureVoice()` method right after `ensureMemory()` (after line 174):

```swift
    /// Build (or rebuild) the voice client from `UserDefaults`. Reuses the memory bearer token
    /// (the i3 voice service shares it). Key: `voiceBaseURL` (default `http://localhost:8082`).
    func ensureVoice() {
        let urlString = UserDefaults.standard.string(forKey: "voiceBaseURL") ?? "http://localhost:8082"
        let token = UserDefaults.standard.string(forKey: "memoryBearerToken") ?? ""
        guard let baseURL = URL(string: urlString) else { return }
        voice.configure(baseURL: baseURL, token: token)
    }
```

- [ ] **Step 2: Add the "Voice Service" Settings section.**

In `Gemma/Gemma/Settings/SettingsView.swift`, add the `@AppStorage` near the others (after line 9 `… memoryBearerToken`):

```swift
    @AppStorage("voiceBaseURL") private var voiceBaseURL: String = "http://localhost:8082"
```

Add a new `Section` right after the `Section("Memory Service") { … }` block (which ends at line 47 with its `.onChange` modifiers) — insert before the `Form`'s closing brace:

```swift
            Section("Voice Service") {
                TextField("Voice base URL", text: $voiceBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .help("Servicio de voz en el i3 (puerto 8082). Usa el mismo bearer token que Memory.")
                Text("Default: http://localhost:8082. Apúntalo al i3 como el Memory Service.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: voiceBaseURL) { _, _ in model.ensureVoice() }
            .onChange(of: memoryBearerToken) { _, _ in model.ensureVoice() }
```

- [ ] **Step 3: Build to verify wiring compiles.**

Run: `cd /Users/hashdown/Projects/personal_agent/Gemma && xcodebuild -scheme Gemma -project Gemma.xcodeproj -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Gemma/Gemma/Harness/HarnessModel.swift Gemma/Gemma/Settings/SettingsView.swift
git commit -m "feat(voice): HarnessModel.voice + ensureVoice() + currentThreadId + Voice Service setting"
```

---

## Task 6: Mic button in the chat input bar

**Files:** Modify `Gemma/Gemma/Harness/AgentChatView.swift`.

- [ ] **Step 1: Add a `voiceIcon` computed property + the mic button, and gate Send on voice state.**

In `Gemma/Gemma/Harness/AgentChatView.swift`, replace the `inputBar` computed property (lines 145–156) with:

```swift
    private var voiceIcon: String {
        switch model.voice.state {
        case .idle:      return "mic"
        case .recording: return "stop.circle.fill"
        case .sending:   return "ellipsis"
        case .playing:   return "speaker.wave.2.fill"
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            Button(action: { model.voice.toggleRecording() }) {
                Image(systemName: voiceIcon)
                    .foregroundStyle(model.voice.state == .recording ? .red : .primary)
            }
            .buttonStyle(.borderless)
            .disabled(model.agentRunning || model.voice.state == .sending || model.voice.state == .playing)
            .help(model.voice.state == .recording ? "Detener y enviar" : "Hablar con Gemma")

            TextField("Message Gemma…", text: $input)
                .textFieldStyle(.roundedBorder)
                .onSubmit(send)
                .disabled(model.agentRunning || !serverReady || model.voice.state != .idle)
            Button("Send", action: send)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(model.agentRunning || !serverReady || model.voice.state != .idle
                          || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
    }
```

- [ ] **Step 2: Build to verify.**

Run: `cd /Users/hashdown/Projects/personal_agent/Gemma && xcodebuild -scheme Gemma -project Gemma.xcodeproj -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Gemma/Gemma/Harness/AgentChatView.swift
git commit -m "feat(voice): mic button in chat input bar (tap to record/stop, state visuals)"
```

---

## Task 7: Full build + test suite green

**Files:** none (integration verification).

- [ ] **Step 1: Run the full test suite.**

Run: `cd /Users/hashdown/Projects/personal_agent/Gemma && xcodebuild test -scheme Gemma -project Gemma.xcodeproj -destination 'platform=macOS' 2>&1 | tail -25`
Expected: build succeeds; `VoiceClientTests` (3) + `VoiceControllerTests` (4) pass; all other suites pass EXCEPT the known pre-existing `HarnessModelTests.test_defaultBaseURL` (unrelated). No NEW failures.

- [ ] **Step 2: If any NEW failure appears, fix it before proceeding** (do not mask it). Re-run until only the known `test_defaultBaseURL` fails (or it too passes).

- [ ] **Step 3: Commit** (only if Step 2 required code changes; otherwise skip — Tasks 1–6 already committed).

---

## Task 8: Manual in-app E2E (user-driven)

**Files:** none.

The i3 voice service is already deployed and curl-verified. This task confirms the in-app loop on real hardware. (Done by the user; the implementer documents the steps + leaves the app built.)

- [ ] **Step 1:** Ensure Settings → "Voice Service" base URL points at the i3 (e.g. `http://192.168.1.50:8082`) and the Memory bearer token is set (the voice service reuses it).
- [ ] **Step 2:** Run the app (`xcodebuild -scheme Gemma … build` then launch the built `.app`, or run from Xcode). On first mic tap, grant the microphone permission prompt.
- [ ] **Step 3:** Tap the mic (🎤), say "¿qué hora es?", tap stop (🔴). Expect: spinner → hear Gemma speak the time → chat shows `you: ¿qué hora es?` + `gemma: Son las …`.
- [ ] **Step 4:** Tap mic again, say "recuérdame que me gusta el café cubano", stop; then mic again "¿qué bebida me gusta?" → it recalls café (same thread).
- [ ] **Step 5:** Confirm error paths: with a wrong Voice base URL, a turn shows a `voice: …` line and the mic returns to idle (no stuck recording).

---

## Self-Review

**1. Spec coverage:**
- §2.1 mic button tap-to-start/stop → Task 6 (`toggleRecording`, `voiceIcon`). ✓
- §2.2 record 16 kHz WAV → POST → play reply + append transcript/reply → Tasks 3 (recorder), 2 (client), 4 (controller `send`). ✓
- §2.3 Settings for voice URL (reuse bearer) → Task 5. ✓
- §2.4 mic permission + entitlement → Task 1 + `AudioRecorder.requestPermission`. ✓
- §2.5 never stuck recording / graceful errors → Task 4 (`VoiceError.silence`→idle, generic→line+idle, denied→notice+idle) + tests. ✓
- §4.2 components (AudioRecorder/VoiceClient/VoiceController, protocols) → Tasks 2–4. ✓
- §4.3 HarnessModel owns `voice`, `currentThreadId`, agentLog append → Task 5. ✓
- §4.4 Settings section + `voiceBaseURL` default :8082 + reuse `memoryBearerToken` → Task 5. ✓
- §4.5 entitlement + INFOPLIST_KEY → Task 1. ✓
- §4.6 16 kHz record / 24 kHz play → Task 3 settings + `AVAudioPlayer(data:)` in Task 4. ✓
- §4.7 error matrix → Task 4 + tests in Task 4 Step 1. ✓
- §5 testing (VoiceClient URLProtocol stub; VoiceController fakes; manual hardware) → Tasks 2, 4, 8. ✓
- §6 order → Tasks 1→8 match. ✓ §7 risks (pbxproj, mic perm, sample rate) → de-risked: synchronized folders (no file-ref edits), Task 1 first, fixed 16 kHz recorder settings. ✓

**2. Placeholder scan:** none — every code/edit step shows full content; every run step has an exact command + expected output. The one pbxproj edit (Task 1 Step 2) gives the exact key string + which blocks.

**3. Type consistency:** `VoiceReply{audio,sttText,replyText}`, `VoiceError{silence, http(status,reply), invalidResponse}`, `VoiceTurning.turn(wav:threadId:timezone:)`, `Recording{requestPermission,start,stop}`, `VoiceController{state, client, appendLine, threadId, configure, beginRecording, send, toggleRecording}` are used identically across `VoiceClient.swift`, `VoiceController.swift`, both test files, `HarnessModel` (builds `VoiceController(recorder: AudioRecorder())`, sets `appendLine`/`threadId`, calls `ensureVoice`→`configure`), and `AgentChatView` (`model.voice.toggleRecording()`, `model.voice.state`). `UserDefaults` key `voiceBaseURL` matches between `ensureVoice()` and the `@AppStorage` in SettingsView. ✓
