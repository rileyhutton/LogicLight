// LogicLight — menu-bar app that turns a Home Assistant light on while
// Logic Pro is recording, and off when it stops.
//
// Detection: reads the state of the Record button in Logic's control bar via
// the macOS Accessibility API (needs Accessibility permission).
// Light control: Home Assistant REST API with a long-lived access token.

import AppKit
import ApplicationServices
import ServiceManagement
import Security

// MARK: - Settings

enum Keys {
    static let url = "haURL"
    static let entity = "entityID"
    static let enabled = "enabled"
}

enum Keychain {
    static let service = "com.rileyhutton.logiclight"
    static let account = "ha-token"

    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func get() -> String? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String) {
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var q = base
        q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}

// MARK: - Home Assistant

enum HAError: LocalizedError {
    case notConfigured
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Home Assistant isn't configured"
        case .http(401): return "Home Assistant rejected the token (401)"
        case .http(let code): return "Home Assistant returned HTTP \(code)"
        }
    }
}

final class HomeAssistant {
    var baseURL: String {
        (UserDefaults.standard.string(forKey: Keys.url) ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ \n"))
    }
    var entity: String {
        (UserDefaults.standard.string(forKey: Keys.entity) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var isConfigured: Bool {
        !baseURL.isEmpty && !entity.isEmpty && !(Keychain.get() ?? "").isEmpty
    }

    func request(on: Bool) -> URLRequest? {
        guard let token = Keychain.get(), !token.isEmpty, !entity.isEmpty else { return nil }
        // light.* uses the light domain; anything else (switch.*, input_boolean.*) works via homeassistant.turn_on/off
        let domain = entity.hasPrefix("light.") ? "light" : "homeassistant"
        guard let url = URL(string: "\(baseURL)/api/services/\(domain)/turn_\(on ? "on" : "off")") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["entity_id": entity])
        return req
    }

    func set(on: Bool, completion: @escaping @MainActor (Error?) -> Void) {
        guard let req = request(on: on) else {
            DispatchQueue.main.async { completion(HAError.notConfigured) }
            return
        }
        URLSession.shared.dataTask(with: req) { _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                if let error { completion(error) }
                else if code == 200 { completion(nil) }
                else { completion(HAError.http(code)) }
            }
        }.resume()
    }

    /// Blocking variant, used only when quitting so the light isn't left on.
    func setSync(on: Bool, timeout: TimeInterval = 2) {
        guard let req = request(on: on) else { return }
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { _, _, _ in sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + timeout)
    }
}

// MARK: - Logic Pro record-state watcher

final class LogicRecordWatcher {
    enum State: Equatable {
        case noPermission, notRunning, buttonNotFound, idle, recording
    }

    static let bundleID = "com.apple.logic10"
    private static let skipRoles: Set<String> = ["AXScrollArea", "AXTable", "AXOutline", "AXList", "AXLayoutArea"]

    private var cachedButton: AXUIElement?
    private var cachedPID: pid_t = 0
    private var lastSearch = Date.distantPast

    func poll() -> State {
        guard AXIsProcessTrusted() else { return .noPermission }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else {
            cachedButton = nil
            return .notRunning
        }
        if app.processIdentifier != cachedPID {
            cachedButton = nil
            cachedPID = app.processIdentifier
        }

        if let button = cachedButton, let on = Self.boolValue(of: button) {
            return on ? .recording : .idle
        }
        cachedButton = nil

        // Searching Logic's UI tree is the expensive part — throttle it.
        guard Date().timeIntervalSince(lastSearch) > 2 else { return .buttonNotFound }
        lastSearch = Date()

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.5)
        cachedButton = findRecordButton(in: axApp)
        if let button = cachedButton, let on = Self.boolValue(of: button) {
            return on ? .recording : .idle
        }
        return .buttonNotFound
    }

    private func findRecordButton(in app: AXUIElement) -> AXUIElement? {
        var budget = 8000
        for window in Self.windows(of: app) {
            if let found = search(window, depth: 0, budget: &budget) { return found }
        }
        return nil
    }

    private func search(_ el: AXUIElement, depth: Int, budget: inout Int) -> AXUIElement? {
        budget -= 1
        guard budget > 0, depth <= 14 else { return nil }
        let role: String? = Self.attr(el, kAXRoleAttribute)
        if role == kAXCheckBoxRole || role == kAXButtonRole {
            let desc: String? = Self.attr(el, kAXDescriptionAttribute)
            let title: String? = Self.attr(el, kAXTitleAttribute)
            if (desc == "Record" || title == "Record"), Self.boolValue(of: el) != nil {
                return el
            }
        }
        if let role, Self.skipRoles.contains(role) { return nil }
        guard let children: [AXUIElement] = Self.attr(el, kAXChildrenAttribute) else { return nil }
        for child in children {
            if let found = search(child, depth: depth + 1, budget: &budget) { return found }
        }
        return nil
    }

    /// Lists every button/checkbox in Logic's windows — for troubleshooting.
    func diagnose() -> String {
        guard AXIsProcessTrusted() else { return "Accessibility permission not granted." }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else {
            return "Logic Pro isn't running."
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 1)
        var lines: [String] = []
        var budget = 15000
        func walk(_ el: AXUIElement, _ depth: Int) {
            budget -= 1
            guard budget > 0, depth <= 14 else { return }
            let role: String? = Self.attr(el, kAXRoleAttribute)
            if role == kAXCheckBoxRole || role == kAXButtonRole {
                let desc: String = Self.attr(el, kAXDescriptionAttribute) ?? ""
                let title: String = Self.attr(el, kAXTitleAttribute) ?? ""
                let value = Self.boolValue(of: el).map { $0 ? "1" : "0" } ?? "-"
                lines.append("\(role!)  desc=\"\(desc)\"  title=\"\(title)\"  value=\(value)  depth=\(depth)")
            }
            if let role, Self.skipRoles.contains(role) { return }
            for child in (Self.attr(el, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { walk(child, depth + 1) }
        }
        for window in Self.windows(of: axApp) {
            let title: String = Self.attr(window, kAXTitleAttribute) ?? "(untitled)"
            lines.append("== Window: \(title)")
            walk(window, 0)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: AX helpers

    private static func windows(of app: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        if let main: AXUIElement = attr(app, kAXMainWindowAttribute) { result.append(main) }
        if let all: [AXUIElement] = attr(app, kAXWindowsAttribute) {
            result += all.filter { w in !result.contains { CFEqual($0, w) } }
        }
        return result
    }

    private static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func boolValue(of el: AXUIElement) -> Bool? {
        guard let n: NSNumber = attr(el, kAXValueAttribute) else { return nil }
        return n.intValue != 0
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let watcher = LogicRecordWatcher()
    private let ha = HomeAssistant()

    private var timer: Timer?
    private var logicState: LogicRecordWatcher.State = .notRunning
    private var desired = false          // what we want the light to be
    private var confirmed: Bool?         // what HA last confirmed
    private var lastError: String?

    private let logicLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let lightLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")

    private var enabled: Bool { UserDefaults.standard.bool(forKey: Keys.enabled) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [Keys.enabled: true])
        buildMenu()

        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
        }
        if !ha.isConfigured { openSettings() }

        timer = Timer.scheduledTimer(timeInterval: 0.3, target: self, selector: #selector(tick),
                                     userInfo: nil, repeats: true)
        tick()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if confirmed == true || desired { ha.setSync(on: false) }
    }

    // MARK: Loop

    @objc private func tick() {
        let state = watcher.poll()
        if state != logicState {
            logicState = state
            refresh()
        }
        let want = enabled && state == .recording
        if want != desired {
            desired = want
            send(want)
        }
    }

    private func send(_ on: Bool) {
        ha.set(on: on) { [weak self] error in
            guard let self else { return }
            if let error {
                self.lastError = error.localizedDescription
                // Retry while it's still what we want.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if self.desired == on && self.confirmed != on { self.send(on) }
                }
            } else {
                self.confirmed = on
                self.lastError = nil
            }
            self.refresh()
        }
    }

    // MARK: Menu

    private func buildMenu() {
        let menu = NSMenu()
        logicLine.isEnabled = false
        lightLine.isEnabled = false
        menu.addItem(logicLine)
        menu.addItem(lightLine)
        menu.addItem(.separator())
        enabledItem.target = self
        menu.addItem(enabledItem)
        menu.addItem(withTitle: "Test Light On", action: #selector(testOn), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Test Light Off", action: #selector(testOff), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(withTitle: "Copy Logic Diagnostics", action: #selector(copyDiagnostics), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit LogicLight", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        refresh()
    }

    private func refresh() {
        let logicText: String
        switch logicState {
        case .noPermission:   logicText = "⚠︎ Needs Accessibility permission"
        case .notRunning:     logicText = "Logic Pro: not running"
        case .buttonNotFound: logicText = "Logic Pro: record button not found"
        case .idle:           logicText = "Logic Pro: not recording"
        case .recording:      logicText = "● Logic Pro: RECORDING"
        }
        logicLine.title = logicText

        if let lastError {
            lightLine.title = "⚠︎ \(lastError)"
        } else if !ha.isConfigured {
            lightLine.title = "Home Assistant not set up"
        } else {
            let lightState = confirmed.map { $0 ? "on" : "off" } ?? "untouched"
            lightLine.title = "\(ha.entity): \(lightState)"
        }

        enabledItem.state = enabled ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off

        guard let button = statusItem.button else { return }
        let symbol: String
        var tint: NSColor? = nil
        if logicState == .noPermission || lastError != nil || !ha.isConfigured {
            symbol = "exclamationmark.circle"
        } else if logicState == .recording && enabled {
            symbol = "record.circle.fill"
            tint = .systemRed
        } else {
            symbol = "record.circle"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "LogicLight")
        image?.isTemplate = (tint == nil)
        button.image = image
        button.contentTintColor = tint
        button.appearsDisabled = !enabled || logicState == .notRunning
    }

    // MARK: Actions

    @objc private func toggleEnabled() {
        UserDefaults.standard.set(!enabled, forKey: Keys.enabled)
        refresh()
        tick()
    }

    @objc private func testOn() { send(true) }
    @objc private func testOff() { send(false) }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showAlert("Couldn't change login item", error.localizedDescription)
        }
        refresh()
    }

    @objc private func copyDiagnostics() {
        let report = watcher.diagnose()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        showAlert("Diagnostics copied",
                  "A list of Logic's buttons and their states is on your clipboard.")
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)

        let urlField = NSTextField(string: UserDefaults.standard.string(forKey: Keys.url) ?? "")
        urlField.placeholderString = "http://homeassistant.local:8123"
        let tokenField = NSSecureTextField(string: Keychain.get() ?? "")
        tokenField.placeholderString = "Long-lived access token"
        let entityField = NSTextField(string: UserDefaults.standard.string(forKey: Keys.entity) ?? "")
        entityField.placeholderString = "light.studio_on_air"

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        for (label, field) in [("Home Assistant URL", urlField as NSTextField),
                               ("Access token", tokenField),
                               ("Entity ID", entityField)] {
            stack.addArrangedSubview(NSTextField(labelWithString: label))
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 320).isActive = true
            stack.addArrangedSubview(field)
        }
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 150)

        let alert = NSAlert()
        alert.messageText = "LogicLight Settings"
        alert.informativeText = "Create a token in Home Assistant under your profile → Security → Long-lived access tokens."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = urlField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        UserDefaults.standard.set(urlField.stringValue, forKey: Keys.url)
        UserDefaults.standard.set(entityField.stringValue, forKey: Keys.entity)
        Keychain.set(tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        lastError = nil
        confirmed = nil
        refresh()
    }

    private func showAlert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}

@main
enum LogicLightApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
