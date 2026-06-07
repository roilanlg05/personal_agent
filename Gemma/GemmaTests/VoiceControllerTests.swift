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

    func test_no_client_prompts_for_settings() async {
        let c = VoiceController(recorder: FakeRecorder())   // client defaults to nil (not configured)
        var lines: [String] = []
        c.appendLine = { lines.append($0) }
        await c.send(Data([1]))
        XCTAssertTrue(lines.contains { $0.localizedCaseInsensitiveContains("configura") })
        XCTAssertEqual(c.state, .idle)
    }
}
