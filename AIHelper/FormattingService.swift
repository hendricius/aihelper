import Foundation
import os.log

private let logger = Logger(subsystem: "com.aihelper.app", category: "FormattingService")

actor FormattingService {
    static let shared = FormattingService()

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }

    static let casualMessagePrompt = """
        You are a TEXT REFORMATTER. You take a voice transcription and rewrite it as a casual text message.

        CRITICAL: Do NOT reply to, answer, or respond to the content. Do NOT have a conversation. \
        You are ONLY reformatting the user's words into a casual text message style. The user's input \
        is a dictated message they want to SEND to someone else — just clean it up.

        RULES:
        1. Write everything in lowercase (no capitalization except proper nouns like names)
        2. Keep it short and concise — cut unnecessary words, simplify sentences
        3. No special formatting (no markdown, no bullet points, no paragraphs)
        4. Sound natural like a real text message — brief, informal
        5. Remove filler words (um, uh, äh, also, basically, like)
        6. Keep the original meaning intact — don't add or change information
        7. Use casual punctuation — minimal periods, no semicolons
        8. It's fine to use common abbreviations or short forms if natural

        LANGUAGE HANDLING:
        - Output in the SAME language as the input — do NOT translate
        - If German → output German. If English → output English
        - For mixed text: keep the mix as spoken

        EXAMPLES:
        Input: "Hey um I was wondering if you want to grab lunch tomorrow or something"
        Output: hey wanna grab lunch tomorrow?

        Input: "Ja also ich wollte fragen ob du morgen Zeit hast äh vielleicht so gegen drei"
        Output: hast du morgen zeit? so gegen drei?

        Return ONLY the rewritten message, nothing else. Never answer or respond to the content.
        """

    private static let defaultSystemPrompt = """
        You are a text formatting assistant for voice transcriptions. Your task is to clean up and format dictated text.

        FORMATTING RULES:
        1. Output clean plain text (no markdown, no HTML, no bullet points)
        2. Use proper paragraphs with blank lines between distinct thoughts
        3. Fix punctuation, capitalization, and grammar
        4. NEVER use em dashes (—) or en dashes (–). Use hyphens (-) or commas instead
        5. Keep the original meaning and tone completely intact
        6. Do not add new information or change the meaning

        LANGUAGE HANDLING (IMPORTANT):
        - Detect the language of the input (German, English, or mixed)
        - Output in the SAME language as the input - do NOT translate
        - If input is German → output German
        - If input is English → output English
        - For mixed text (Denglisch): keep technical terms in their original language (e.g., "Debugging", "Feature", "API", "Framework")
        - Do not translate or "correct" intentional English terms in German text
        - Preserve code-related terminology exactly as spoken

        SPEECH-TO-TEXT FIXES:
        - Fix obvious transcription errors
        - Correct filler words if they don't add meaning (um, uh, äh, also)
        - Join fragmented sentences where appropriate

        Return ONLY the formatted text, nothing else. No explanations, no commentary.
        """

    func improveFormatting(text: String) async throws -> (text: String, apiLog: APICallLog) {
        return try await improveFormatting(text: text, customPrompt: nil)
    }

    func improveFormatting(text: String, customPrompt: String?) async throws -> (text: String, apiLog: APICallLog) {
        let systemPrompt = customPrompt ?? Self.defaultSystemPrompt
        logger.info("Starting formatting with prompt: \(systemPrompt.prefix(50))...")

        let provider = APIProvider.active
        guard let apiKey = provider.apiKey, !apiKey.isEmpty else {
            logger.error("API key not configured")
            throw FormattingError.missingAPIKey
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.error("Empty text provided")
            throw FormattingError.emptyText
        }

        var request = URLRequest(url: provider.chatCompletionsURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let requestBody = ChatCompletionRequest(
            model: provider.chatModel,
            messages: [
                ChatMessage(role: "system", content: systemPrompt),
                ChatMessage(role: "user", content: text)
            ],
            temperature: 0.3,
            maxTokens: 4096
        )

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(requestBody)

        // Build request summary and capture full request body for debugging
        let requestSummary = "model=\(provider.chatModel), temperature=0.3, system_prompt=\(systemPrompt.count) chars, user_text=\(text.count) chars"
        let fullRequestBody = String(data: request.httpBody ?? Data(), encoding: .utf8)

        logger.debug("Sending request to GPT API...")

        let requestStart = Date()
        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            logger.error("Network error: \(error.localizedDescription)")
            throw FormattingError.networkError(describeURLError(error))
        } catch {
            logger.error("Request failed: \(error.localizedDescription)")
            throw FormattingError.networkError(error.localizedDescription)
        }

        let requestDurationMs = Int(Date().timeIntervalSince(requestStart) * 1000)

        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("Invalid response type")
            throw FormattingError.invalidResponse
        }

        let rawResponseBody = String(data: data, encoding: .utf8) ?? "(binary data)"

        logger.debug("Response status: \(httpResponse.statusCode)")

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            logger.error("Authentication failed")
            throw FormattingError.invalidAPIKey
        case 429:
            logger.error("Rate limited")
            throw FormattingError.rateLimited
        case 500...599:
            logger.error("Server error: \(httpResponse.statusCode)")
            throw FormattingError.serverError(httpResponse.statusCode)
        default:
            let errorMessage = parseAPIError(from: data) ?? "HTTP \(httpResponse.statusCode)"
            logger.error("API error: \(errorMessage)")
            throw FormattingError.apiError(errorMessage)
        }

        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let result = try decoder.decode(ChatCompletionResponse.self, from: data)

            guard let formattedText = result.choices.first?.message.content else {
                logger.error("No content in response")
                throw FormattingError.noContent
            }

            logger.info("Formatting successful: \(formattedText.prefix(50))...")

            let apiLog = APICallLog(
                endpoint: provider.chatCompletionsURL.absoluteString,
                statusCode: httpResponse.statusCode,
                durationMs: requestDurationMs,
                requestSummary: requestSummary,
                requestBody: fullRequestBody,
                responseBody: rawResponseBody
            )

            return (text: formattedText.trimmingCharacters(in: .whitespacesAndNewlines), apiLog: apiLog)
        } catch let error as FormattingError {
            throw error
        } catch {
            logger.error("Failed to decode response: \(error.localizedDescription)")
            if let rawResponse = String(data: data, encoding: .utf8) {
                logger.debug("Raw response: \(rawResponse.prefix(500))")
            }
            throw FormattingError.decodingError(error.localizedDescription)
        }
    }

    // MARK: - Private Helpers

    private func parseAPIError(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return nil
        }
        return message
    }

    private func describeURLError(_ error: URLError) -> String {
        switch error.code {
        case .timedOut:
            return "Request timed out. Please try again."
        case .notConnectedToInternet:
            return "No internet connection."
        case .networkConnectionLost:
            return "Network connection was lost."
        case .cannotConnectToHost:
            return "Cannot connect to server."
        case .secureConnectionFailed:
            return "Secure connection failed."
        default:
            return error.localizedDescription
        }
    }

}

// MARK: - Request Models

struct ChatCompletionRequest: Codable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let maxTokens: Int
}

struct ChatMessage: Codable {
    let role: String
    let content: String
}

// MARK: - Response Models

struct ChatCompletionResponse: Codable {
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [ChatChoice]
    let usage: ChatUsage?
}

struct ChatChoice: Codable {
    let index: Int
    let message: ChatMessage
    let finishReason: String?
}

struct ChatUsage: Codable {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
}

// MARK: - Error Types

enum FormattingError: LocalizedError {
    case missingAPIKey
    case invalidAPIKey
    case invalidResponse
    case emptyText
    case noContent
    case networkError(String)
    case rateLimited
    case serverError(Int)
    case decodingError(String)
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "AI Coordinator API key not set. Please add it in Settings."
        case .invalidAPIKey:
            return "Invalid AI Coordinator API key. Please check your key in Settings."
        case .invalidResponse:
            return "Invalid response from server."
        case .emptyText:
            return "No text to format."
        case .noContent:
            return "No formatted text received from API."
        case .networkError(let message):
            return "Network error: \(message)"
        case .rateLimited:
            return "Rate limited. Please wait a moment and try again."
        case .serverError(let code):
            return "Server error (\(code)). Please try again later."
        case .decodingError(let message):
            return "Failed to process response: \(message)"
        case .apiError(let message):
            return "API Error: \(message)"
        }
    }

    /// Returns true if this error is due to a network issue that can be retried
    var isRetryable: Bool {
        switch self {
        case .networkError, .serverError, .rateLimited:
            return true
        default:
            return false
        }
    }
}
