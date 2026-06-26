import XCTest
@testable import AIHelper

final class WhisperServiceTests: XCTestCase {

    // MARK: - WhisperError Tests

    func testAllErrorsHaveDescriptions() {
        let errors: [WhisperError] = [
            .missingAPIKey,
            .invalidAPIKey,
            .invalidResponse,
            .audioFileNotFound,
            .audioFileReadError("test error"),
            .audioFileTooLarge,
            .networkError("connection failed"),
            .rateLimited,
            .serverError(500),
            .decodingError("invalid json"),
            .apiError("rate limit exceeded")
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "\(error) should have error description")
            XCTAssertFalse(error.errorDescription!.isEmpty, "\(error) should have non-empty description")
        }
    }

    func testMissingAPIKeyError() {
        let error = WhisperError.missingAPIKey
        XCTAssertTrue(error.errorDescription!.lowercased().contains("api key"))
        XCTAssertTrue(error.errorDescription!.lowercased().contains("settings"))
    }

    func testInvalidAPIKeyError() {
        let error = WhisperError.invalidAPIKey
        XCTAssertTrue(error.errorDescription!.lowercased().contains("invalid"))
    }

    func testAudioFileNotFoundError() {
        let error = WhisperError.audioFileNotFound
        XCTAssertTrue(error.errorDescription!.lowercased().contains("not found"))
    }

    func testAudioFileTooLargeError() {
        let error = WhisperError.audioFileTooLarge
        XCTAssertTrue(error.errorDescription!.lowercased().contains("25mb") ||
                      error.errorDescription!.lowercased().contains("too large"))
    }

    func testRateLimitedError() {
        let error = WhisperError.rateLimited
        XCTAssertTrue(error.errorDescription!.lowercased().contains("rate") ||
                      error.errorDescription!.lowercased().contains("wait"))
    }

    func testServerErrorIncludesCode() {
        let error = WhisperError.serverError(503)
        XCTAssertTrue(error.errorDescription!.contains("503"))
    }

    func testNetworkErrorIncludesMessage() {
        let message = "Connection timed out"
        let error = WhisperError.networkError(message)
        XCTAssertTrue(error.errorDescription!.contains(message))
    }

    func testAPIErrorIncludesMessage() {
        let message = "Invalid audio format"
        let error = WhisperError.apiError(message)
        XCTAssertTrue(error.errorDescription!.contains(message))
    }

    func testDecodingErrorIncludesMessage() {
        let message = "Missing 'text' field"
        let error = WhisperError.decodingError(message)
        XCTAssertTrue(error.errorDescription!.contains(message))
    }

    // MARK: - WhisperResponse Tests

    func testWhisperResponseDecoding() throws {
        let json = """
        {"text": "Hello, world!"}
        """
        let data = json.data(using: .utf8)!

        let response = try JSONDecoder().decode(WhisperResponse.self, from: data)
        XCTAssertEqual(response.text, "Hello, world!")
    }

    func testWhisperResponseDecodingWithEmptyText() throws {
        let json = """
        {"text": ""}
        """
        let data = json.data(using: .utf8)!

        let response = try JSONDecoder().decode(WhisperResponse.self, from: data)
        XCTAssertEqual(response.text, "")
    }

    func testWhisperResponseDecodingWithSpecialCharacters() throws {
        let json = """
        {"text": "Hello 🌍! Special: <>&\\"'"}
        """
        let data = json.data(using: .utf8)!

        let response = try JSONDecoder().decode(WhisperResponse.self, from: data)
        XCTAssertTrue(response.text.contains("🌍"))
    }

    func testWhisperResponseDecodingFailsWithMissingText() {
        let json = """
        {"result": "Hello"}
        """
        let data = json.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(WhisperResponse.self, from: data))
    }

    func testWhisperResponseDecodingFailsWithInvalidJSON() {
        let json = "not valid json"
        let data = json.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(WhisperResponse.self, from: data))
    }

    // MARK: - File Validation Tests (via error types)

    func testAudioFileReadErrorIncludesReason() {
        let reason = "Permission denied"
        let error = WhisperError.audioFileReadError(reason)
        XCTAssertTrue(error.errorDescription!.contains(reason))
    }
}
