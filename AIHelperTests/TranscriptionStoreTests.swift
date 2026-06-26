import XCTest
@testable import AIHelper

final class TranscriptionStoreTests: XCTestCase {

    var store: TranscriptionStore!

    override func setUp() {
        super.setUp()
        store = TranscriptionStore()
        store.clearAll()
    }

    override func tearDown() {
        store.clearAll()
        store = nil
        super.tearDown()
    }

    // MARK: - Basic Operations

    func testAddTranscription() {
        let transcription = Transcription(text: "Hello world", date: Date())

        store.add(transcription)

        XCTAssertEqual(store.transcriptions.count, 1)
        XCTAssertEqual(store.transcriptions.first?.text, "Hello world")
    }

    func testAddMultipleTranscriptions() {
        let t1 = Transcription(text: "First", date: Date())
        let t2 = Transcription(text: "Second", date: Date())
        let t3 = Transcription(text: "Third", date: Date())

        store.add(t1)
        store.add(t2)
        store.add(t3)

        XCTAssertEqual(store.transcriptions.count, 3)
    }

    func testNewTranscriptionsAreAddedAtFront() {
        let t1 = Transcription(text: "First", date: Date())
        let t2 = Transcription(text: "Second", date: Date())

        store.add(t1)
        store.add(t2)

        XCTAssertEqual(store.transcriptions.first?.text, "Second", "Newest transcription should be first")
        XCTAssertEqual(store.transcriptions.last?.text, "First", "Oldest transcription should be last")
    }

    func testRemoveTranscription() {
        let transcription = Transcription(text: "To remove", date: Date())

        store.add(transcription)
        XCTAssertEqual(store.transcriptions.count, 1)

        store.remove(transcription)
        XCTAssertEqual(store.transcriptions.count, 0)
    }

    func testRemoveSpecificTranscription() {
        let t1 = Transcription(text: "Keep me", date: Date())
        let t2 = Transcription(text: "Remove me", date: Date())
        let t3 = Transcription(text: "Keep me too", date: Date())

        store.add(t1)
        store.add(t2)
        store.add(t3)

        store.remove(t2)

        XCTAssertEqual(store.transcriptions.count, 2)
        XCTAssertFalse(store.transcriptions.contains(where: { $0.id == t2.id }))
        XCTAssertTrue(store.transcriptions.contains(where: { $0.id == t1.id }))
        XCTAssertTrue(store.transcriptions.contains(where: { $0.id == t3.id }))
    }

    func testClearAll() {
        for i in 1...5 {
            store.add(Transcription(text: "Text \(i)", date: Date()))
        }

        XCTAssertEqual(store.transcriptions.count, 5)

        store.clearAll()

        XCTAssertEqual(store.transcriptions.count, 0)
        XCTAssertTrue(store.transcriptions.isEmpty)
    }

    // MARK: - Storage Limit Tests

    func testStorageLimitEnforced() {
        // Add more than the max (100) transcriptions
        for i in 1...110 {
            store.add(Transcription(text: "Transcription \(i)", date: Date()))
        }

        XCTAssertLessThanOrEqual(store.transcriptions.count, 100, "Should not exceed 100 transcriptions")
    }

    func testOldestTranscriptionsRemovedWhenLimitReached() {
        // Add exactly max transcriptions
        for i in 1...100 {
            store.add(Transcription(text: "Transcription \(i)", date: Date()))
        }

        // The first transcription should still be "Transcription 100" (most recent)
        XCTAssertEqual(store.transcriptions.first?.text, "Transcription 100")

        // Add one more
        store.add(Transcription(text: "Transcription 101", date: Date()))

        // Should still have 100
        XCTAssertEqual(store.transcriptions.count, 100)

        // Newest should be first
        XCTAssertEqual(store.transcriptions.first?.text, "Transcription 101")

        // Oldest (Transcription 1) should have been removed
        XCTAssertFalse(store.transcriptions.contains(where: { $0.text == "Transcription 1" }))
    }

    // MARK: - Transcription Model Tests

    func testTranscriptionEquality() {
        let id = UUID()
        let date = Date()

        let t1 = Transcription(id: id, text: "Same", date: date)
        let t2 = Transcription(id: id, text: "Same", date: date)

        XCTAssertEqual(t1, t2)
    }

    func testTranscriptionInequality() {
        let t1 = Transcription(text: "First", date: Date())
        let t2 = Transcription(text: "Second", date: Date())

        XCTAssertNotEqual(t1, t2)
    }

    func testTranscriptionCodable() throws {
        let date = Date()
        let transcription = Transcription(text: "Test text", date: date)

        let encoder = JSONEncoder()
        let data = try encoder.encode(transcription)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Transcription.self, from: data)

        XCTAssertEqual(transcription.id, decoded.id)
        XCTAssertEqual(transcription.text, decoded.text)
        XCTAssertEqual(transcription.date.timeIntervalSince1970, decoded.date.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - Edge Cases

    func testAddEmptyTextTranscription() {
        let transcription = Transcription(text: "", date: Date())

        store.add(transcription)

        XCTAssertEqual(store.transcriptions.count, 1)
        XCTAssertEqual(store.transcriptions.first?.text, "")
    }

    func testAddVeryLongTextTranscription() {
        let longText = String(repeating: "A", count: 10000)
        let transcription = Transcription(text: longText, date: Date())

        store.add(transcription)

        XCTAssertEqual(store.transcriptions.count, 1)
        XCTAssertEqual(store.transcriptions.first?.text.count, 10000)
    }

    func testAddTranscriptionWithSpecialCharacters() {
        let specialText = "Hello 🌍! Special chars: <>&\"'\\n\\t emoji: 😀🎉"
        let transcription = Transcription(text: specialText, date: Date())

        store.add(transcription)

        XCTAssertEqual(store.transcriptions.first?.text, specialText)
    }

    func testRemoveNonExistentTranscription() {
        let t1 = Transcription(text: "Exists", date: Date())
        let t2 = Transcription(text: "Never added", date: Date())

        store.add(t1)

        // This should not crash or affect existing transcriptions
        store.remove(t2)

        XCTAssertEqual(store.transcriptions.count, 1)
        XCTAssertEqual(store.transcriptions.first?.id, t1.id)
    }

    func testClearEmptyStore() {
        // Should not crash
        store.clearAll()

        XCTAssertTrue(store.transcriptions.isEmpty)
    }
}
