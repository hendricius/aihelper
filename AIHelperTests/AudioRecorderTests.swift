import XCTest
@testable import AIHelper

final class AudioRecorderTests: XCTestCase {

    var recorder: AudioRecorder!

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        recorder = AudioRecorder()
    }

    @MainActor
    override func tearDown() async throws {
        recorder.cancelRecording()
        recorder = nil
        try await super.tearDown()
    }

    // MARK: - Initial State Tests

    @MainActor
    func testInitialState() {
        XCTAssertFalse(recorder.isRecording, "Should not be recording initially")
        XCTAssertEqual(recorder.recordingTime, 0, "Recording time should be 0 initially")
        XCTAssertNil(recorder.lastError, "Should have no error initially")
    }

    // MARK: - Recording State Tests

    @MainActor
    func testCancelRecordingWhenNotRecording() {
        // Should not crash when canceling without recording
        recorder.cancelRecording()

        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recorder.recordingTime, 0)
    }

    @MainActor
    func testStopRecordingWhenNotRecording() {
        // Should return nil when not recording
        let url = recorder.stopRecording()

        XCTAssertNil(url, "Should return nil when stopping without recording")
        XCTAssertFalse(recorder.isRecording)
    }

    @MainActor
    func testMultipleCancelCalls() {
        // Should not crash with multiple cancel calls
        recorder.cancelRecording()
        recorder.cancelRecording()
        recorder.cancelRecording()

        XCTAssertFalse(recorder.isRecording)
    }

    @MainActor
    func testMultipleStopCalls() {
        // Should not crash with multiple stop calls
        _ = recorder.stopRecording()
        _ = recorder.stopRecording()
        _ = recorder.stopRecording()

        XCTAssertFalse(recorder.isRecording)
    }

    // MARK: - RecordingError Tests

    func testRecordingErrorDescriptions() {
        let errors: [RecordingError] = [
            .invalidURL,
            .permissionDenied,
            .preparationFailed,
            .recordingFailed,
            .recordingInterrupted,
            .recorderCreationFailed("test error"),
            .encodingFailed("encoding issue")
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "\(error) should have description")
            XCTAssertFalse(error.errorDescription!.isEmpty, "\(error) should have non-empty description")
        }
    }

    func testRecordingErrorEquality() {
        XCTAssertEqual(RecordingError.invalidURL, RecordingError.invalidURL)
        XCTAssertEqual(RecordingError.permissionDenied, RecordingError.permissionDenied)
        XCTAssertEqual(RecordingError.preparationFailed, RecordingError.preparationFailed)
        XCTAssertEqual(RecordingError.recordingFailed, RecordingError.recordingFailed)
        XCTAssertEqual(RecordingError.recordingInterrupted, RecordingError.recordingInterrupted)
    }

    func testRecordingErrorEqualityWithMessages() {
        let error1 = RecordingError.recorderCreationFailed("message")
        let error2 = RecordingError.recorderCreationFailed("message")
        let error3 = RecordingError.recorderCreationFailed("different")

        XCTAssertEqual(error1, error2)
        XCTAssertNotEqual(error1, error3)
    }

    func testRecordingErrorEncodingEqualityWithMessages() {
        let error1 = RecordingError.encodingFailed("reason")
        let error2 = RecordingError.encodingFailed("reason")
        let error3 = RecordingError.encodingFailed("other")

        XCTAssertEqual(error1, error2)
        XCTAssertNotEqual(error1, error3)
    }

    func testRecordingErrorInequality() {
        XCTAssertNotEqual(RecordingError.invalidURL, RecordingError.permissionDenied)
        XCTAssertNotEqual(RecordingError.preparationFailed, RecordingError.recordingFailed)
        XCTAssertNotEqual(
            RecordingError.recorderCreationFailed("a"),
            RecordingError.encodingFailed("a")
        )
    }

    func testPermissionDeniedErrorContainsUsefulInfo() {
        let error = RecordingError.permissionDenied

        XCTAssertTrue(
            error.errorDescription!.lowercased().contains("microphone") ||
            error.errorDescription!.lowercased().contains("access") ||
            error.errorDescription!.lowercased().contains("settings"),
            "Permission error should mention microphone/access/settings"
        )
    }

    func testRecorderCreationFailedIncludesMessage() {
        let message = "Audio hardware not available"
        let error = RecordingError.recorderCreationFailed(message)

        XCTAssertTrue(error.errorDescription!.contains(message))
    }

    func testEncodingFailedIncludesMessage() {
        let message = "Codec not supported"
        let error = RecordingError.encodingFailed(message)

        XCTAssertTrue(error.errorDescription!.contains(message))
    }

    // MARK: - State Consistency Tests

    @MainActor
    func testStateConsistencyAfterCancel() {
        recorder.cancelRecording()

        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recorder.recordingTime, 0)
    }

    @MainActor
    func testStateConsistencyAfterStop() {
        _ = recorder.stopRecording()

        XCTAssertFalse(recorder.isRecording)
    }
}

// MARK: - WhisperError Extended Tests (moved from AudioRecorderTests)

final class WhisperErrorExtendedTests: XCTestCase {

    func testMissingAPIKeyError() {
        let error = WhisperError.missingAPIKey
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("api key"))
    }

    func testInvalidAPIKeyError() {
        let error = WhisperError.invalidAPIKey
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("invalid"))
    }

    func testInvalidResponseError() {
        let error = WhisperError.invalidResponse
        XCTAssertNotNil(error.errorDescription)
    }

    func testAPIErrorWithMessage() {
        let error = WhisperError.apiError("Rate limit exceeded")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("Rate limit exceeded"))
    }

    func testAllErrorsAreLocalizedErrors() {
        let errors: [WhisperError] = [
            .missingAPIKey,
            .invalidAPIKey,
            .invalidResponse,
            .audioFileNotFound,
            .audioFileReadError("test"),
            .audioFileTooLarge,
            .networkError("test"),
            .rateLimited,
            .serverError(500),
            .decodingError("test"),
            .apiError("Test error")
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "\(error) should have error description")
        }
    }
}
