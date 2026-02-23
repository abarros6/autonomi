// AccessibilityController.swift
// Executes validated, risk-classified actions via macOS AXUIElement APIs.
//
// Architecture constraints:
//   - This class assumes Accessibility permission is already granted.
//     PermissionManager is the sole owner of permission state.
//   - No raw screen coordinate injection without justification.
//   - No arbitrary CGEvent injection.
//   - No shell execution, no Process(), no filesystem writes.
//   - 500-char limit is enforced upstream in IntentValidator;
//     asserted here in debug builds as a defence-in-depth check.

import AppKit
import ApplicationServices

/// Protocol for AccessibilityController, enabling mock injection in tests.
protocol AccessibilityControlling {
    func openApplication(bundleIdentifier: String) throws
    func clickElement(applicationName: String, label: String, role: String?) throws
    func typeText(_ text: String) throws
    func pressKey(key: String, modifiers: [String], applicationName: String?) throws
    func rightClickElement(applicationName: String, label: String, role: String?) throws
    func doubleClickElement(applicationName: String, label: String, role: String?) throws
    func scrollInElement(applicationName: String, label: String?, direction: String, amount: Int) throws
    func moveMouse(to point: CGPoint) throws
    func moveMouseToElement(applicationName: String, label: String) throws
    func clickAt(point: CGPoint, count: Int) throws
    func queryFrontmostApp() throws -> String
    func queryScreenElements(applicationName: String?) throws -> String
    func drag(from startPoint: CGPoint, to endPoint: CGPoint) throws
    func dragFromElement(applicationName: String, fromLabel: String, toLabel: String) throws
}

/// Executes AXUIElement actions. Assumes permission is granted before any call.
final class AccessibilityController: AccessibilityControlling {

    private let logger = AppLogger(category: "AccessibilityController")

    // MARK: - Open Application

    /// Launches or activates an application by bundle identifier.
    func openApplication(bundleIdentifier: String) throws {
        logger.info("Opening application: \(bundleIdentifier)")
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            throw ExecutionError.executionFailed("No application found with bundle identifier: \(bundleIdentifier)")
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
    }

    // MARK: - Click Element

    /// Clicks the first AX element matching `label` (and optionally `role`)
    /// in the named application. Traversal order is AX tree order.
    ///
    /// Ambiguity policy: first match wins (spec Section 12).
    func clickElement(applicationName: String, label: String, role: String?) throws {
        logger.info("Clicking element '\(label)' in '\(applicationName)'")

        guard let app = runningApplication(named: applicationName) else {
            throw ExecutionError.executionFailed("Application '\(applicationName)' is not running.")
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        guard let element = findElement(in: axApp, label: label, role: role) else {
            throw ExecutionError.executionFailed("No element found matching label: \(label)")
        }

        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard result == .success else {
            throw ExecutionError.executionFailed("AX press action failed with error code: \(result.rawValue)")
        }
    }

    // MARK: - Type Text

    /// Types text into the currently focused element.
    /// Aborts if the focused element is a secure text field.
    func typeText(_ text: String) throws {
        // Debug-build assertion: the 500-char limit must be enforced upstream.
        assert(text.count <= 500, "typeText called with text exceeding 500 characters — IntentValidator should have rejected this.")

        logger.info("Typing text (\(text.count) chars)")

        // Obtain the system-wide focused element.
        let systemElement = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        let result = AXUIElementCopyAttributeValue(systemElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)

        guard result == .success, let focused = focusedElement else {
            throw ExecutionError.executionFailed("Could not determine focused UI element.")
        }

        // Verify the returned object is actually an AXUIElement before using it.
        guard CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            throw ExecutionError.executionFailed("Focused element has an unexpected type.")
        }
        let axFocused = focused as! AXUIElement

        // Security guard: refuse to type into secure text fields (passwords, etc.).
        var roleValue: AnyObject?
        AXUIElementCopyAttributeValue(axFocused, kAXRoleAttribute as CFString, &roleValue)
        // kAXSecureTextFieldRole = "AXSecureTextField" — using the string literal directly
        // because the C constant is not bridged to Swift in all SDK versions.
        if let role = roleValue as? String, role == "AXSecureTextField" {
            throw ExecutionError.executionFailed("Typing into secure fields is not permitted.")
        }

        // Set the value directly via AX.
        let setResult = AXUIElementSetAttributeValue(
            axFocused,
            kAXValueAttribute as CFString,
            text as CFTypeRef
        )

        if setResult != .success {
            // Fall back to CGEvent keyboard simulation for elements that don't support AXValue.
            try typeViaKeyEvents(text)
        }
    }

    // MARK: - Press Key

    /// Presses a keyboard key with optional modifier keys via CGEvent.
    /// - Parameters:
    ///   - key: Key name ("n", "s", "return", "escape", "tab", "space", "f1"–"f12",
    ///          "left", "right", "up", "down", "delete", "home", "end", "pageup", "pagedown")
    ///   - modifiers: Modifier names: "cmd", "shift", "opt", "ctrl"
    ///   - applicationName: If provided, activates that app before sending the key.
    func pressKey(key: String, modifiers: [String], applicationName: String?) throws {
        logger.info("Pressing key '\(key)' with modifiers \(modifiers)")

        // Optionally activate the target application first.
        if let appName = applicationName {
            guard let app = runningApplication(named: appName) else {
                throw ExecutionError.executionFailed("Application '\(appName)' is not running.")
            }
            app.activate(options: [])
            // Brief yield so the app can become active before the keypress is sent.
            Thread.sleep(forTimeInterval: 0.05)
        }

        guard let keyCode = virtualKeyCode(for: key.lowercased()) else {
            throw ExecutionError.executionFailed("Unknown key name: '\(key)'")
        }

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ExecutionError.executionFailed("Could not create CGEventSource.")
        }

        let flags = modifierFlags(from: modifiers)

        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            throw ExecutionError.executionFailed("Could not create CGEvent for key '\(key)'.")
        }

        keyDown.flags = flags
        keyUp.flags   = flags

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    // MARK: - Right Click Element

    /// Right-clicks the first AX element matching `label` and optional `role`.
    func rightClickElement(applicationName: String, label: String, role: String?) throws {
        logger.info("Right-clicking element '\(label)' in '\(applicationName)'")
        let point = try elementCenter(applicationName: applicationName, label: label, role: role)
        try postMouseEvent(type: .rightMouseDown, button: .right, at: point)
        try postMouseEvent(type: .rightMouseUp, button: .right, at: point)
    }

    // MARK: - Double Click Element

    /// Double-clicks the first AX element matching `label` and optional `role`.
    func doubleClickElement(applicationName: String, label: String, role: String?) throws {
        logger.info("Double-clicking element '\(label)' in '\(applicationName)'")
        let point = try elementCenter(applicationName: applicationName, label: label, role: role)
        try clickAt(point: point, count: 2)
    }

    // MARK: - Scroll

    /// Scrolls inside the given application (optionally targeting a named element).
    /// - Parameters:
    ///   - direction: "up", "down", "left", "right"
    ///   - amount: Number of scroll units (default 3)
    func scrollInElement(applicationName: String, label: String?, direction: String, amount: Int) throws {
        logger.info("Scrolling \(direction) in '\(applicationName)' (amount: \(amount))")

        // Determine the scroll point: named element center or front window center.
        let scrollPoint: CGPoint
        if let label = label, !label.isEmpty {
            scrollPoint = try elementCenter(applicationName: applicationName, label: label, role: nil)
        } else {
            scrollPoint = try applicationWindowCenter(applicationName: applicationName)
        }

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ExecutionError.executionFailed("Could not create CGEventSource.")
        }

        // Scroll units: positive = down/right, negative = up/left for axis1/axis2.
        let units = Int32(amount)
        let (axis1, axis2): (Int32, Int32) = {
            switch direction.lowercased() {
            case "up":    return (-units, 0)
            case "down":  return (units,  0)
            case "left":  return (0, -units)
            case "right": return (0,  units)
            default:      return (-units, 0)
            }
        }()

        guard let scrollEvent = CGEvent(
            scrollWheelEvent2Source: source,
            units: .line,
            wheelCount: 2,
            wheel1: axis1,
            wheel2: axis2,
            wheel3: 0
        ) else {
            throw ExecutionError.executionFailed("Could not create scroll CGEvent.")
        }

        scrollEvent.location = scrollPoint
        scrollEvent.post(tap: .cghidEventTap)
    }

    // MARK: - Move Mouse (coordinates)

    /// Moves the mouse cursor to absolute screen coordinates.
    func moveMouse(to point: CGPoint) throws {
        logger.info("Moving mouse to (\(point.x), \(point.y))")
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                  mouseCursorPosition: point, mouseButton: .left)
        else {
            throw ExecutionError.executionFailed("Could not create mouse-move CGEvent.")
        }
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Move Mouse (element-based)

    /// Moves the mouse cursor to the center of a named AX element.
    func moveMouseToElement(applicationName: String, label: String) throws {
        logger.info("Moving mouse to element '\(label)' in '\(applicationName)'")
        let point = try elementCenter(applicationName: applicationName, label: label, role: nil)
        try moveMouse(to: point)
    }

    // MARK: - Click At Coordinates

    /// Clicks at absolute screen coordinates.
    /// - Parameters:
    ///   - point: Screen position in pixels.
    ///   - count: Number of clicks (1 = single, 2 = double).
    func clickAt(point: CGPoint, count: Int) throws {
        logger.info("Clicking at (\(point.x), \(point.y)) x\(count)")
        for clickNumber in 1...max(1, count) {
            try postMouseEvent(type: .leftMouseDown, button: .left, at: point, clickState: Int32(clickNumber))
            try postMouseEvent(type: .leftMouseUp,   button: .left, at: point, clickState: Int32(clickNumber))
        }
    }

    // MARK: - Query Frontmost App

    /// Returns the localised name of the currently active application.
    func queryFrontmostApp() throws -> String {
        return NSWorkspace.shared.frontmostApplication?.localizedName ?? "No app active"
    }

    // MARK: - Query Screen Elements

    /// Lists up to 50 visible AX element labels and roles in the target application.
    /// Returns a newline-separated string of "<role>: <label>" entries for LLM consumption.
    func queryScreenElements(applicationName: String?) throws -> String {
        let appName: String
        if let name = applicationName, !name.isEmpty {
            appName = name
        } else {
            appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        }

        guard !appName.isEmpty else {
            throw ExecutionError.executionFailed("No application specified and no frontmost app.")
        }
        guard let app = runningApplication(named: appName) else {
            throw ExecutionError.executionFailed("Application '\(appName)' is not running.")
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var results: [String] = []
        collectElements(in: axApp, into: &results, limit: 50)

        if results.isEmpty {
            return "No accessible elements found in \(appName)."
        }
        return results.joined(separator: "\n")
    }

    /// Depth-first traversal collecting "<role>: <label>" strings up to a limit.
    private func collectElements(in element: AXUIElement, into results: inout [String], limit: Int) {
        guard results.count < limit else { return }

        var roleRef: AnyObject?
        var titleRef: AnyObject?
        var descRef: AnyObject?

        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
        AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descRef)

        let role  = roleRef as? String ?? ""
        let label = (titleRef as? String ?? descRef as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if !label.isEmpty {
            results.append("\(role): \(label)")
        }

        guard results.count < limit else { return }

        var childrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement]
        else { return }

        for child in children {
            collectElements(in: child, into: &results, limit: limit)
            if results.count >= limit { break }
        }
    }

    // MARK: - Drag (coordinate-based)

    /// Drags from startPoint to endPoint using CGEvent mouse simulation.
    func drag(from startPoint: CGPoint, to endPoint: CGPoint) throws {
        logger.info("Dragging from (\(startPoint.x), \(startPoint.y)) to (\(endPoint.x), \(endPoint.y))")

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ExecutionError.executionFailed("Could not create CGEventSource for drag.")
        }

        guard
            let mouseDown = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                    mouseCursorPosition: startPoint, mouseButton: .left),
            let mouseDrag = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged,
                                    mouseCursorPosition: endPoint, mouseButton: .left),
            let mouseUp   = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                                    mouseCursorPosition: endPoint, mouseButton: .left)
        else {
            throw ExecutionError.executionFailed("Could not create drag CGEvents.")
        }

        mouseDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        mouseDrag.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        mouseUp.post(tap: .cghidEventTap)
    }

    // MARK: - Drag (element-based)

    /// Drags from the center of fromLabel to the center of toLabel within applicationName.
    func dragFromElement(applicationName: String, fromLabel: String, toLabel: String) throws {
        logger.info("Dragging from element '\(fromLabel)' to '\(toLabel)' in '\(applicationName)'")
        let startPoint = try elementCenter(applicationName: applicationName, label: fromLabel, role: nil)
        let endPoint   = try elementCenter(applicationName: applicationName, label: toLabel,   role: nil)
        try drag(from: startPoint, to: endPoint)
    }

    // MARK: - Private Helpers

    /// Finds the first running application whose localised name matches (case-insensitive).
    private func runningApplication(named name: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    /// Depth-first AX tree search for the first element matching label and optional role.
    private func findElement(in element: AXUIElement, label: String, role: String?) -> AXUIElement? {
        // Check this element.
        if elementMatches(element, label: label, role: role) {
            return element
        }

        // Recurse into children.
        var childrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement]
        else {
            return nil
        }

        for child in children {
            if let found = findElement(in: child, label: label, role: role) {
                return found
            }
        }

        return nil
    }

    /// Returns true if the element's title or description matches label (case-insensitive)
    /// and its role matches (if role is specified).
    private func elementMatches(_ element: AXUIElement, label: String, role: String?) -> Bool {
        // Check label against AXTitle and AXDescription.
        let labelMatches: Bool = {
            var titleRef: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef) == .success,
               let title = titleRef as? String,
               title.caseInsensitiveCompare(label) == .orderedSame {
                return true
            }
            var descRef: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descRef) == .success,
               let desc = descRef as? String,
               desc.caseInsensitiveCompare(label) == .orderedSame {
                return true
            }
            return false
        }()

        guard labelMatches else { return false }

        // If role filter is specified, also check AXRole.
        if let role = role {
            var roleRef: AnyObject?
            guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
                  let elementRole = roleRef as? String,
                  elementRole.caseInsensitiveCompare(role) == .orderedSame
            else {
                return false
            }
        }

        return true
    }

    /// Types text by posting CGEvent key presses for each character.
    /// Used as a fallback when AXValue cannot be set directly.
    private func typeViaKeyEvents(_ text: String) throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ExecutionError.executionFailed("Could not create CGEventSource.")
        }

        for scalar in text.unicodeScalars {
            guard scalar.value <= UInt16.max else { continue }
            let char = UniChar(scalar.value)

            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
               let up   = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                down.keyboardSetUnicodeString(stringLength: 1, unicodeString: [char])
                up.keyboardSetUnicodeString(stringLength: 1, unicodeString: [char])
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
        }
    }

    /// Returns the screen center point of the named AX element in the given application.
    private func elementCenter(applicationName: String, label: String, role: String?) throws -> CGPoint {
        guard let app = runningApplication(named: applicationName) else {
            throw ExecutionError.executionFailed("Application '\(applicationName)' is not running.")
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let element = findElement(in: axApp, label: label, role: role) else {
            throw ExecutionError.executionFailed("No element found matching label: \(label)")
        }
        return try centerPoint(of: element)
    }

    /// Returns the screen center of the front window of the given application.
    private func applicationWindowCenter(applicationName: String) throws -> CGPoint {
        guard let app = runningApplication(named: applicationName) else {
            throw ExecutionError.executionFailed("Application '\(applicationName)' is not running.")
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              let window = windows.first
        else {
            throw ExecutionError.executionFailed("Could not find a window for '\(applicationName)'.")
        }
        return try centerPoint(of: window)
    }

    /// Reads AXPosition/AXSize from an AX element and returns its center in screen coordinates.
    private func centerPoint(of element: AXUIElement) throws -> CGPoint {
        var posRef: AnyObject?
        var sizeRef: AnyObject?
        guard
            AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
            let posValue = posRef, let sizeValue = sizeRef
        else {
            throw ExecutionError.executionFailed("Could not read element position/size.")
        }
        // Verify both attributes are AXValue before unpacking.
        guard
            CFGetTypeID(posValue)  == AXValueGetTypeID(),
            CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else {
            throw ExecutionError.executionFailed("Element position/size attributes have unexpected types.")
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue  as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize,  &size)
        return CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
    }

    /// Posts a mouse event at the given screen point.
    private func postMouseEvent(
        type: CGEventType,
        button: CGMouseButton,
        at point: CGPoint,
        clickState: Int32 = 1
    ) throws {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: button)
        else {
            throw ExecutionError.executionFailed("Could not create mouse CGEvent.")
        }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        event.post(tap: .cghidEventTap)
    }

    /// Converts modifier name strings ("cmd", "shift", "opt", "ctrl") to CGEventFlags.
    private func modifierFlags(from modifiers: [String]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for mod in modifiers {
            switch mod.lowercased() {
            case "cmd", "command":  flags.insert(.maskCommand)
            case "shift":           flags.insert(.maskShift)
            case "opt", "option", "alt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default: break
            }
        }
        return flags
    }

    /// Maps a key name string to a CGKeyCode (ANSI US layout).
    // swiftlint:disable:next cyclomatic_complexity
    private func virtualKeyCode(for key: String) -> CGKeyCode? {
        let table: [String: CGKeyCode] = [
            // Letters
            "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03,
            "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
            "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
            "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
            "t": 0x11, "o": 0x1F, "u": 0x20, "i": 0x22,
            "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28,
            "n": 0x2D, "m": 0x2E,
            // Digits
            "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15,
            "6": 0x16, "5": 0x17, "9": 0x19, "7": 0x1A,
            "8": 0x1C, "0": 0x1D,
            // Special keys
            "return": 0x24, "enter": 0x24,
            "tab": 0x30,
            "space": 0x31,
            "delete": 0x33, "backspace": 0x33,
            "escape": 0x35, "esc": 0x35,
            "forwarddelete": 0x75,
            "home": 0x73,
            "end": 0x77,
            "pageup": 0x74,
            "pagedown": 0x79,
            // Arrow keys
            "left": 0x7B, "leftarrow": 0x7B,
            "right": 0x7C, "rightarrow": 0x7C,
            "down": 0x7D, "downarrow": 0x7D,
            "up": 0x7E, "uparrow": 0x7E,
            // Function keys
            "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76,
            "f5": 0x60, "f6": 0x61, "f7": 0x62, "f8": 0x64,
            "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
            // Punctuation / symbols
            "minus": 0x1B, "-": 0x1B,
            "equal": 0x18, "=": 0x18,
            "leftbracket": 0x21, "[": 0x21,
            "rightbracket": 0x1E, "]": 0x1E,
            "backslash": 0x2A, "\\": 0x2A,
            "semicolon": 0x29, ";": 0x29,
            "quote": 0x27, "'": 0x27,
            "comma": 0x2B, ",": 0x2B,
            "period": 0x2F, ".": 0x2F,
            "slash": 0x2C, "/": 0x2C,
            "grave": 0x32, "`": 0x32
        ]
        return table[key]
    }
}
