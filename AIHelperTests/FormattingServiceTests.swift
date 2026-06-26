import XCTest
@testable import AIHelper

final class FormattingServiceTests: XCTestCase {

    // MARK: - FormattingError Tests

    func testAllErrorsHaveDescriptions() {
        let errors: [FormattingError] = [
            .missingAPIKey,
            .invalidAPIKey,
            .invalidResponse,
            .emptyText,
            .noContent,
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
        let error = FormattingError.missingAPIKey
        XCTAssertTrue(error.errorDescription!.lowercased().contains("api key"))
        XCTAssertTrue(error.errorDescription!.lowercased().contains("settings"))
    }

    func testInvalidAPIKeyError() {
        let error = FormattingError.invalidAPIKey
        XCTAssertTrue(error.errorDescription!.lowercased().contains("invalid"))
    }

    func testEmptyTextError() {
        let error = FormattingError.emptyText
        XCTAssertTrue(error.errorDescription!.lowercased().contains("no text") ||
                      error.errorDescription!.lowercased().contains("empty"))
    }

    func testNoContentError() {
        let error = FormattingError.noContent
        XCTAssertTrue(error.errorDescription!.lowercased().contains("no") ||
                      error.errorDescription!.lowercased().contains("content"))
    }

    func testRateLimitedError() {
        let error = FormattingError.rateLimited
        XCTAssertTrue(error.errorDescription!.lowercased().contains("rate") ||
                      error.errorDescription!.lowercased().contains("wait"))
    }

    func testServerErrorIncludesCode() {
        let error = FormattingError.serverError(503)
        XCTAssertTrue(error.errorDescription!.contains("503"))
    }

    func testNetworkErrorIncludesMessage() {
        let message = "Connection timed out"
        let error = FormattingError.networkError(message)
        XCTAssertTrue(error.errorDescription!.contains(message))
    }

    func testAPIErrorIncludesMessage() {
        let message = "Invalid request format"
        let error = FormattingError.apiError(message)
        XCTAssertTrue(error.errorDescription!.contains(message))
    }

    func testDecodingErrorIncludesMessage() {
        let message = "Missing 'choices' field"
        let error = FormattingError.decodingError(message)
        XCTAssertTrue(error.errorDescription!.contains(message))
    }

    // MARK: - ChatCompletionResponse Tests

    func testChatCompletionResponseDecoding() throws {
        let json = """
        {
            "id": "chatcmpl-123",
            "object": "chat.completion",
            "created": 1677652288,
            "model": "gpt-4o-mini",
            "choices": [{
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": "Hello, this is formatted text."
                },
                "finish_reason": "stop"
            }],
            "usage": {
                "prompt_tokens": 10,
                "completion_tokens": 20,
                "total_tokens": 30
            }
        }
        """
        let data = json.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(ChatCompletionResponse.self, from: data)

        XCTAssertEqual(response.id, "chatcmpl-123")
        XCTAssertEqual(response.model, "gpt-4o-mini")
        XCTAssertEqual(response.choices.count, 1)
        XCTAssertEqual(response.choices.first?.message.content, "Hello, this is formatted text.")
        XCTAssertEqual(response.choices.first?.message.role, "assistant")
        XCTAssertEqual(response.choices.first?.finishReason, "stop")
        XCTAssertEqual(response.usage?.totalTokens, 30)
    }

    func testChatCompletionResponseDecodingWithoutUsage() throws {
        let json = """
        {
            "id": "chatcmpl-456",
            "object": "chat.completion",
            "created": 1677652288,
            "model": "gpt-4o-mini",
            "choices": [{
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": "Formatted output"
                },
                "finish_reason": "stop"
            }]
        }
        """
        let data = json.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(ChatCompletionResponse.self, from: data)

        XCTAssertEqual(response.choices.first?.message.content, "Formatted output")
        XCTAssertNil(response.usage)
    }

    func testChatCompletionResponseDecodingWithEmptyContent() throws {
        let json = """
        {
            "id": "chatcmpl-789",
            "object": "chat.completion",
            "created": 1677652288,
            "model": "gpt-4o-mini",
            "choices": [{
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": ""
                },
                "finish_reason": "stop"
            }]
        }
        """
        let data = json.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(ChatCompletionResponse.self, from: data)

        XCTAssertEqual(response.choices.first?.message.content, "")
    }

    func testChatCompletionResponseDecodingFailsWithMissingChoices() {
        let json = """
        {
            "id": "chatcmpl-123",
            "object": "chat.completion",
            "created": 1677652288,
            "model": "gpt-4o-mini"
        }
        """
        let data = json.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        XCTAssertThrowsError(try decoder.decode(ChatCompletionResponse.self, from: data))
    }

    func testChatCompletionResponseDecodingFailsWithInvalidJSON() {
        let json = "not valid json"
        let data = json.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        XCTAssertThrowsError(try decoder.decode(ChatCompletionResponse.self, from: data))
    }

    // MARK: - ChatMessage Tests

    func testChatMessageDecoding() throws {
        let json = """
        {"role": "user", "content": "Hello world"}
        """
        let data = json.data(using: .utf8)!

        let message = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertEqual(message.role, "user")
        XCTAssertEqual(message.content, "Hello world")
    }

    func testChatMessageEncoding() throws {
        let message = ChatMessage(role: "system", content: "You are a helpful assistant.")

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)

        XCTAssertEqual(decoded.role, "system")
        XCTAssertEqual(decoded.content, "You are a helpful assistant.")
    }

    // MARK: - ChatCompletionRequest Tests

    func testChatCompletionRequestEncoding() throws {
        let request = ChatCompletionRequest(
            model: "gpt-4o-mini",
            messages: [
                ChatMessage(role: "system", content: "Format this text"),
                ChatMessage(role: "user", content: "hello world")
            ],
            temperature: 0.3,
            maxTokens: 4096
        )

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["model"] as? String, "gpt-4o-mini")
        XCTAssertEqual(json?["temperature"] as? Double, 0.3)
        XCTAssertEqual(json?["max_tokens"] as? Int, 4096)
        XCTAssertEqual((json?["messages"] as? [[String: Any]])?.count, 2)
    }

    // MARK: - ChatUsage Tests

    func testChatUsageDecoding() throws {
        let json = """
        {
            "prompt_tokens": 100,
            "completion_tokens": 50,
            "total_tokens": 150
        }
        """
        let data = json.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let usage = try decoder.decode(ChatUsage.self, from: data)

        XCTAssertEqual(usage.promptTokens, 100)
        XCTAssertEqual(usage.completionTokens, 50)
        XCTAssertEqual(usage.totalTokens, 150)
    }

    // MARK: - ChatChoice Tests

    func testChatChoiceDecoding() throws {
        let json = """
        {
            "index": 0,
            "message": {
                "role": "assistant",
                "content": "Improved text here"
            },
            "finish_reason": "stop"
        }
        """
        let data = json.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let choice = try decoder.decode(ChatChoice.self, from: data)

        XCTAssertEqual(choice.index, 0)
        XCTAssertEqual(choice.message.role, "assistant")
        XCTAssertEqual(choice.message.content, "Improved text here")
        XCTAssertEqual(choice.finishReason, "stop")
    }

    func testChatChoiceDecodingWithNullFinishReason() throws {
        let json = """
        {
            "index": 0,
            "message": {
                "role": "assistant",
                "content": "Partial response"
            },
            "finish_reason": null
        }
        """
        let data = json.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let choice = try decoder.decode(ChatChoice.self, from: data)

        XCTAssertEqual(choice.message.content, "Partial response")
        XCTAssertNil(choice.finishReason)
    }
}
