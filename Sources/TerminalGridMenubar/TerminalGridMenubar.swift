import AppKit
import Carbon
import Darwin
import Foundation
import ServiceManagement

@main
struct TerminalGridMenubar {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private struct FinishedJob {
        let tty: String
        let command: String
        let project: String
        let exitCode: Int
        let finishedAt: Date
    }

    private enum HotKeyID: UInt32 {
        case tile = 1
        case reviewNext = 2
    }

    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private var hotKeyInfoMenuItem: NSMenuItem?
    private var reviewHotKeyInfoMenuItem: NSMenuItem?
    private var restoreMenuItem: NSMenuItem?
    private var reviewNextMenuItem: NSMenuItem?
    private var launchAtLoginMenuItem: NSMenuItem?

    private var globalInteractionMonitor: Any?
    private var localInteractionMonitor: Any?

    private let hotKeyManager = GlobalHotKeyManager()
    private let terminalTiler = TerminalWindowTiler()
    private let launchAtLoginManager = LaunchAtLoginManager()
    private let completionEventServer = CompletionEventServer()

    private var currentHotKey: HotKey = HotKeyStore.load() ?? .defaultHotKey
    private let reviewHotKey: HotKey = .defaultReviewHotKey
    private var finishedJobsQueue: [FinishedJob] = []
    private let maxQueuedFinishedJobs = 100

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupHotKeyRegistration()
        setupCompletionEventListener()
        installInteractionMonitors()
        refreshHotKeyMenuLabel()
        refreshRestoreMenuState()
        refreshReviewQueueUI()
        refreshLaunchAtLoginMenuState()
        updateStatus("Ready")
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let globalInteractionMonitor {
            NSEvent.removeMonitor(globalInteractionMonitor)
            self.globalInteractionMonitor = nil
        }
        if let localInteractionMonitor {
            NSEvent.removeMonitor(localInteractionMonitor)
            self.localInteractionMonitor = nil
        }
        completionEventServer.stop()
    }

    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "square.grid.3x3", accessibilityDescription: "Tile Terminal Windows")
            button.imagePosition = .imageOnly
        }

        let menu = NSMenu()

        let tileItem = NSMenuItem(title: "Tile Terminal Windows", action: #selector(tileWindowsNow), keyEquivalent: "")
        tileItem.target = self
        menu.addItem(tileItem)

        let restoreItem = NSMenuItem(title: "Restore Previous Layout", action: #selector(restorePreviousLayout), keyEquivalent: "")
        restoreItem.target = self
        restoreItem.isEnabled = false
        menu.addItem(restoreItem)
        restoreMenuItem = restoreItem

        let reviewItem = NSMenuItem(title: "Review Next Finished Job (0)", action: #selector(reviewNextFinishedJob), keyEquivalent: "")
        reviewItem.target = self
        reviewItem.isEnabled = false
        menu.addItem(reviewItem)
        reviewNextMenuItem = reviewItem

        menu.addItem(.separator())

        let setHotKeyItem = NSMenuItem(title: "Set Hotkey...", action: #selector(setHotKeyFromMenu), keyEquivalent: "")
        setHotKeyItem.target = self
        menu.addItem(setHotKeyItem)

        let hotkeyInfo = NSMenuItem(title: "Hotkey: \(currentHotKey.displayString)", action: nil, keyEquivalent: "")
        hotkeyInfo.isEnabled = false
        menu.addItem(hotkeyInfo)
        hotKeyInfoMenuItem = hotkeyInfo

        let reviewHotkeyInfo = NSMenuItem(title: "Review Hotkey: \(reviewHotKey.displayString)", action: nil, keyEquivalent: "")
        reviewHotkeyInfo.isEnabled = false
        menu.addItem(reviewHotkeyInfo)
        reviewHotKeyInfoMenuItem = reviewHotkeyInfo

        menu.addItem(.separator())

        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        menu.addItem(launchItem)
        launchAtLoginMenuItem = launchItem

        menu.addItem(.separator())

        let status = NSMenuItem(title: "Status: Ready", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        statusMenuItem = status

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    private func setupHotKeyRegistration() {
        let tileRegistered = hotKeyManager.register(
            id: HotKeyID.tile.rawValue,
            keyCode: currentHotKey.keyCode,
            modifiers: currentHotKey.modifiers
        ) { [weak self] in
            Task { @MainActor in
                self?.tileWindowsNow()
            }
        }

        let reviewRegistered = hotKeyManager.register(
            id: HotKeyID.reviewNext.rawValue,
            keyCode: reviewHotKey.keyCode,
            modifiers: reviewHotKey.modifiers
        ) { [weak self] in
            Task { @MainActor in
                self?.reviewNextFinishedJob()
            }
        }

        if !tileRegistered || !reviewRegistered {
            updateStatus("Hotkey registration failed")
            NSSound.beep()
        }
    }

    private func setupCompletionEventListener() {
        completionEventServer.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handleShellEvent(event)
            }
        }

        completionEventServer.onError = { [weak self] message in
            Task { @MainActor in
                self?.updateStatus("Event error: \(message)")
            }
        }

        do {
            try completionEventServer.start()
        } catch {
            updateStatus("Listener failed: \(error.localizedDescription)")
            NSSound.beep()
        }
    }

    private func installInteractionMonitors() {
        globalInteractionMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] _ in
            Task { @MainActor in
                self?.handlePotentialTerminalInteraction()
            }
        }

        localInteractionMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            Task { @MainActor in
                self?.handlePotentialTerminalInteraction()
            }
            return event
        }
    }

    private func handleShellEvent(_ event: CompletionEvent) {
        guard event.command == "codex" || event.command == "claude" else { return }

        switch event.type {
        case "job_start":
            do {
                let updated = try terminalTiler.setCompactTitleForTTY(
                    event.tty,
                    projectName: event.project,
                    command: event.command
                )
                if updated {
                    updateStatus("Titel gezet: \(event.command) op \(event.tty)")
                } else {
                    updateStatus("Geen Terminal-tab voor \(event.tty)")
                }
            } catch {
                updateStatus("Title handling failed: \(error.localizedDescription)")
                NSSound.beep()
            }

        case "job_done":
            guard let exitCode = event.exitCode else { return }

            do {
                let marked = try terminalTiler.markCompletionForTTY(event.tty, exitCode: exitCode)
                if marked {
                    enqueueFinishedJob(
                        tty: event.tty,
                        command: event.command,
                        project: normalizedProject(event.project),
                        exitCode: exitCode
                    )
                    playCompletionSound(exitCode: exitCode)
                    refreshRestoreMenuState()
                    if exitCode == 0 {
                        updateStatus("\(event.command) klaar op \(event.tty) - groen")
                    } else {
                        updateStatus("\(event.command) faalde op \(event.tty) - rood")
                    }
                } else {
                    updateStatus("Geen Terminal-tab voor \(event.tty)")
                }
            } catch {
                updateStatus("Completion handling failed: \(error.localizedDescription)")
                NSSound.beep()
            }

        default:
            break
        }
    }

    private func enqueueFinishedJob(tty: String, command: String, project: String, exitCode: Int) {
        let normalizedTTY = tty.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTTY.isEmpty else { return }

        if let existingIndex = finishedJobsQueue.firstIndex(where: { $0.tty == normalizedTTY }) {
            finishedJobsQueue.remove(at: existingIndex)
        }

        let job = FinishedJob(
            tty: normalizedTTY,
            command: command,
            project: project,
            exitCode: exitCode,
            finishedAt: Date()
        )
        finishedJobsQueue.append(job)

        if finishedJobsQueue.count > maxQueuedFinishedJobs {
            finishedJobsQueue.removeFirst(finishedJobsQueue.count - maxQueuedFinishedJobs)
        }

        refreshReviewQueueUI()
    }

    private func normalizedProject(_ value: String?) -> String {
        guard let value else { return "project" }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "project" : trimmed
    }

    private func playCompletionSound(exitCode: Int) {
        let preferred = exitCode == 0 ? "Glass" : "Basso"
        if let sound = NSSound(named: NSSound.Name(preferred)) {
            sound.play()
        } else {
            NSSound.beep()
        }
    }

    private func handlePotentialTerminalInteraction() {
        guard terminalTiler.hasHighlightedTabs else { return }

        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard frontmostBundleID == "com.apple.Terminal" else { return }

        do {
            guard let tty = try terminalTiler.selectedTTYOfFrontWindow(), !tty.isEmpty else { return }
            let restored = try terminalTiler.restoreHighlightIfNeeded(forTTY: tty)
            if restored {
                refreshRestoreMenuState()
                updateStatus("Status gewist voor \(tty)")
            }
        } catch {
            updateStatus("Interaction handling failed: \(error.localizedDescription)")
        }
    }

    @objc private func tileWindowsNow() {
        do {
            let count = try terminalTiler.tileVisibleWindowsOnActiveScreen()
            refreshRestoreMenuState()
            updateStatus("Tiled \(count) window(s)")
        } catch {
            updateStatus("Error: \(error.localizedDescription)")
            NSSound.beep()
        }
    }

    @objc private func restorePreviousLayout() {
        do {
            let count = try terminalTiler.restorePreviousLayout()
            refreshRestoreMenuState()
            updateStatus("Restored \(count) window(s)")
        } catch {
            updateStatus("Restore failed: \(error.localizedDescription)")
            NSSound.beep()
        }
    }

    @objc private func reviewNextFinishedJob() {
        guard !finishedJobsQueue.isEmpty else {
            updateStatus("Geen afgeronde jobs in de wachtrij")
            refreshReviewQueueUI()
            return
        }

        let job = finishedJobsQueue.removeFirst()
        refreshReviewQueueUI()

        do {
            let focused = try terminalTiler.focusTabForTTY(job.tty)
            if !focused {
                updateStatus("Kon job-tab niet vinden voor \(job.tty)")
                return
            }

            _ = try terminalTiler.restoreHighlightIfNeeded(forTTY: job.tty)
            refreshRestoreMenuState()

            let tail = (try? terminalTiler.historyTailForTTY(job.tty, maxLines: 40)) ?? ""
            let statusLabel = job.exitCode == 0 ? "SUCCESS" : "FAILED(\(job.exitCode))"
            let timeText = ISO8601DateFormatter().string(from: job.finishedAt)
            let summary = """
            Project: \(job.project)
            Command: \(job.command)
            Status: \(statusLabel)
            TTY: \(job.tty)
            Finished: \(timeText)

            Last Output:
            \(tail.isEmpty ? "<geen output beschikbaar>" : tail)
            """
            copyToClipboard(summary)

            updateStatus("Review geopend voor \(job.project) • \(job.command) (summary gekopieerd)")
        } catch {
            updateStatus("Review mode failed: \(error.localizedDescription)")
            NSSound.beep()
        }
    }

    @objc private func setHotKeyFromMenu() {
        guard let newHotKey = captureHotKeyInteractively() else {
            updateStatus("Hotkey unchanged")
            return
        }

        let registered = hotKeyManager.register(
            id: HotKeyID.tile.rawValue,
            keyCode: newHotKey.keyCode,
            modifiers: newHotKey.modifiers
        ) { [weak self] in
            Task { @MainActor in
                self?.tileWindowsNow()
            }
        }
        guard registered else {
            updateStatus("Could not set hotkey")
            NSSound.beep()
            return
        }

        currentHotKey = newHotKey
        HotKeyStore.save(newHotKey)
        refreshHotKeyMenuLabel()
        updateStatus("Hotkey set: \(newHotKey.displayString)")
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            let isEnabled = launchAtLoginManager.status() == .enabled
            try launchAtLoginManager.setEnabled(!isEnabled)
            refreshLaunchAtLoginMenuState()

            switch launchAtLoginManager.status() {
            case .enabled:
                updateStatus("Launch at login enabled")
            case .requiresApproval:
                updateStatus("Approve login item in System Settings > Login Items")
            case .notRegistered:
                updateStatus("Launch at login disabled")
            case .notFound:
                updateStatus("Launch at login unavailable for this app location")
            @unknown default:
                updateStatus("Launch at login updated")
            }
        } catch {
            updateStatus("Launch-at-login failed: \(error.localizedDescription)")
            NSSound.beep()
        }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    private func captureHotKeyInteractively() -> HotKey? {
        NSApp.activate(ignoringOtherApps: true)

        var captured: HotKey?
        var monitor: Any?

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Press a new hotkey"
        alert.informativeText = "Use at least one modifier key (Command, Option, Control, Shift). Press Esc to cancel."
        alert.addButton(withTitle: "Cancel")

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                NSApp.abortModal()
                return nil
            }

            let keyCode = UInt32(event.keyCode)
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let modifiers = HotKey.carbonModifiers(from: flags)

            guard modifiers != 0 else {
                NSSound.beep()
                return nil
            }

            captured = HotKey(keyCode: keyCode, modifiers: modifiers)
            NSApp.abortModal()
            return nil
        }

        _ = alert.runModal()

        if let monitor {
            NSEvent.removeMonitor(monitor)
        }

        return captured
    }

    private func refreshHotKeyMenuLabel() {
        hotKeyInfoMenuItem?.title = "Hotkey: \(currentHotKey.displayString)"
        reviewHotKeyInfoMenuItem?.title = "Review Hotkey: \(reviewHotKey.displayString)"
    }

    private func refreshRestoreMenuState() {
        let enabled = terminalTiler.canRestorePreviousLayout || terminalTiler.hasHighlightedTabs
        restoreMenuItem?.isEnabled = enabled
    }

    private func refreshReviewQueueUI() {
        let count = finishedJobsQueue.count
        reviewNextMenuItem?.title = "Review Next Finished Job (\(count))"
        reviewNextMenuItem?.isEnabled = count > 0
    }

    private func refreshLaunchAtLoginMenuState() {
        guard let item = launchAtLoginMenuItem else { return }
        item.title = "Launch at Login"

        switch launchAtLoginManager.status() {
        case .enabled:
            item.state = .on
            item.toolTip = "App starts automatically when you log in."
        case .notRegistered:
            item.state = .off
            item.toolTip = "App does not start automatically."
        case .requiresApproval:
            item.state = .mixed
            item.toolTip = "Requires approval in System Settings > Login Items."
        case .notFound:
            item.state = .off
            item.toolTip = "Move the app to /Applications for launch-at-login support."
        @unknown default:
            item.state = .off
            item.toolTip = nil
        }
    }

    private func updateStatus(_ text: String) {
        statusMenuItem?.title = "Status: \(text)"
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

final class GlobalHotKeyManager {
    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private let signature = OSType(0x54475244)

    init() {
        installEventHandler()
    }

    deinit {
        for (_, hotKeyRef) in hotKeyRefs {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRefs.removeAll()
        handlers.removeAll()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    @discardableResult
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> Bool {
        if let existingRef = hotKeyRefs[id] {
            UnregisterEventHotKey(existingRef)
            hotKeyRefs.removeValue(forKey: id)
        }

        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )

        if status != noErr {
            NSLog("Failed to register hotkey: \(status)")
            return false
        }

        if let hotKeyRef {
            hotKeyRefs[id] = hotKeyRef
            handlers[id] = handler
        }

        return true
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let callback: EventHandlerUPP = { _, eventRef, userData in
            guard let userData, let eventRef else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            manager.handleHotKey(eventRef)
            return noErr
        }

        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            callback,
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &eventHandlerRef
        )

        if status != noErr {
            NSLog("Failed to install hotkey event handler: \(status)")
        }
    }

    private func handleHotKey(_ eventRef: EventRef) {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            eventRef,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        if status == noErr, hotKeyID.signature == signature {
            handlers[hotKeyID.id]?()
        }
    }
}

struct HotKey {
    let keyCode: UInt32
    let modifiers: UInt32

    static let defaultHotKey = HotKey(
        keyCode: UInt32(kVK_ANSI_G),
        modifiers: UInt32(controlKey | optionKey | cmdKey)
    )

    static let defaultReviewHotKey = HotKey(
        keyCode: UInt32(kVK_ANSI_R),
        modifiers: UInt32(controlKey | optionKey | cmdKey)
    )

    var displayString: String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("Ctrl") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("Option") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("Shift") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("Command") }
        parts.append(Self.keyName(for: keyCode))
        return parts.joined(separator: " + ")
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var value: UInt32 = 0
        if flags.contains(.control) { value |= UInt32(controlKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }
        if flags.contains(.shift) { value |= UInt32(shiftKey) }
        if flags.contains(.command) { value |= UInt32(cmdKey) }
        return value
    }

    private static func keyName(for keyCode: UInt32) -> String {
        if let mapped = keyMap[keyCode] {
            return mapped
        }
        return "Key \(keyCode)"
    }

    private static let keyMap: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A",
        UInt32(kVK_ANSI_B): "B",
        UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_D): "D",
        UInt32(kVK_ANSI_E): "E",
        UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G",
        UInt32(kVK_ANSI_H): "H",
        UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_J): "J",
        UInt32(kVK_ANSI_K): "K",
        UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M",
        UInt32(kVK_ANSI_N): "N",
        UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_P): "P",
        UInt32(kVK_ANSI_Q): "Q",
        UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S",
        UInt32(kVK_ANSI_T): "T",
        UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_V): "V",
        UInt32(kVK_ANSI_W): "W",
        UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y",
        UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_0): "0",
        UInt32(kVK_ANSI_1): "1",
        UInt32(kVK_ANSI_2): "2",
        UInt32(kVK_ANSI_3): "3",
        UInt32(kVK_ANSI_4): "4",
        UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6",
        UInt32(kVK_ANSI_7): "7",
        UInt32(kVK_ANSI_8): "8",
        UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_Space): "Space",
        UInt32(kVK_Return): "Return",
        UInt32(kVK_Tab): "Tab",
        UInt32(kVK_Delete): "Delete",
        UInt32(kVK_Escape): "Escape",
        UInt32(kVK_LeftArrow): "Left",
        UInt32(kVK_RightArrow): "Right",
        UInt32(kVK_UpArrow): "Up",
        UInt32(kVK_DownArrow): "Down",
        UInt32(kVK_F1): "F1",
        UInt32(kVK_F2): "F2",
        UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5",
        UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7",
        UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10",
        UInt32(kVK_F11): "F11",
        UInt32(kVK_F12): "F12"
    ]
}

enum HotKeyStore {
    private static let keyCodeKey = "hotkey.keyCode"
    private static let modifiersKey = "hotkey.modifiers"

    static func load() -> HotKey? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: keyCodeKey) != nil,
              defaults.object(forKey: modifiersKey) != nil else {
            return nil
        }

        return HotKey(
            keyCode: UInt32(defaults.integer(forKey: keyCodeKey)),
            modifiers: UInt32(defaults.integer(forKey: modifiersKey))
        )
    }

    static func save(_ hotKey: HotKey) {
        let defaults = UserDefaults.standard
        defaults.set(Int(hotKey.keyCode), forKey: keyCodeKey)
        defaults.set(Int(hotKey.modifiers), forKey: modifiersKey)
    }
}

final class LaunchAtLoginManager {
    private let service = SMAppService.mainApp

    func status() -> SMAppService.Status {
        service.status
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try service.register()
        } else {
            try service.unregister()
        }
    }
}

struct CompletionEvent: Decodable {
    let type: String
    let tty: String
    let command: String
    let exitCode: Int?
    let project: String?
}

final class CompletionEventServer {
    static let defaultSocketPath = NSHomeDirectory() + "/.terminal-grid-menubar/events.sock"

    var onEvent: ((CompletionEvent) -> Void)?
    var onError: ((String) -> Void)?

    private let socketPath: String
    private let queue = DispatchQueue(label: "io.terminalgrid.menubar.event-server")
    private let decoder = JSONDecoder()

    private var listenFD: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var clientSources: [Int32: DispatchSourceRead] = [:]
    private var clientBuffers: [Int32: Data] = [:]

    init(socketPath: String = CompletionEventServer.defaultSocketPath) {
        self.socketPath = socketPath
    }

    deinit {
        stop()
    }

    func start() throws {
        if listenFD != -1 { return }

        let directory = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: socketPath) {
            unlink(socketPath)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw EventServerError.socketCreateFailed(errno: errno)
        }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)

        let pathCString = socketPath.utf8CString
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard pathCString.count <= maxPathLength else {
            close(fd)
            throw EventServerError.socketPathTooLong
        }

        pathCString.withUnsafeBufferPointer { buffer in
            withUnsafeMutablePointer(to: &address.sun_path) { pathPtr in
                pathPtr.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { rebound in
                    _ = strncpy(rebound, buffer.baseAddress, maxPathLength - 1)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &address) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                bind(fd, rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            let err = errno
            close(fd)
            throw EventServerError.bindFailed(errno: err)
        }

        guard listen(fd, 16) == 0 else {
            let err = errno
            close(fd)
            throw EventServerError.listenFailed(errno: err)
        }

        chmod(socketPath, 0o600)

        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptPendingClients()
        }
        source.resume()
        listenSource = source
    }

    func stop() {
        queue.sync {
            for (fd, source) in clientSources {
                source.cancel()
                close(fd)
            }
            clientSources.removeAll()
            clientBuffers.removeAll()

            if let listenSource {
                listenSource.cancel()
                self.listenSource = nil
            }

            if listenFD != -1 {
                close(listenFD)
                listenFD = -1
            }

            if FileManager.default.fileExists(atPath: socketPath) {
                unlink(socketPath)
            }
        }
    }

    private func acceptPendingClients() {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                let err = errno
                if err == EWOULDBLOCK || err == EAGAIN {
                    break
                }
                emitError("accept failed: errno \(err)")
                break
            }

            let flags = fcntl(clientFD, F_GETFL, 0)
            _ = fcntl(clientFD, F_SETFL, flags | O_NONBLOCK)

            let source = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: queue)
            source.setEventHandler { [weak self] in
                self?.readFromClient(clientFD)
            }
            source.resume()

            clientSources[clientFD] = source
            clientBuffers[clientFD] = Data()
        }
    }

    private func readFromClient(_ clientFD: Int32) {
        var temp = [UInt8](repeating: 0, count: 4096)

        while true {
            let count = read(clientFD, &temp, temp.count)
            if count > 0 {
                clientBuffers[clientFD, default: Data()].append(temp, count: count)
                processBuffer(for: clientFD)
            } else if count == 0 {
                closeClient(clientFD)
                break
            } else {
                let err = errno
                if err == EWOULDBLOCK || err == EAGAIN {
                    break
                }
                emitError("read failed: errno \(err)")
                closeClient(clientFD)
                break
            }
        }
    }

    private func processBuffer(for clientFD: Int32) {
        guard var buffer = clientBuffers[clientFD] else { return }

        while let newlineRange = buffer.firstRange(of: Data([0x0A])) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newlineRange.lowerBound)
            buffer.removeSubrange(buffer.startIndex...newlineRange.lowerBound)

            if lineData.isEmpty {
                continue
            }

            do {
                let event = try decoder.decode(CompletionEvent.self, from: lineData)
                emitEvent(event)
            } catch {
                let raw = String(data: lineData, encoding: .utf8) ?? "<non-utf8>"
                emitError("invalid event JSON: \(raw)")
            }
        }

        clientBuffers[clientFD] = buffer
    }

    private func closeClient(_ clientFD: Int32) {
        if let source = clientSources.removeValue(forKey: clientFD) {
            source.cancel()
        }
        clientBuffers.removeValue(forKey: clientFD)
        close(clientFD)
    }

    private func emitEvent(_ event: CompletionEvent) {
        onEvent?(event)
    }

    private func emitError(_ message: String) {
        onError?(message)
    }
}

enum EventServerError: LocalizedError {
    case socketCreateFailed(errno: Int32)
    case socketPathTooLong
    case bindFailed(errno: Int32)
    case listenFailed(errno: Int32)

    var errorDescription: String? {
        switch self {
        case let .socketCreateFailed(errno):
            return "Could not create socket (errno \(errno))"
        case .socketPathTooLong:
            return "Socket path too long"
        case let .bindFailed(errno):
            return "Could not bind socket (errno \(errno))"
        case let .listenFailed(errno):
            return "Could not listen on socket (errno \(errno))"
        }
    }
}

final class TerminalWindowTiler {
    private struct GridPlan {
        let rects: [CGRect]
        let columns: Int
        let rows: Int
    }

    private struct TabSizeMetrics {
        let minColumns: Int
        let minRows: Int
        let maxColumns: Int
        let maxRows: Int
    }

    private struct ReadabilityTargets {
        let minColumns: Int
        let maxColumns: Int
        let minRows: Int
        let maxRows: Int
    }

    private struct WindowSnapshot {
        let id: Int
        let bounds: TerminalBounds
        let fontSize: Int?
    }

    private struct TerminalBounds {
        let left: Int
        let top: Int
        let right: Int
        let bottom: Int
    }

    private struct RGBColor {
        let r: Int
        let g: Int
        let b: Int

        var listLiteral: String {
            "{\(r), \(g), \(b)}"
        }

        static func parse(_ text: String) -> RGBColor? {
            let parts = text.split(separator: ",")
            guard parts.count == 3,
                  let r = Int(parts[0]),
                  let g = Int(parts[1]),
                  let b = Int(parts[2]) else {
                return nil
            }
            return RGBColor(r: r, g: g, b: b)
        }
    }

    private struct HighlightSnapshot {
        let originalBackground: RGBColor
        let originalText: RGBColor
    }

    private let defaultOuterPadding: CGFloat = 10
    private let defaultGap: CGFloat = 8

    private var previousLayout: [WindowSnapshot] = []
    private var highlightedTabs: [String: HighlightSnapshot] = [:]

    var canRestorePreviousLayout: Bool {
        !previousLayout.isEmpty
    }

    var hasHighlightedTabs: Bool {
        !highlightedTabs.isEmpty
    }

    func tileVisibleWindowsOnActiveScreen() throws -> Int {
        let snapshots = try getOpenWindowSnapshots()
        guard !snapshots.isEmpty else { return 0 }

        previousLayout = snapshots

        guard let activeScreen = activeScreen() else {
            throw TilerError.activeScreenNotFound
        }

        let visible = activeScreen.visibleFrame
        let windowIDs = snapshots.map(\.id)
        let layout = computeGridLayout(count: snapshots.count, in: visible)
        var fontSize = fontSizeForWindowCount(snapshots.count)
        let mainHeight = mainScreenHeight()

        var commands: [String] = []
        for (index, snapshot) in snapshots.enumerated() {
            guard index < layout.rects.count else { break }
            let rect = layout.rects[index]
            let bounds = toTerminalBounds(rect: rect, mainScreenHeight: mainHeight)

            commands.append("if exists window id \(snapshot.id) then")
            commands.append("try")
            commands.append("set zoomed of window id \(snapshot.id) to false")
            commands.append("end try")
            commands.append("try")
            commands.append("set miniaturized of window id \(snapshot.id) to false")
            commands.append("end try")
            commands.append("try")
            commands.append("set font size of selected tab of window id \(snapshot.id) to \(fontSize)")
            commands.append("end try")
            commands.append("try")
            commands.append("set bounds of window id \(snapshot.id) to {\(bounds.left), \(bounds.top), \(bounds.right), \(bounds.bottom)}")
            commands.append("end try")
            commands.append("try")
            commands.append("set bounds of window id \(snapshot.id) to {\(bounds.left), \(bounds.top), \(bounds.right), \(bounds.bottom)}")
            commands.append("end try")
            commands.append("end if")
        }

        let script = """
        tell application "Terminal"
            \(commands.joined(separator: "\n            "))
            activate
        end tell
        """

        _ = try runAppleScript(script)

        let targets = readabilityTargets(for: layout)
        fontSize = try tuneFontSizeForReadability(
            windowIDs: windowIDs,
            startingFontSize: fontSize,
            targets: targets
        )

        try applyFontSizeWithVerification(windowIDs: windowIDs, fontSize: fontSize)
        try applyBoundsWithVerification(windowIDs: windowIDs, rects: layout.rects, mainScreenHeight: mainHeight)
        return snapshots.count
    }

    func restorePreviousLayout() throws -> Int {
        guard !previousLayout.isEmpty else { return 0 }

        let liveWindowIDs = Set(try getOpenWindowSnapshots().map(\.id))
        let windowsToRestore = previousLayout.filter { liveWindowIDs.contains($0.id) }
        guard !windowsToRestore.isEmpty else { return 0 }

        var commands: [String] = []
        for snapshot in windowsToRestore {
            commands.append("if exists window id \(snapshot.id) then")
            commands.append("try")
            commands.append("set zoomed of window id \(snapshot.id) to false")
            commands.append("end try")
            commands.append("try")
            commands.append("set miniaturized of window id \(snapshot.id) to false")
            commands.append("end try")
            commands.append("try")
            commands.append("set bounds of window id \(snapshot.id) to {\(snapshot.bounds.left), \(snapshot.bounds.top), \(snapshot.bounds.right), \(snapshot.bounds.bottom)}")
            commands.append("end try")
            if let fontSize = snapshot.fontSize {
                commands.append("try")
                commands.append("set font size of selected tab of window id \(snapshot.id) to \(fontSize)")
                commands.append("end try")
            }
            commands.append("end if")
        }

        let script = """
        tell application "Terminal"
            \(commands.joined(separator: "\n            "))
            activate
        end tell
        """

        _ = try runAppleScript(script)
        return windowsToRestore.count
    }

    func setCompactTitleForTTY(_ tty: String, projectName: String?, command: String) throws -> Bool {
        let normalizedTTY = tty.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTTY.isEmpty else { return false }

        let cleanProject = normalizedProjectName(projectName)
        let commandLabel = command.lowercased() == "claude" ? "Claude" : "Codex"
        let compactTitle = "\(cleanProject) • \(commandLabel)"

        let escapedTTY = escapeAppleScriptString(normalizedTTY)
        let escapedTitle = escapeAppleScriptString(compactTitle)

        let script = """
        set targetTTY to "\(escapedTTY)"
        set targetTitle to "\(escapedTitle)"

        tell application "Terminal"
            if not running then
                return 0
            end if

            repeat with w in windows
                try
                    set tabList to tabs of w
                    repeat with t in tabList
                        try
                            if (tty of t as text) is targetTTY then
                                try
                                    set title displays device name of t to false
                                end try
                                try
                                    set title displays shell path of t to false
                                end try
                                try
                                    set title displays window size of t to false
                                end try
                                try
                                    set title displays file name of t to false
                                end try
                                try
                                    set title displays custom title of t to true
                                end try

                                set custom title of t to targetTitle
                                return 1
                            end if
                        end try
                    end repeat
                end try
            end repeat

            return 0
        end tell
        """

        let descriptor = try runAppleScript(script)
        return descriptor.int32Value == 1
    }

    func focusTabForTTY(_ tty: String) throws -> Bool {
        let normalizedTTY = tty.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTTY.isEmpty else { return false }

        let escapedTTY = escapeAppleScriptString(normalizedTTY)
        let script = """
        set targetTTY to "\(escapedTTY)"

        tell application "Terminal"
            if not running then
                return 0
            end if

            repeat with w in windows
                try
                    set tabList to tabs of w
                    repeat with t in tabList
                        try
                            if (tty of t as text) is targetTTY then
                                set selected tab of w to t
                                set index of w to 1
                                activate
                                return 1
                            end if
                        end try
                    end repeat
                end try
            end repeat

            return 0
        end tell
        """

        let descriptor = try runAppleScript(script)
        return descriptor.int32Value == 1
    }

    func historyTailForTTY(_ tty: String, maxLines: Int) throws -> String {
        let normalizedTTY = tty.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTTY.isEmpty else { return "" }

        let escapedTTY = escapeAppleScriptString(normalizedTTY)
        let script = """
        set targetTTY to "\(escapedTTY)"

        tell application "Terminal"
            if not running then
                return ""
            end if

            repeat with w in windows
                try
                    set tabList to tabs of w
                    repeat with t in tabList
                        try
                            if (tty of t as text) is targetTTY then
                                return history of t
                            end if
                        end try
                    end repeat
                end try
            end repeat

            return ""
        end tell
        """

        let descriptor = try runAppleScript(script)
        let history = descriptor.stringValue ?? ""
        if history.isEmpty {
            return ""
        }

        let lines = history.components(separatedBy: .newlines)
        let tailLines = lines.suffix(max(1, maxLines))
        return tailLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func markCompletionForTTY(_ tty: String, exitCode: Int) throws -> Bool {
        guard !tty.isEmpty else { return false }

        let normalizedTTY = tty.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTTY.isEmpty else { return false }

        let alreadyTracked = highlightedTabs[normalizedTTY] != nil

        if !alreadyTracked {
            guard let snapshot = try fetchCurrentColors(forTTY: normalizedTTY) else {
                return false
            }
            highlightedTabs[normalizedTTY] = snapshot
        }

        let statusBackground: RGBColor
        let statusText: RGBColor

        if exitCode == 0 {
            statusBackground = RGBColor(r: 6000, g: 33000, b: 6000)
            statusText = RGBColor(r: 65535, g: 65535, b: 65535)
        } else {
            statusBackground = RGBColor(r: 46000, g: 12000, b: 2000)
            statusText = RGBColor(r: 65535, g: 65535, b: 65535)
        }

        let applied = try applyColors(forTTY: normalizedTTY, background: statusBackground, text: statusText)

        if !applied, !alreadyTracked {
            highlightedTabs.removeValue(forKey: normalizedTTY)
        }

        return applied
    }

    func restoreHighlightIfNeeded(forTTY tty: String) throws -> Bool {
        let normalizedTTY = tty.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let snapshot = highlightedTabs[normalizedTTY] else {
            return false
        }

        let restored = try applyColors(forTTY: normalizedTTY, background: snapshot.originalBackground, text: snapshot.originalText)
        highlightedTabs.removeValue(forKey: normalizedTTY)
        return restored
    }

    func selectedTTYOfFrontWindow() throws -> String? {
        let script = """
        tell application "Terminal"
            if not running then
                return ""
            end if
            try
                return tty of selected tab of front window
            on error
                return ""
            end try
        end tell
        """

        let descriptor = try runAppleScript(script)
        let value = descriptor.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value, !value.isEmpty {
            return value
        }
        return nil
    }

    private func fetchCurrentColors(forTTY tty: String) throws -> HighlightSnapshot? {
        let escapedTTY = escapeAppleScriptString(tty)
        let script = """
        set targetTTY to "\(escapedTTY)"
        tell application "Terminal"
            if not running then
                return ""
            end if

            repeat with w in windows
                try
                    set tabList to tabs of w
                    repeat with t in tabList
                        try
                            if (tty of t as text) is targetTTY then
                                set bg to background color of t
                                set fg to normal text color of t
                                return ((item 1 of bg as text) & "," & (item 2 of bg as text) & "," & (item 3 of bg as text) & "|" & (item 1 of fg as text) & "," & (item 2 of fg as text) & "," & (item 3 of fg as text))
                            end if
                        end try
                    end repeat
                end try
            end repeat

            return ""
        end tell
        """

        let descriptor = try runAppleScript(script)
        guard let value = descriptor.stringValue, !value.isEmpty else {
            return nil
        }

        let parts = value.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let background = RGBColor.parse(String(parts[0])),
              let text = RGBColor.parse(String(parts[1])) else {
            return nil
        }

        return HighlightSnapshot(originalBackground: background, originalText: text)
    }

    private func applyColors(forTTY tty: String, background: RGBColor, text: RGBColor) throws -> Bool {
        let escapedTTY = escapeAppleScriptString(tty)
        let script = """
        set targetTTY to "\(escapedTTY)"
        set targetBackground to \(background.listLiteral)
        set targetText to \(text.listLiteral)

        tell application "Terminal"
            if not running then
                return 0
            end if

            repeat with w in windows
                try
                    set tabList to tabs of w
                    repeat with t in tabList
                        try
                            if (tty of t as text) is targetTTY then
                                set background color of t to targetBackground
                                set normal text color of t to targetText
                                return 1
                            end if
                        end try
                    end repeat
                end try
            end repeat

            return 0
        end tell
        """

        let descriptor = try runAppleScript(script)
        return descriptor.int32Value == 1
    }

    private func getOpenWindowSnapshots() throws -> [WindowSnapshot] {
        let script = """
        tell application "Terminal"
            if not running then
                return ""
            end if

            set outLines to {}
            set targetWindows to every window

            repeat with w in targetWindows
                try
                    try
                        if miniaturized of w is true then
                            set miniaturized of w to false
                        end if
                    end try

                    set wid to id of w
                    set b to bounds of w

                    set fs to 0
                    try
                        set fs to font size of selected tab of w
                    end try

                    set end of outLines to ((wid as text) & "|" & (item 1 of b as text) & "|" & (item 2 of b as text) & "|" & (item 3 of b as text) & "|" & (item 4 of b as text) & "|" & (fs as text))
                on error
                    -- Skip invalid window references that sometimes appear in Terminal's scripting bridge.
                end try
            end repeat

            set oldDelims to AppleScript's text item delimiters
            set AppleScript's text item delimiters to linefeed
            set outputText to outLines as text
            set AppleScript's text item delimiters to oldDelims
            return outputText
        end tell
        """

        let descriptor = try runAppleScript(script)
        let output = descriptor.stringValue ?? ""
        return parseWindowSnapshots(from: output)
    }

    private func parseWindowSnapshots(from output: String) -> [WindowSnapshot] {
        let lines = output.split(separator: "\n")
        guard !lines.isEmpty else { return [] }

        var snapshots: [WindowSnapshot] = []
        snapshots.reserveCapacity(lines.count)

        for line in lines {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count >= 6,
                  let id = Int(parts[0]),
                  let left = Int(parts[1]),
                  let top = Int(parts[2]),
                  let right = Int(parts[3]),
                  let bottom = Int(parts[4]) else {
                continue
            }

            let rawFontSize = Int(parts[5]) ?? 0
            let fontSize = rawFontSize > 0 ? rawFontSize : nil

            snapshots.append(
                WindowSnapshot(
                    id: id,
                    bounds: TerminalBounds(left: left, top: top, right: right, bottom: bottom),
                    fontSize: fontSize
                )
            )
        }

        return snapshots
    }

    private func activeScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        if let byMouse = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) {
            return byMouse
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func mainScreenHeight() -> CGFloat {
        if let mainAtOrigin = NSScreen.screens.first(where: { $0.frame.origin.equalTo(.zero) }) {
            return mainAtOrigin.frame.height
        }
        return NSScreen.main?.frame.height ?? (NSScreen.screens.first?.frame.height ?? 1200)
    }

    private func computeGridLayout(count: Int, in frame: CGRect) -> GridPlan {
        struct Candidate {
            let columns: Int
            let rows: Int
            let cellWidth: CGFloat
            let cellHeight: CGFloat
            let score: Double
        }

        var best: Candidate?
        let outerPadding = layoutOuterPadding(for: count)
        let gap = layoutGap(for: count)

        for columns in 1...count {
            let rows = max(1, Int(ceil(Double(count) / Double(columns))))
            let usableWidth = frame.width - (outerPadding * 2) - (gap * CGFloat(columns - 1))
            let usableHeight = frame.height - (outerPadding * 2) - (gap * CGFloat(rows - 1))

            guard usableWidth > 0, usableHeight > 0 else { continue }

            let cellWidth = floor(usableWidth / CGFloat(columns))
            let cellHeight = floor(usableHeight / CGFloat(rows))
            guard cellWidth >= 200, cellHeight >= 130 else { continue }

            let emptySlots = (rows * columns) - count
            let minDimension = min(cellWidth, cellHeight)
            let aspect = cellWidth / max(1, cellHeight)
            let aspectPenalty = abs(aspect - 1.35) * 60
            let emptyPenalty = Double(emptySlots) * 220
            let score = Double(minDimension) * 1000 + Double(cellWidth * cellHeight) / 80 - aspectPenalty - emptyPenalty

            let candidate = Candidate(
                columns: columns,
                rows: rows,
                cellWidth: cellWidth,
                cellHeight: cellHeight,
                score: score
            )

            if let currentBest = best {
                if candidate.score > currentBest.score {
                    best = candidate
                }
            } else {
                best = candidate
            }
        }

        if best == nil {
            let columns = max(1, Int(ceil(sqrt(Double(count)))))
            let rows = max(1, Int(ceil(Double(count) / Double(columns))))
            let usableWidth = frame.width - (outerPadding * 2) - (gap * CGFloat(columns - 1))
            let usableHeight = frame.height - (outerPadding * 2) - (gap * CGFloat(rows - 1))
            let cellWidth = floor(max(50, usableWidth / CGFloat(columns)))
            let cellHeight = floor(max(50, usableHeight / CGFloat(rows)))
            best = Candidate(columns: columns, rows: rows, cellWidth: cellWidth, cellHeight: cellHeight, score: 0)
        }

        guard let best else {
            return GridPlan(rects: [], columns: 1, rows: 1)
        }

        var rects: [CGRect] = []
        rects.reserveCapacity(count)

        for index in 0..<count {
            let row = index / best.columns
            let startIndexOfRow = row * best.columns
            let remaining = count - startIndexOfRow
            let columnsInThisRow = min(best.columns, remaining)
            let colInRow = index - startIndexOfRow

            let centeredOffset = CGFloat(best.columns - columnsInThisRow) * (best.cellWidth + gap) / 2
            let x = frame.minX + outerPadding + centeredOffset + CGFloat(colInRow) * (best.cellWidth + gap)
            let y = frame.maxY - outerPadding - CGFloat(row + 1) * best.cellHeight - CGFloat(row) * gap

            rects.append(CGRect(x: x, y: y, width: best.cellWidth, height: best.cellHeight))
        }

        return GridPlan(rects: rects, columns: best.columns, rows: best.rows)
    }

    private func fontSizeForWindowCount(_ count: Int) -> Int {
        switch count {
        case 0...2:
            return 14
        case 3...4:
            return 13
        case 5...6:
            return 12
        case 7...8:
            return 11
        case 9...10:
            return 10
        case 11...12:
            return 9
        case 13...16:
            return 8
        default:
            return 7
        }
    }

    private func layoutOuterPadding(for count: Int) -> CGFloat {
        if count >= 13 { return 2 }
        if count >= 10 { return 4 }
        return defaultOuterPadding
    }

    private func layoutGap(for count: Int) -> CGFloat {
        if count >= 13 { return 2 }
        if count >= 10 { return 4 }
        return defaultGap
    }

    private func readabilityTargets(for plan: GridPlan) -> ReadabilityTargets {
        let minColumns = max(34, 84 - ((plan.columns - 1) * 14))
        let maxColumns = minColumns + 34
        let minRows = max(10, 22 - ((plan.rows - 1) * 4))
        let maxRows = minRows + 10
        return ReadabilityTargets(minColumns: minColumns, maxColumns: maxColumns, minRows: minRows, maxRows: maxRows)
    }

    private func minimumFontSize(for windowCount: Int) -> Int {
        switch windowCount {
        case 0...8:
            return 10
        case 9...12:
            return 9
        case 13...16:
            return 8
        default:
            return 7
        }
    }

    private func tuneFontSizeForReadability(
        windowIDs: [Int],
        startingFontSize: Int,
        targets: ReadabilityTargets
    ) throws -> Int {
        guard !windowIDs.isEmpty else { return startingFontSize }

        var fontSize = startingFontSize
        let minimumFontSize = minimumFontSize(for: windowIDs.count)
        let maximumFontSize = 15

        for _ in 0..<5 {
            guard let metrics = try fetchTabSizeMetrics(windowIDs: windowIDs) else { break }

            let rowDeficit = targets.minRows - metrics.minRows
            let columnDeficit = targets.minColumns - metrics.minColumns
            let rowSurplus = metrics.minRows - targets.maxRows
            let columnSurplus = metrics.minColumns - targets.maxColumns

            let tooDense = rowDeficit >= 3 || columnDeficit >= 6
            let tooSparse = rowSurplus >= 4 && columnSurplus >= 10

            if tooDense, fontSize > minimumFontSize {
                fontSize -= 1
                try applyFontSize(windowIDs: windowIDs, fontSize: fontSize)
                continue
            }

            if tooSparse, fontSize < maximumFontSize {
                fontSize += 1
                try applyFontSize(windowIDs: windowIDs, fontSize: fontSize)
                continue
            }

            break
        }

        return fontSize
    }

    private func fetchTabSizeMetrics(windowIDs: [Int]) throws -> TabSizeMetrics? {
        guard !windowIDs.isEmpty else { return nil }

        let ids = appleScriptIntegerList(windowIDs)
        let script = """
        set targetIDs to \(ids)
        tell application "Terminal"
            if not running then
                return ""
            end if

            set outLines to {}
            repeat with wid in targetIDs
                try
                    if exists window id wid then
                        set c to number of columns of selected tab of window id wid
                        set r to number of rows of selected tab of window id wid
                        set end of outLines to ((wid as text) & "|" & (c as text) & "|" & (r as text))
                    end if
                end try
            end repeat

            set oldDelims to AppleScript's text item delimiters
            set AppleScript's text item delimiters to linefeed
            set outputText to outLines as text
            set AppleScript's text item delimiters to oldDelims
            return outputText
        end tell
        """

        let descriptor = try runAppleScript(script)
        let text = descriptor.stringValue ?? ""
        let lines = text.split(separator: "\n")
        guard !lines.isEmpty else { return nil }

        var minColumns = Int.max
        var minRows = Int.max
        var maxColumns = Int.min
        var maxRows = Int.min
        var any = false

        for line in lines {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count >= 3,
                  let columns = Int(parts[1]),
                  let rows = Int(parts[2]) else { continue }
            minColumns = min(minColumns, columns)
            minRows = min(minRows, rows)
            maxColumns = max(maxColumns, columns)
            maxRows = max(maxRows, rows)
            any = true
        }

        guard any else { return nil }
        return TabSizeMetrics(
            minColumns: minColumns,
            minRows: minRows,
            maxColumns: maxColumns,
            maxRows: maxRows
        )
    }

    private func applyFontSize(windowIDs: [Int], fontSize: Int) throws {
        guard !windowIDs.isEmpty else { return }
        let ids = appleScriptIntegerList(windowIDs)
        let script = """
        set targetIDs to \(ids)
        tell application "Terminal"
            repeat with wid in targetIDs
                try
                    if exists window id wid then
                        set font size of selected tab of window id wid to \(fontSize)
                    end if
                end try
            end repeat
        end tell
        """
        _ = try runAppleScript(script)
    }

    private func applyFontSizeWithVerification(windowIDs: [Int], fontSize: Int) throws {
        guard !windowIDs.isEmpty else { return }

        var pending = windowIDs
        for _ in 0..<3 {
            try applyFontSize(windowIDs: pending, fontSize: fontSize)
            usleep(80_000)

            let current = try fetchFontSizes(windowIDs: pending)
            pending = pending.filter { current[$0] != fontSize }
            if pending.isEmpty {
                break
            }
        }
    }

    private func fetchFontSizes(windowIDs: [Int]) throws -> [Int: Int] {
        guard !windowIDs.isEmpty else { return [:] }

        let ids = appleScriptIntegerList(windowIDs)
        let script = """
        set targetIDs to \(ids)
        tell application "Terminal"
            if not running then
                return ""
            end if

            set outLines to {}
            repeat with wid in targetIDs
                try
                    if exists window id wid then
                        set fs to font size of selected tab of window id wid
                        set end of outLines to ((wid as text) & "|" & (fs as text))
                    end if
                end try
            end repeat

            set oldDelims to AppleScript's text item delimiters
            set AppleScript's text item delimiters to linefeed
            set outputText to outLines as text
            set AppleScript's text item delimiters to oldDelims
            return outputText
        end tell
        """

        let descriptor = try runAppleScript(script)
        let text = descriptor.stringValue ?? ""
        let lines = text.split(separator: "\n")
        var result: [Int: Int] = [:]
        result.reserveCapacity(lines.count)

        for line in lines {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count >= 2,
                  let id = Int(parts[0]),
                  let fontSize = Int(parts[1]) else { continue }
            result[id] = fontSize
        }

        return result
    }

    private func applyBoundsWithVerification(windowIDs: [Int], rects: [CGRect], mainScreenHeight: CGFloat) throws {
        guard !windowIDs.isEmpty, !rects.isEmpty else { return }

        var rectByID: [Int: CGRect] = [:]
        rectByID.reserveCapacity(windowIDs.count)
        var expectedByID: [Int: TerminalBounds] = [:]
        expectedByID.reserveCapacity(windowIDs.count)

        for (index, wid) in windowIDs.enumerated() {
            guard index < rects.count else { break }
            let rect = rects[index]
            rectByID[wid] = rect
            expectedByID[wid] = toTerminalBounds(rect: rect, mainScreenHeight: mainScreenHeight)
        }

        var pending = windowIDs.filter { rectByID[$0] != nil }
        for _ in 0..<4 {
            guard !pending.isEmpty else { break }

            var pendingIDs: [Int] = []
            var pendingRects: [CGRect] = []
            pendingIDs.reserveCapacity(pending.count)
            pendingRects.reserveCapacity(pending.count)

            for wid in pending {
                guard let rect = rectByID[wid] else { continue }
                pendingIDs.append(wid)
                pendingRects.append(rect)
            }

            try applyBounds(windowIDs: pendingIDs, rects: pendingRects, mainScreenHeight: mainScreenHeight)
            usleep(90_000)

            let current = try fetchWindowBounds(windowIDs: pendingIDs)
            pending = pendingIDs.filter { wid in
                guard let expected = expectedByID[wid],
                      let actual = current[wid] else {
                    return true
                }
                return !boundsApproximatelyEqual(expected, actual, tolerance: 3)
            }
        }
    }

    private func fetchWindowBounds(windowIDs: [Int]) throws -> [Int: TerminalBounds] {
        guard !windowIDs.isEmpty else { return [:] }

        let ids = appleScriptIntegerList(windowIDs)
        let script = """
        set targetIDs to \(ids)
        tell application "Terminal"
            if not running then
                return ""
            end if

            set outLines to {}
            repeat with wid in targetIDs
                try
                    if exists window id wid then
                        set b to bounds of window id wid
                        set end of outLines to ((wid as text) & "|" & (item 1 of b as text) & "|" & (item 2 of b as text) & "|" & (item 3 of b as text) & "|" & (item 4 of b as text))
                    end if
                end try
            end repeat

            set oldDelims to AppleScript's text item delimiters
            set AppleScript's text item delimiters to linefeed
            set outputText to outLines as text
            set AppleScript's text item delimiters to oldDelims
            return outputText
        end tell
        """

        let descriptor = try runAppleScript(script)
        let text = descriptor.stringValue ?? ""
        let lines = text.split(separator: "\n")
        var result: [Int: TerminalBounds] = [:]
        result.reserveCapacity(lines.count)

        for line in lines {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count >= 5,
                  let id = Int(parts[0]),
                  let left = Int(parts[1]),
                  let top = Int(parts[2]),
                  let right = Int(parts[3]),
                  let bottom = Int(parts[4]) else { continue }
            result[id] = TerminalBounds(left: left, top: top, right: right, bottom: bottom)
        }

        return result
    }

    private func boundsApproximatelyEqual(_ lhs: TerminalBounds, _ rhs: TerminalBounds, tolerance: Int) -> Bool {
        abs(lhs.left - rhs.left) <= tolerance &&
            abs(lhs.top - rhs.top) <= tolerance &&
            abs(lhs.right - rhs.right) <= tolerance &&
            abs(lhs.bottom - rhs.bottom) <= tolerance
    }

    private func applyBounds(windowIDs: [Int], rects: [CGRect], mainScreenHeight: CGFloat) throws {
        guard !windowIDs.isEmpty, !rects.isEmpty else { return }

        var commands: [String] = []
        for (index, wid) in windowIDs.enumerated() {
            guard index < rects.count else { break }
            let bounds = toTerminalBounds(rect: rects[index], mainScreenHeight: mainScreenHeight)
            commands.append("if exists window id \(wid) then")
            commands.append("try")
            commands.append("set bounds of window id \(wid) to {\(bounds.left), \(bounds.top), \(bounds.right), \(bounds.bottom)}")
            commands.append("end try")
            commands.append("end if")
        }

        let script = """
        tell application "Terminal"
            \(commands.joined(separator: "\n            "))
        end tell
        """
        _ = try runAppleScript(script)
    }

    private func appleScriptIntegerList(_ values: [Int]) -> String {
        let body = values.map(String.init).joined(separator: ", ")
        return "{\(body)}"
    }

    private func toTerminalBounds(rect: CGRect, mainScreenHeight: CGFloat) -> TerminalBounds {
        let left = Int(rect.minX.rounded())
        let right = Int(rect.maxX.rounded())
        let top = Int((mainScreenHeight - rect.maxY).rounded())
        let bottom = Int((mainScreenHeight - rect.minY).rounded())
        return TerminalBounds(left: left, top: top, right: right, bottom: bottom)
    }

    private func normalizedProjectName(_ raw: String?) -> String {
        guard let raw else { return "project" }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "project"
        }
        return trimmed
    }

    private func runAppleScript(_ source: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else {
            throw TilerError.appleScriptCompileFailed("Unknown compile error")
        }

        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
            throw TilerError.appleScriptRuntimeFailed(message)
        }

        return result
    }

    private func escapeAppleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

enum TilerError: LocalizedError {
    case activeScreenNotFound
    case appleScriptCompileFailed(String)
    case appleScriptRuntimeFailed(String)

    var errorDescription: String? {
        switch self {
        case .activeScreenNotFound:
            return "No active screen found."
        case let .appleScriptCompileFailed(message):
            return "AppleScript compile failed: \(message)"
        case let .appleScriptRuntimeFailed(message):
            return "AppleScript runtime failed: \(message)"
        }
    }
}
