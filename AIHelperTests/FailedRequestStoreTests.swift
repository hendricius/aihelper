import XCTest
@testable import AIHelper

final class FailedRequestStoreTests: XCTestCase {

    var store: FailedRequestStore!

    override func setUp() {
        super.setUp()
        store = FailedRequestStore()
        store.clearAll()
    }

    override func tearDown() {
        store.clearAll()
        store = nil
        super.tearDown()
    }

    // MARK: - Basic Operations

    func testAddFailedRequest() {
        let request = FailedRequest.transcription(
            audioData: Data([0x00, 0x01, 0x02]),
            errorMessage: "Network timeout"
        )

        store.add(request)

        XCTAssertEqual(store.failedRequests.count, 1)
        XCTAssertEqual(store.failedRequests.first?.errorMessage, "Network timeout")
    }

    func testAddMultipleFailedRequests() {
        let r1 = FailedRequest.transcription(audioData: Data(), errorMessage: "Error 1")
        let r2 = FailedRequest.formatting(text: "Hello", errorMessage: "Error 2")
        let r3 = FailedRequest.transcription(audioData: Data(), errorMessage: "Error 3")

        store.add(r1)
        store.add(r2)
        store.add(r3)

        XCTAssertEqual(store.failedRequests.count, 3)
    }

    func testNewRequestsAreAddedAtFront() {
        let r1 = FailedRequest.transcription(audioData: Data(), errorMessage: "First")
        let r2 = FailedRequest.transcription(audioData: Data(), errorMessage: "Second")

        store.add(r1)
        store.add(r2)

        XCTAssertEqual(store.failedRequests.first?.errorMessage, "Second", "Newest request should be first")
        XCTAssertEqual(store.failedRequests.last?.errorMessage, "First", "Oldest request should be last")
    }

    func testRemoveFailedRequest() {
        let request = FailedRequest.transcription(audioData: Data(), errorMessage: "To remove")

        store.add(request)
        XCTAssertEqual(store.failedRequests.count, 1)

        store.remove(request)
        XCTAssertEqual(store.failedRequests.count, 0)
    }

    func testRemoveSpecificRequest() {
        let r1 = FailedRequest.transcription(audioData: Data(), errorMessage: "Keep me")
        let r2 = FailedRequest.formatting(text: "Remove", errorMessage: "Remove me")
        let r3 = FailedRequest.transcription(audioData: Data(), errorMessage: "Keep me too")

        store.add(r1)
        store.add(r2)
        store.add(r3)

        store.remove(r2)

        XCTAssertEqual(store.failedRequests.count, 2)
        XCTAssertFalse(store.failedRequests.contains(where: { $0.id == r2.id }))
        XCTAssertTrue(store.failedRequests.contains(where: { $0.id == r1.id }))
        XCTAssertTrue(store.failedRequests.contains(where: { $0.id == r3.id }))
    }

    func testClearAll() {
        for i in 1...5 {
            store.add(FailedRequest.transcription(audioData: Data(), errorMessage: "Error \(i)"))
        }

        XCTAssertEqual(store.failedRequests.count, 5)

        store.clearAll()

        XCTAssertEqual(store.failedRequests.count, 0)
        XCTAssertTrue(store.failedRequests.isEmpty)
    }

    // MARK: - Storage Limit Tests

    func testStorageLimitEnforced() {
        // Add more than the max (10) requests
        for i in 1...15 {
            store.add(FailedRequest.transcription(audioData: Data(), errorMessage: "Error \(i)"))
        }

        XCTAssertLessThanOrEqual(store.failedRequests.count, 10, "Should not exceed 10 failed requests")
    }

    func testOldestRequestsRemovedWhenLimitReached() {
        // Add exactly max requests
        for i in 1...10 {
            store.add(FailedRequest.transcription(audioData: Data(), errorMessage: "Error \(i)"))
        }

        // The first request should be "Error 10" (most recent)
        XCTAssertEqual(store.failedRequests.first?.errorMessage, "Error 10")

        // Add one more
        store.add(FailedRequest.transcription(audioData: Data(), errorMessage: "Error 11"))

        // Should still have 10
        XCTAssertEqual(store.failedRequests.count, 10)

        // Newest should be first
        XCTAssertEqual(store.failedRequests.first?.errorMessage, "Error 11")

        // Oldest (Error 1) should have been removed
        XCTAssertFalse(store.failedRequests.contains(where: { $0.errorMessage == "Error 1" }))
    }

    // MARK: - Helper Properties Tests

    func testHasFailedRequests() {
        XCTAssertFalse(store.hasFailedRequests)

        store.add(FailedRequest.transcription(audioData: Data(), errorMessage: "Test"))

        XCTAssertTrue(store.hasFailedRequests)
    }

    func testCount() {
        XCTAssertEqual(store.count, 0)

        store.add(FailedRequest.transcription(audioData: Data(), errorMessage: "Test 1"))
        XCTAssertEqual(store.count, 1)

        store.add(FailedRequest.transcription(audioData: Data(), errorMessage: "Test 2"))
        XCTAssertEqual(store.count, 2)
    }

    // MARK: - FailedRequest Model Tests

    func testTranscriptionRequestCreation() {
        let audioData = Data([0x00, 0x01, 0x02, 0x03])
        let request = FailedRequest.transcription(
            audioData: audioData,
            errorMessage: "Timeout",
            formattingEnabled: true
        )

        XCTAssertEqual(request.requestType, .transcription)
        XCTAssertEqual(request.audioData, audioData)
        XCTAssertEqual(request.errorMessage, "Timeout")
        XCTAssertTrue(request.formattingEnabled)
        XCTAssertNil(request.text)
    }

    func testFormattingRequestCreation() {
        let request = FailedRequest.formatting(
            text: "Hello world",
            errorMessage: "Connection lost"
        )

        XCTAssertEqual(request.requestType, .formatting)
        XCTAssertEqual(request.text, "Hello world")
        XCTAssertEqual(request.errorMessage, "Connection lost")
        XCTAssertNil(request.audioData)
        XCTAssertFalse(request.formattingEnabled)
    }

    func testRequestEquality() {
        let id = UUID()
        let date = Date()

        let r1 = FailedRequest(
            id: id,
            date: date,
            errorMessage: "Error",
            requestType: .transcription,
            audioData: Data(),
            formattingEnabled: false
        )
        let r2 = FailedRequest(
            id: id,
            date: date,
            errorMessage: "Error",
            requestType: .transcription,
            audioData: Data(),
            formattingEnabled: false
        )

        XCTAssertEqual(r1, r2)
    }

    func testRequestInequality() {
        let r1 = FailedRequest.transcription(audioData: Data(), errorMessage: "First")
        let r2 = FailedRequest.transcription(audioData: Data(), errorMessage: "Second")

        XCTAssertNotEqual(r1, r2)
    }

    func testRequestCodable() throws {
        let date = Date()
        let audioData = Data([0x01, 0x02, 0x03])
        let request = FailedRequest(
            date: date,
            errorMessage: "Test error",
            requestType: .transcription,
            audioData: audioData,
            formattingEnabled: true
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(request)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(FailedRequest.self, from: data)

        XCTAssertEqual(request.id, decoded.id)
        XCTAssertEqual(request.errorMessage, decoded.errorMessage)
        XCTAssertEqual(request.requestType, decoded.requestType)
        XCTAssertEqual(request.audioData, decoded.audioData)
        XCTAssertEqual(request.formattingEnabled, decoded.formattingEnabled)
        XCTAssertEqual(request.date.timeIntervalSince1970, decoded.date.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - Edge Cases

    func testRemoveNonExistentRequest() {
        let r1 = FailedRequest.transcription(audioData: Data(), errorMessage: "Exists")
        let r2 = FailedRequest.transcription(audioData: Data(), errorMessage: "Never added")

        store.add(r1)

        // This should not crash or affect existing requests
        store.remove(r2)

        XCTAssertEqual(store.failedRequests.count, 1)
        XCTAssertEqual(store.failedRequests.first?.id, r1.id)
    }

    func testClearEmptyStore() {
        // Should not crash
        store.clearAll()

        XCTAssertTrue(store.failedRequests.isEmpty)
    }

    func testLargeAudioData() {
        // Test with large audio data (1MB)
        let largeData = Data(repeating: 0x42, count: 1024 * 1024)
        let request = FailedRequest.transcription(audioData: largeData, errorMessage: "Timeout")

        store.add(request)

        XCTAssertEqual(store.failedRequests.count, 1)
        XCTAssertEqual(store.failedRequests.first?.audioData?.count, 1024 * 1024)
    }
}

// MARK: - Error Retryable Tests

final class ErrorRetryableTests: XCTestCase {

    func testWhisperNetworkErrorIsRetryable() {
        let error = WhisperError.networkError("Timeout")
        XCTAssertTrue(error.isRetryable)
    }

    func testWhisperServerErrorIsRetryable() {
        let error = WhisperError.serverError(503)
        XCTAssertTrue(error.isRetryable)
    }

    func testWhisperRateLimitedIsRetryable() {
        let error = WhisperError.rateLimited
        XCTAssertTrue(error.isRetryable)
    }

    func testWhisperMissingAPIKeyIsNotRetryable() {
        let error = WhisperError.missingAPIKey
        XCTAssertFalse(error.isRetryable)
    }

    func testWhisperInvalidAPIKeyIsNotRetryable() {
        let error = WhisperError.invalidAPIKey
        XCTAssertFalse(error.isRetryable)
    }

    func testWhisperAudioFileNotFoundIsNotRetryable() {
        let error = WhisperError.audioFileNotFound
        XCTAssertFalse(error.isRetryable)
    }

    func testFormattingNetworkErrorIsRetryable() {
        let error = FormattingError.networkError("Connection lost")
        XCTAssertTrue(error.isRetryable)
    }

    func testFormattingServerErrorIsRetryable() {
        let error = FormattingError.serverError(500)
        XCTAssertTrue(error.isRetryable)
    }

    func testFormattingRateLimitedIsRetryable() {
        let error = FormattingError.rateLimited
        XCTAssertTrue(error.isRetryable)
    }

    func testFormattingMissingAPIKeyIsNotRetryable() {
        let error = FormattingError.missingAPIKey
        XCTAssertFalse(error.isRetryable)
    }

    func testFormattingEmptyTextIsNotRetryable() {
        let error = FormattingError.emptyText
        XCTAssertFalse(error.isRetryable)
    }
}
