// LocalLLMProviderDecodeTests.swift
// Tests for LocalLLMProvider.decodeIntent — the LLM output isolation boundary.
// No network calls are made.

import XCTest
@testable import AssistiveControlApp

final class LocalLLMProviderDecodeTests: XCTestCase {

    private var provider: LocalLLMProvider!

    override func setUp() {
        super.setUp()
        // baseURL and model don't matter — we're testing decodeIntent directly.
        provider = LocalLLMProvider()
    }

    // MARK: - Valid JSON

    func test_validIntent_decodesCorrectly() throws {
        let raw = """
        {"intent": "open_application", "parameters": {"bundle_identifier": "com.apple.safari"}, "confidence": 0.95}
        """
        let intent = try provider.decodeIntent(raw)
        XCTAssertEqual(intent.intent, "open_application")
        XCTAssertEqual(intent.parameters["bundle_identifier"], "com.apple.safari")
        XCTAssertEqual(intent.confidence, 0.95)
    }

    func test_validIntent_nilConfidence() throws {
        let raw = """
        {"intent": "type_text", "parameters": {"text": "hello"}}
        """
        let intent = try provider.decodeIntent(raw)
        XCTAssertEqual(intent.intent, "type_text")
        XCTAssertNil(intent.confidence)
    }

    func test_unsupportedIntent_decodesCorrectly() throws {
        let raw = """
        {"intent": "unsupported", "parameters": {}}
        """
        let intent = try provider.decodeIntent(raw)
        XCTAssertEqual(intent.intent, "unsupported")
        XCTAssertTrue(intent.parameters.isEmpty)
    }

    // MARK: - Markdown code fences (model sometimes wraps output)

    func test_markdownFences_stripped() throws {
        let raw = """
        ```json
        {"intent": "open_application", "parameters": {"bundle_identifier": "com.apple.finder"}, "confidence": 0.9}
        ```
        """
        let intent = try provider.decodeIntent(raw)
        XCTAssertEqual(intent.intent, "open_application")
    }

    func test_plainFences_stripped() throws {
        let raw = """
        ```
        {"intent": "type_text", "parameters": {"text": "world"}}
        ```
        """
        let intent = try provider.decodeIntent(raw)
        XCTAssertEqual(intent.intent, "type_text")
    }

    // MARK: - Malformed / invalid input

    func test_invalidJSON_throws() {
        let raw = "this is not json at all"
        XCTAssertThrowsError(try provider.decodeIntent(raw)) { error in
            guard case LLMProviderError.parseError = error else {
                XCTFail("Expected LLMProviderError.parseError, got \(error)")
                return
            }
        }
    }

    func test_emptyString_throws() {
        XCTAssertThrowsError(try provider.decodeIntent("")) { error in
            guard case LLMProviderError.parseError = error else {
                XCTFail("Expected LLMProviderError.parseError")
                return
            }
        }
    }

    func test_proseOnly_throws() {
        let raw = "I think you want to open Safari. Let me do that for you!"
        XCTAssertThrowsError(try provider.decodeIntent(raw)) { error in
            guard case LLMProviderError.parseError = error else {
                XCTFail("Expected LLMProviderError.parseError")
                return
            }
        }
    }

    func test_missingIntentField_throws() {
        // JSON object but missing the required "intent" key.
        let raw = """
        {"parameters": {"bundle_identifier": "com.apple.safari"}, "confidence": 0.9}
        """
        XCTAssertThrowsError(try provider.decodeIntent(raw)) { error in
            guard case LLMProviderError.parseError = error else {
                XCTFail("Expected LLMProviderError.parseError for missing 'intent' field")
                return
            }
        }
    }

    func test_missingParametersField_throws() {
        // "parameters" is required by the Codable struct.
        let raw = """
        {"intent": "open_application"}
        """
        XCTAssertThrowsError(try provider.decodeIntent(raw)) { error in
            guard case LLMProviderError.parseError = error else {
                XCTFail("Expected LLMProviderError.parseError for missing 'parameters' field")
                return
            }
        }
    }

    func test_jsonArray_throws() {
        let raw = """
        [{"intent": "open_application", "parameters": {}}]
        """
        XCTAssertThrowsError(try provider.decodeIntent(raw)) { error in
            guard case LLMProviderError.parseError = error else {
                XCTFail("Expected LLMProviderError.parseError for JSON array")
                return
            }
        }
    }
}
