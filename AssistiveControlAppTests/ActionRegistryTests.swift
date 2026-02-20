// ActionRegistryTests.swift
// Tests for ActionRegistry — risk classification and descriptor availability.

import XCTest
@testable import AssistiveControlApp

final class ActionRegistryTests: XCTestCase {

    private var registry: ActionRegistry!

    override func setUp() {
        super.setUp()
        registry = ActionRegistry()
    }

    // MARK: - Risk levels for v1 intents

    func test_openApplication_isHarmless() {
        XCTAssertEqual(registry.riskLevel(for: "open_application"), .harmless)
    }

    func test_clickElement_isHarmless() {
        XCTAssertEqual(registry.riskLevel(for: "click_element"), .harmless)
    }

    func test_typeText_isHarmless() {
        XCTAssertEqual(registry.riskLevel(for: "type_text"), .harmless)
    }

    func test_unknownIntent_returnsNil() {
        XCTAssertNil(registry.riskLevel(for: "delete_file"))
        XCTAssertNil(registry.riskLevel(for: ""))
        XCTAssertNil(registry.riskLevel(for: "run_shell"))
    }

    // MARK: - Available descriptors

    func test_availableActions_containsAllV1Intents() {
        let names = registry.availableActions().map { $0.name }
        XCTAssertTrue(names.contains("open_application"))
        XCTAssertTrue(names.contains("click_element"))
        XCTAssertTrue(names.contains("type_text"))
    }

    func test_openApplication_descriptor_requiredParameters() {
        let desc = registry.descriptor(for: "open_application")
        XCTAssertNotNil(desc)
        XCTAssertTrue(desc!.requiredParameters.contains("bundle_identifier"))
    }

    func test_clickElement_descriptor_requiredParameters() {
        let desc = registry.descriptor(for: "click_element")
        XCTAssertNotNil(desc)
        XCTAssertTrue(desc!.requiredParameters.contains("application_name"))
        XCTAssertTrue(desc!.requiredParameters.contains("element_label"))
        XCTAssertTrue(desc!.optionalParameters.contains("role"))
    }

    func test_typeText_descriptor_requiredParameters() {
        let desc = registry.descriptor(for: "type_text")
        XCTAssertNotNil(desc)
        XCTAssertTrue(desc!.requiredParameters.contains("text"))
    }

    func test_unknownIntent_descriptorIsNil() {
        XCTAssertNil(registry.descriptor(for: "unknown_action"))
    }
}
