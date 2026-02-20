// IntentValidatorTests.swift
// Tests for IntentValidator — the primary LLM output safety gate.

import XCTest
@testable import AssistiveControlApp

final class IntentValidatorTests: XCTestCase {

    private var validator: IntentValidator!

    override func setUp() {
        super.setUp()
        validator = IntentValidator()
    }

    // MARK: - open_application

    func test_openApplication_valid() {
        let intent = Intent(intent: "open_application", parameters: ["bundle_identifier": "com.apple.safari"], confidence: nil)
        guard case .valid = validator.validate(intent) else {
            XCTFail("Expected .valid for well-formed open_application intent")
            return
        }
    }

    func test_openApplication_missingBundleIdentifier() {
        let intent = Intent(intent: "open_application", parameters: [:], confidence: nil)
        guard case .invalid(let error) = validator.validate(intent),
              case .missingParameter(let key) = error else {
            XCTFail("Expected .invalid(.missingParameter)")
            return
        }
        XCTAssertEqual(key, "bundle_identifier")
    }

    func test_openApplication_emptyBundleIdentifier() {
        let intent = Intent(intent: "open_application", parameters: ["bundle_identifier": "   "], confidence: nil)
        guard case .invalid(let error) = validator.validate(intent),
              case .emptyParameter(let key) = error else {
            XCTFail("Expected .invalid(.emptyParameter)")
            return
        }
        XCTAssertEqual(key, "bundle_identifier")
    }

    // MARK: - click_element

    func test_clickElement_valid() {
        let intent = Intent(
            intent: "click_element",
            parameters: ["application_name": "Safari", "element_label": "OK"],
            confidence: nil
        )
        guard case .valid = validator.validate(intent) else {
            XCTFail("Expected .valid")
            return
        }
    }

    func test_clickElement_missingApplicationName() {
        let intent = Intent(intent: "click_element", parameters: ["element_label": "OK"], confidence: nil)
        guard case .invalid(let error) = validator.validate(intent),
              case .missingParameter(let key) = error else {
            XCTFail("Expected .invalid(.missingParameter)")
            return
        }
        XCTAssertEqual(key, "application_name")
    }

    func test_clickElement_missingElementLabel() {
        let intent = Intent(intent: "click_element", parameters: ["application_name": "Safari"], confidence: nil)
        guard case .invalid(let error) = validator.validate(intent),
              case .missingParameter(let key) = error else {
            XCTFail("Expected .invalid(.missingParameter)")
            return
        }
        XCTAssertEqual(key, "element_label")
    }

    // MARK: - type_text

    func test_typeText_valid() {
        let intent = Intent(intent: "type_text", parameters: ["text": "Hello world"], confidence: nil)
        guard case .valid = validator.validate(intent) else {
            XCTFail("Expected .valid")
            return
        }
    }

    func test_typeText_atExactLimit_valid() {
        let text = String(repeating: "a", count: 500)
        let intent = Intent(intent: "type_text", parameters: ["text": text], confidence: nil)
        guard case .valid = validator.validate(intent) else {
            XCTFail("Expected .valid at exactly 500 characters")
            return
        }
    }

    func test_typeText_exceedsLimit() {
        let text = String(repeating: "a", count: 501)
        let intent = Intent(intent: "type_text", parameters: ["text": text], confidence: nil)
        guard case .invalid(let error) = validator.validate(intent),
              case .textTooLong(let count) = error else {
            XCTFail("Expected .invalid(.textTooLong)")
            return
        }
        XCTAssertEqual(count, 501)
    }

    func test_typeText_missingText() {
        let intent = Intent(intent: "type_text", parameters: [:], confidence: nil)
        guard case .invalid(let error) = validator.validate(intent),
              case .missingParameter = error else {
            XCTFail("Expected .invalid(.missingParameter)")
            return
        }
    }

    // MARK: - Confidence threshold

    func test_confidenceBelowThreshold_rejected() {
        let intent = Intent(intent: "open_application", parameters: ["bundle_identifier": "com.apple.safari"], confidence: 0.59)
        guard case .invalid(let error) = validator.validate(intent),
              case .lowConfidence = error else {
            XCTFail("Expected .invalid(.lowConfidence) for confidence 0.59")
            return
        }
    }

    func test_confidenceExactlyAtThreshold_allowed() {
        // 0.6 is the boundary — exactly 0.6 must pass.
        let intent = Intent(intent: "open_application", parameters: ["bundle_identifier": "com.apple.safari"], confidence: 0.6)
        guard case .valid = validator.validate(intent) else {
            XCTFail("Expected .valid for confidence exactly 0.6")
            return
        }
    }

    func test_confidenceAboveThreshold_allowed() {
        let intent = Intent(intent: "open_application", parameters: ["bundle_identifier": "com.apple.safari"], confidence: 0.95)
        guard case .valid = validator.validate(intent) else {
            XCTFail("Expected .valid for confidence 0.95")
            return
        }
    }

    func test_nilConfidence_allowed() {
        let intent = Intent(intent: "open_application", parameters: ["bundle_identifier": "com.apple.safari"], confidence: nil)
        guard case .valid = validator.validate(intent) else {
            XCTFail("Expected .valid when confidence is nil")
            return
        }
    }

    // MARK: - Unknown intent

    func test_unknownIntent_rejected() {
        let intent = Intent(intent: "delete_file", parameters: [:], confidence: nil)
        guard case .invalid(let error) = validator.validate(intent),
              case .unknownIntent(let name) = error else {
            XCTFail("Expected .invalid(.unknownIntent)")
            return
        }
        XCTAssertEqual(name, "delete_file")
    }

    // MARK: - Unsupported intent

    func test_unsupportedIntent_handledGracefully() {
        let intent = Intent(intent: "unsupported", parameters: [:], confidence: nil)
        guard case .unsupported = validator.validate(intent) else {
            XCTFail("Expected .unsupported result for intent=='unsupported'")
            return
        }
    }
}
