// ExecutionEngineTests.swift
// Tests for ExecutionEngine using mock LLMProvider and mock AccessibilityController.
// No real AX APIs or network calls are made.

import XCTest
@testable import AssistiveControlApp

// MARK: - Mock AccessibilityController

final class MockAccessibilityController: AccessibilityControlling {

    enum Call: Equatable {
        case openApplication(bundleIdentifier: String)
        case clickElement(applicationName: String, label: String, role: String?)
        case typeText(String)
    }

    var calls: [Call] = []
    var shouldThrow: ExecutionError? = nil

    func openApplication(bundleIdentifier: String) throws {
        if let error = shouldThrow { throw error }
        calls.append(.openApplication(bundleIdentifier: bundleIdentifier))
    }

    func clickElement(applicationName: String, label: String, role: String?) throws {
        if let error = shouldThrow { throw error }
        calls.append(.clickElement(applicationName: applicationName, label: label, role: role))
    }

    func typeText(_ text: String) throws {
        if let error = shouldThrow { throw error }
        calls.append(.typeText(text))
    }
}

// MARK: - Tests

final class ExecutionEngineTests: XCTestCase {

    private var registry: ActionRegistry!
    private var mock: MockAccessibilityController!
    private var engine: ExecutionEngine!

    override func setUp() {
        super.setUp()
        registry = ActionRegistry()
        mock = MockAccessibilityController()
        engine = ExecutionEngine(registry: registry, accessibilityController: mock)
    }

    // MARK: - open_application dispatch

    func test_openApplication_callsController() async {
        let intent = Intent(intent: "open_application", parameters: ["bundle_identifier": "com.apple.safari"], confidence: nil)
        let result = await engine.execute(intent)
        XCTAssertEqual(result, .success)
        XCTAssertEqual(mock.calls, [.openApplication(bundleIdentifier: "com.apple.safari")])
    }

    // MARK: - click_element dispatch

    func test_clickElement_callsController_withOptionalRole() async {
        let intent = Intent(
            intent: "click_element",
            parameters: ["application_name": "Safari", "element_label": "OK", "role": "AXButton"],
            confidence: nil
        )
        let result = await engine.execute(intent)
        XCTAssertEqual(result, .success)
        XCTAssertEqual(mock.calls, [.clickElement(applicationName: "Safari", label: "OK", role: "AXButton")])
    }

    func test_clickElement_callsController_withoutRole() async {
        let intent = Intent(
            intent: "click_element",
            parameters: ["application_name": "Safari", "element_label": "Submit"],
            confidence: nil
        )
        let result = await engine.execute(intent)
        XCTAssertEqual(result, .success)
        XCTAssertEqual(mock.calls, [.clickElement(applicationName: "Safari", label: "Submit", role: nil)])
    }

    // MARK: - type_text dispatch

    func test_typeText_callsController() async {
        let intent = Intent(intent: "type_text", parameters: ["text": "Hello world"], confidence: nil)
        let result = await engine.execute(intent)
        XCTAssertEqual(result, .success)
        XCTAssertEqual(mock.calls, [.typeText("Hello world")])
    }

    // MARK: - Unknown intent returns failure

    func test_unknownIntent_returnsFailure() async {
        let intent = Intent(intent: "fly_to_mars", parameters: [:], confidence: nil)
        let result = await engine.execute(intent)
        guard case .failure = result else {
            XCTFail("Expected .failure for unknown intent")
            return
        }
        XCTAssertTrue(mock.calls.isEmpty)
    }

    // MARK: - Controller error is surfaced as failure

    func test_controllerThrows_returnsFailure() async {
        mock.shouldThrow = .executionFailed("Application not running.")
        let intent = Intent(intent: "open_application", parameters: ["bundle_identifier": "com.example.app"], confidence: nil)
        let result = await engine.execute(intent)
        guard case .failure(let reason) = result else {
            XCTFail("Expected .failure when controller throws")
            return
        }
        XCTAssertTrue(reason.contains("Application not running."))
    }
}

// MARK: - ExecutionResult Equatable

extension ExecutionResult: Equatable {
    public static func == (lhs: ExecutionResult, rhs: ExecutionResult) -> Bool {
        switch (lhs, rhs) {
        case (.success, .success):
            return true
        case (.failure(let a), .failure(let b)):
            return a == b
        default:
            return false
        }
    }
}
