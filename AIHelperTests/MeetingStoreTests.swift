import XCTest
@testable import AIHelper

/// Every test works in its own temporary folder, never the real meetings archive.
final class MeetingStoreTests: XCTestCase {

    private var root: URL!
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aihelper-tests-meetings-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        root = nil
        super.tearDown()
    }

    @MainActor
    private func makeStore() -> MeetingStore {
        MeetingStore(root: root, usesTrash: false)
    }

    @MainActor
    private func transcribedMeeting(in store: MeetingStore) throws -> Meeting {
        var meeting = try store.createMeeting(startedAt: start)
        var greeting = MeetingSegment(track: .microphone, speaker: MeetingSpeaker.me, start: 1, end: 3)
        greeting.text = "Hello there."
        meeting.segments = [greeting]
        meeting.duration = 125
        meeting.status = .done
        store.update(meeting)
        return meeting
    }

    @MainActor
    func testMeetingSurvivesAReload() throws {
        let store = makeStore()
        let meeting = try transcribedMeeting(in: store)

        let reloaded = makeStore()

        XCTAssertEqual(reloaded.meetings, [meeting])
        let transcript = try String(contentsOf: store.transcriptURL(for: meeting), encoding: .utf8)
        XCTAssertTrue(transcript.contains("[00:01] Me: Hello there."))
    }

    @MainActor
    func testMeetingsStartedInTheSameMinuteGetTheirOwnFolders() throws {
        let store = makeStore()

        let first = try store.createMeeting(startedAt: start)
        let second = try store.createMeeting(startedAt: start)

        XCTAssertNotEqual(first.folderName, second.folderName)
        XCTAssertEqual(store.meetings.count, 2)
    }

    @MainActor
    func testRenamingASpeakerRewritesTheTranscript() throws {
        let store = makeStore()
        let meeting = try transcribedMeeting(in: store)

        store.renameSpeaker(MeetingSpeaker.me, to: "Hendrik", in: meeting.id)
        var transcript = try String(contentsOf: store.transcriptURL(for: meeting), encoding: .utf8)
        XCTAssertTrue(transcript.contains("Hendrik: Hello there."))

        store.renameSpeaker(MeetingSpeaker.me, to: "  ", in: meeting.id)
        transcript = try String(contentsOf: store.transcriptURL(for: meeting), encoding: .utf8)
        XCTAssertTrue(transcript.contains("Me: Hello there."), "an empty name restores the default")
    }

    @MainActor
    func testRenamingTheMeetingIgnoresBlankTitles() throws {
        let store = makeStore()
        let meeting = try transcribedMeeting(in: store)

        store.rename(meeting.id, to: "Pricing review")
        store.rename(meeting.id, to: "   ")

        XCTAssertEqual(store.meeting(id: meeting.id)?.title, "Pricing review")
    }

    @MainActor
    func testDeletingRemovesTheFolder() throws {
        let store = makeStore()
        let meeting = try transcribedMeeting(in: store)
        let folder = store.folder(for: meeting)

        store.delete(meeting)

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(store.meetings.isEmpty)
        XCTAssertTrue(makeStore().meetings.isEmpty)
    }
}
