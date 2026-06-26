import XCTest
@testable import AIHelper

final class SafetyUtilsTests: XCTestCase {

    // MARK: - Array Safe Subscript Tests

    func testSafeSubscriptValidIndex() {
        let array = [1, 2, 3, 4, 5]

        XCTAssertEqual(array[safe: 0], 1)
        XCTAssertEqual(array[safe: 2], 3)
        XCTAssertEqual(array[safe: 4], 5)
    }

    func testSafeSubscriptInvalidIndex() {
        let array = [1, 2, 3]

        XCTAssertNil(array[safe: -1])
        XCTAssertNil(array[safe: 3])
        XCTAssertNil(array[safe: 100])
    }

    func testSafeSubscriptEmptyArray() {
        let array: [Int] = []

        XCTAssertNil(array[safe: 0])
        XCTAssertNil(array[safe: -1])
    }

    func testSafeSubscriptWithStrings() {
        let array = ["a", "b", "c"]

        XCTAssertEqual(array[safe: 1], "b")
        XCTAssertNil(array[safe: 5])
    }

    // MARK: - String Truncation Tests

    func testTruncateShortString() {
        let short = "Hello"

        XCTAssertEqual(short.truncated(to: 10), "Hello")
        XCTAssertEqual(short.truncated(to: 5), "Hello")
    }

    func testTruncateLongString() {
        let long = "Hello, World!"

        XCTAssertEqual(long.truncated(to: 8), "Hello...")
        XCTAssertEqual(long.truncated(to: 5), "He...")
    }

    func testTruncateWithCustomTrailing() {
        let text = "Hello, World!"

        XCTAssertEqual(text.truncated(to: 10, trailing: "…"), "Hello, Wo…")
        XCTAssertEqual(text.truncated(to: 8, trailing: ">>"), "Hello,>>")
    }

    func testTruncateExactLength() {
        let text = "Hello"

        XCTAssertEqual(text.truncated(to: 5), "Hello")
        XCTAssertEqual(text.truncated(to: 4), "H...")
    }

    func testTruncateEmptyString() {
        let empty = ""

        XCTAssertEqual(empty.truncated(to: 10), "")
        XCTAssertEqual(empty.truncated(to: 0), "")
    }

    // MARK: - UserDefaults Safe Decode Tests

    func testSafeDecodeValidData() {
        let defaults = UserDefaults.standard
        let key = "test_safe_decode_valid"

        // Store valid data
        let testData = ["item1", "item2", "item3"]
        let encoded = try! JSONEncoder().encode(testData)
        defaults.set(encoded, forKey: key)

        // Decode
        let decoded = defaults.safeDecode([String].self, forKey: key)

        XCTAssertEqual(decoded, testData)

        // Cleanup
        defaults.removeObject(forKey: key)
    }

    func testSafeDecodeInvalidData() {
        let defaults = UserDefaults.standard
        let key = "test_safe_decode_invalid"

        // Store invalid data (not proper JSON for the expected type)
        defaults.set("not an array".data(using: .utf8), forKey: key)

        // Should return nil and not crash
        let decoded = defaults.safeDecode([String].self, forKey: key)

        XCTAssertNil(decoded)

        // Should also clean up the corrupted data
        XCTAssertNil(defaults.data(forKey: key))
    }

    func testSafeDecodeMissingKey() {
        let defaults = UserDefaults.standard
        let key = "test_safe_decode_missing_\(UUID().uuidString)"

        let decoded = defaults.safeDecode([String].self, forKey: key)

        XCTAssertNil(decoded)
    }

    func testSafeEncodeValidData() {
        let defaults = UserDefaults.standard
        let key = "test_safe_encode_valid"

        let testData = ["encoded1", "encoded2"]

        // Should not crash
        defaults.safeEncode(testData, forKey: key)

        // Verify it was stored correctly
        let decoded = defaults.safeDecode([String].self, forKey: key)
        XCTAssertEqual(decoded, testData)

        // Cleanup
        defaults.removeObject(forKey: key)
    }

    func testSafeEncodeComplexTypes() {
        let defaults = UserDefaults.standard
        let key = "test_safe_encode_complex"

        struct TestStruct: Codable, Equatable {
            let id: UUID
            let name: String
            let count: Int
        }

        let testData = TestStruct(id: UUID(), name: "Test", count: 42)

        defaults.safeEncode(testData, forKey: key)

        let decoded = defaults.safeDecode(TestStruct.self, forKey: key)
        XCTAssertEqual(decoded, testData)

        // Cleanup
        defaults.removeObject(forKey: key)
    }

    // MARK: - safeExecute Tests

    func testSafeExecuteSuccess() {
        let result = safeExecute("test operation") {
            return 42
        }

        XCTAssertEqual(result, 42)
    }

    func testSafeExecuteFailure() {
        enum TestError: Error {
            case testFailure
        }

        let result: Int? = safeExecute("failing operation") {
            throw TestError.testFailure
        }

        XCTAssertNil(result)
    }

    func testSafeExecuteWithVoidReturn() {
        var sideEffect = false

        let result: Void? = safeExecute("void operation") {
            sideEffect = true
        }

        XCTAssertNotNil(result)
        XCTAssertTrue(sideEffect)
    }

    // MARK: - safeExecuteAsync Tests

    func testSafeExecuteAsyncSuccess() async {
        let result = await safeExecuteAsync("async test") {
            return "success"
        }

        XCTAssertEqual(result, "success")
    }

    func testSafeExecuteAsyncFailure() async {
        enum TestError: Error {
            case asyncFailure
        }

        let result: String? = await safeExecuteAsync("async failing") {
            throw TestError.asyncFailure
        }

        XCTAssertNil(result)
    }

    func testSafeExecuteAsyncWithDelay() async {
        let result = await safeExecuteAsync("async delayed") {
            try await Task.sleep(nanoseconds: 1_000_000) // 1ms
            return 123
        }

        XCTAssertEqual(result, 123)
    }
}
