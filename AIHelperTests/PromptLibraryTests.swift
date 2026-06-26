import XCTest
@testable import AIHelper

final class PromptLibraryTests: XCTestCase {

    var library: PromptLibrary!

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        library = PromptLibrary.shared
        library.resetToDefaults()
    }

    // MARK: - Built-in Prompts Tests

    @MainActor
    func testBuiltInPromptsExist() {
        XCTAssertFalse(library.prompts.isEmpty, "Library should have built-in prompts")
        XCTAssertGreaterThanOrEqual(library.prompts.count, 15, "Should have at least 15 built-in prompts")
    }

    @MainActor
    func testAllCategoriesHavePrompts() {
        let promptsByCategory = library.promptsByCategory()

        // Core categories should have prompts
        XCTAssertNotNil(promptsByCategory[.codeReview], "Code Review category should have prompts")
        XCTAssertNotNil(promptsByCategory[.security], "Security category should have prompts")
        XCTAssertNotNil(promptsByCategory[.testing], "Testing category should have prompts")
        XCTAssertNotNil(promptsByCategory[.documentation], "Documentation category should have prompts")
    }

    @MainActor
    func testBuiltInPromptsHaveShortcuts() {
        let promptsWithShortcuts = library.prompts.filter { $0.shortcut != nil }
        XCTAssertGreaterThan(promptsWithShortcuts.count, 10, "Most built-in prompts should have shortcuts")
    }

    // MARK: - Search Tests

    @MainActor
    func testSearchByShortcut() {
        let results = library.search(query: "review")
        XCTAssertFalse(results.isEmpty, "Should find prompts with 'review' shortcut")

        // First result should have exact shortcut match
        if let firstResult = results.first {
            XCTAssertEqual(firstResult.shortcut, "review", "First result should be exact shortcut match")
        }
    }

    @MainActor
    func testSearchByName() {
        let results = library.search(query: "security")
        XCTAssertFalse(results.isEmpty, "Should find security-related prompts")
    }

    @MainActor
    func testSearchByCategory() {
        let results = library.search(query: "Code Review")
        XCTAssertFalse(results.isEmpty, "Should find prompts in Code Review category")
    }

    @MainActor
    func testSearchEmptyQuery() {
        let results = library.search(query: "")
        XCTAssertEqual(results.count, library.prompts.count, "Empty query should return all prompts")
    }

    @MainActor
    func testSearchNoResults() {
        let results = library.search(query: "xyznonexistent123")
        XCTAssertTrue(results.isEmpty, "Nonsense query should return no results")
    }

    @MainActor
    func testSearchIsCaseInsensitive() {
        let lowercaseResults = library.search(query: "security")
        let uppercaseResults = library.search(query: "SECURITY")
        let mixedCaseResults = library.search(query: "SeCuRiTy")

        XCTAssertEqual(lowercaseResults.count, uppercaseResults.count, "Search should be case insensitive")
        XCTAssertEqual(lowercaseResults.count, mixedCaseResults.count, "Search should be case insensitive")
    }

    // MARK: - Custom Prompt Tests

    @MainActor
    func testAddCustomPrompt() {
        let initialCount = library.prompts.count

        let customPrompt = Prompt(
            name: "Test Custom Prompt",
            category: .custom,
            shortcut: "testcustom",
            content: "This is a test prompt content",
            description: "A test prompt for unit testing",
            isBuiltIn: false
        )

        library.addPrompt(customPrompt)

        XCTAssertEqual(library.prompts.count, initialCount + 1, "Prompt count should increase by 1")
        XCTAssertTrue(library.prompts.contains(where: { $0.id == customPrompt.id }), "Library should contain the new prompt")
    }

    @MainActor
    func testDeleteCustomPrompt() {
        let customPrompt = Prompt(
            name: "To Be Deleted",
            category: .custom,
            content: "Delete me",
            description: "Will be deleted"
        )

        library.addPrompt(customPrompt)
        let countAfterAdd = library.prompts.count

        library.deletePrompt(customPrompt)

        XCTAssertEqual(library.prompts.count, countAfterAdd - 1, "Prompt count should decrease by 1")
        XCTAssertFalse(library.prompts.contains(where: { $0.id == customPrompt.id }), "Deleted prompt should not exist")
    }

    @MainActor
    func testUpdatePrompt() {
        let customPrompt = Prompt(
            name: "Original Name",
            category: .custom,
            content: "Original content",
            description: "Original description"
        )

        library.addPrompt(customPrompt)

        var updatedPrompt = customPrompt
        updatedPrompt.name = "Updated Name"
        updatedPrompt.content = "Updated content"

        library.updatePrompt(updatedPrompt)

        if let found = library.prompts.first(where: { $0.id == customPrompt.id }) {
            XCTAssertEqual(found.name, "Updated Name", "Name should be updated")
            XCTAssertEqual(found.content, "Updated content", "Content should be updated")
        } else {
            XCTFail("Updated prompt should exist in library")
        }
    }

    // MARK: - Recently Used Tests

    @MainActor
    func testMarkAsUsed() {
        guard let prompt = library.prompts.first else {
            XCTFail("Should have at least one prompt")
            return
        }

        library.markAsUsed(prompt)

        let recentPrompts = library.getRecentPrompts()
        XCTAssertFalse(recentPrompts.isEmpty, "Should have recently used prompts")
        XCTAssertEqual(recentPrompts.first?.id, prompt.id, "Most recent should be the one we just used")
    }

    @MainActor
    func testRecentlyUsedLimit() {
        // Mark 10 prompts as used
        for prompt in library.prompts.prefix(10) {
            library.markAsUsed(prompt)
        }

        let recentPrompts = library.getRecentPrompts()
        XCTAssertLessThanOrEqual(recentPrompts.count, 5, "Recently used should be limited to 5")
    }

    @MainActor
    func testRecentlyUsedOrder() {
        let prompts = Array(library.prompts.prefix(3))

        library.markAsUsed(prompts[0])
        library.markAsUsed(prompts[1])
        library.markAsUsed(prompts[2])

        let recentPrompts = library.getRecentPrompts()

        XCTAssertEqual(recentPrompts[0].id, prompts[2].id, "Most recently used should be first")
        XCTAssertEqual(recentPrompts[1].id, prompts[1].id, "Second most recently used should be second")
        XCTAssertEqual(recentPrompts[2].id, prompts[0].id, "Third most recently used should be third")
    }

    // MARK: - Reset Tests

    @MainActor
    func testResetToDefaults() {
        // Add a custom prompt
        let customPrompt = Prompt(
            name: "Custom",
            category: .custom,
            content: "Custom content",
            description: "Custom"
        )
        library.addPrompt(customPrompt)

        // Reset
        library.resetToDefaults()

        // Custom prompt should be gone
        XCTAssertFalse(library.prompts.contains(where: { $0.id == customPrompt.id }), "Custom prompt should be removed after reset")

        // Should only have built-in prompts
        XCTAssertEqual(library.prompts.count, PromptLibrary.builtInPrompts.count, "Should have only built-in prompts after reset")
    }

    // MARK: - Prompt Model Tests

    func testPromptEquality() {
        let prompt1 = Prompt(
            name: "Test",
            category: .codeReview,
            content: "Content",
            description: "Description"
        )

        let prompt2 = Prompt(
            id: prompt1.id,
            name: "Different Name",
            category: .security,
            content: "Different Content",
            description: "Different Description"
        )

        XCTAssertEqual(prompt1.id, prompt2.id, "Prompts with same ID should be identifiable as same")
    }

    func testPromptCodable() throws {
        let prompt = Prompt(
            name: "Codable Test",
            category: .testing,
            shortcut: "codable",
            content: "Test content",
            description: "Test description",
            isBuiltIn: false
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(prompt)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Prompt.self, from: data)

        XCTAssertEqual(prompt.id, decoded.id)
        XCTAssertEqual(prompt.name, decoded.name)
        XCTAssertEqual(prompt.category, decoded.category)
        XCTAssertEqual(prompt.shortcut, decoded.shortcut)
        XCTAssertEqual(prompt.content, decoded.content)
        XCTAssertEqual(prompt.description, decoded.description)
        XCTAssertEqual(prompt.isBuiltIn, decoded.isBuiltIn)
    }

    // MARK: - Category Tests

    func testAllCategoriesHaveIcons() {
        for category in PromptCategory.allCases {
            XCTAssertFalse(category.icon.isEmpty, "\(category.rawValue) should have an icon")
        }
    }

    func testCategoryRawValues() {
        XCTAssertEqual(PromptCategory.codeReview.rawValue, "Code Review")
        XCTAssertEqual(PromptCategory.security.rawValue, "Security")
        XCTAssertEqual(PromptCategory.testing.rawValue, "Testing")
        XCTAssertEqual(PromptCategory.documentation.rawValue, "Documentation")
        XCTAssertEqual(PromptCategory.refactoring.rawValue, "Refactoring")
        XCTAssertEqual(PromptCategory.debugging.rawValue, "Debugging")
        XCTAssertEqual(PromptCategory.architecture.rawValue, "Architecture")
        XCTAssertEqual(PromptCategory.git.rawValue, "Git & PRs")
        XCTAssertEqual(PromptCategory.custom.rawValue, "Custom")
    }
}
