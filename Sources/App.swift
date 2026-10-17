import AppKit
import AVFoundation
import ServiceManagement

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let host = VoiceHost()
    private var preferences = SavedPreferences.load()
    private var appliedSound = VoiceSettings.balanced
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private let statusLabel = NSTextField(wrappingLabelWithString: "Choose your microphone to begin")
    private let startButton = NSButton(title: "Start microphone", target: nil, action: #selector(toggle))
    private let inputPicker = NSPopUpButton()
    private let channelPicker = NSPopUpButton()
    private let presetPicker = NSPopUpButton()
    private let compression = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: #selector(soundChanged))
    private let tone = NSSlider(value: 0.65, minValue: 0, maxValue: 1, target: nil, action: #selector(soundChanged))
    private let rejection = NSSlider(value: 0.6, minValue: 0, maxValue: 1, target: nil, action: #selector(soundChanged))
    private let inputMeter = NSLevelIndicator(), outputMeter = NSLevelIndicator()
    private let inputLevel = NSTextField(labelWithString: "—"), outputLevel = NSTextField(labelWithString: "—")
    private let autoButton = NSButton(checkboxWithTitle: "Start processing when SoundOff opens", target: nil, action: #selector(setAutoStart))
    private let loginButton = NSButton(checkboxWithTitle: "Open SoundOff at login", target: nil, action: #selector(setLogin))
    private let loginStatus = NSTextField(wrappingLabelWithString: "")
    private var timer: Timer?
    private var wanted = false, sleeping = false, permissionPending = false
    private var tick = 0, lastFrames: UInt64 = 0
    private var retryAt = Date.distantPast
    private var knownDevices: [AudioDevice] = []
    private var notifications: [NSObjectProtocol] = []

    static func main() {
        let app = NSApplication.shared, delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenus(); buildWindow(); syncSliders(); refreshDevices(); refreshLogin()
        appliedSound = preferences.sound
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.refresh() }
        let center = NSWorkspace.shared.notificationCenter
        notifications.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }; self.sleeping = true; self.host.stop(); self.updateStatus("Paused while your Mac sleeps")
        })
        notifications.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sleeping = false; self?.retryAt = Date().addingTimeInterval(2)
        })
        if preferences.startProcessingOnOpen, preferences.inputUID != nil { wanted = true; requestStart() }
    }
    private func buildMenus() {
        let menu = NSMenu(), top = NSMenuItem(), appMenu = NSMenu()
        menu.addItem(top); top.submenu = appMenu
        appMenu.addItem(withTitle: "Show SoundOff", action: #selector(show), keyEquivalent: "0").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit SoundOff", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = menu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let quick = NSMenu()
        quick.addItem(withTitle: "Show SoundOff", action: #selector(show), keyEquivalent: "").target = self
        quick.addItem(withTitle: "Start / Stop", action: #selector(toggle), keyEquivalent: "").target = self
        quick.addItem(.separator())
        quick.addItem(withTitle: "Quit SoundOff", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = quick
        updateStatus("Choose your microphone to begin")
    }
    private func label(_ text: String, size: CGFloat = 12, secondary: Bool = false) -> NSTextField {
        let view = NSTextField(wrappingLabelWithString: text)
        view.font = .systemFont(ofSize: size)
        view.textColor = secondary ? .secondaryLabelColor : .labelColor
        return view
    }
    private func row(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = spacing
        return stack
    }
    private func control(title: String, slider: NSSlider, left: String, right: String, help: String) -> NSView {
        let heading = label(title, size: 15); heading.font = .systemFont(ofSize: 15, weight: .semibold)
        let a = label(left, size: 11, secondary: true), b = label(right, size: 11, secondary: true)
        let space = NSView(); space.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let endpoints = row([a, space, b]); endpoints.distribution = .fill
        let stack = NSStackView(views: [heading, slider, endpoints, label(help, secondary: true)])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 5
        slider.target = self; slider.isContinuous = true
        slider.setAccessibilityLabel(title)
        slider.setAccessibilityHelp("Left: \(left). Right: \(right).")
        slider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        endpoints.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }
    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 590, height: 750), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "SoundOff"; window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 540, height: 580); window.center()
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor), scroll.topAnchor.constraint(equalTo: window.contentView!.topAnchor), scroll.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor)])
        let title = label("SoundOff", size: 30); title.font = .systemFont(ofSize: 30, weight: .bold)
        let subtitle = label("Your microphone. Your sound.", size: 14, secondary: true)
        inputPicker.target = self; inputPicker.action = #selector(deviceChanged); inputPicker.setAccessibilityLabel("Microphone")
        channelPicker.target = self; channelPicker.action = #selector(channelChanged); channelPicker.setAccessibilityLabel("Input channel")
        let microphoneRow = row([inputPicker, channelPicker]); inputPicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        startButton.target = self; startButton.bezelStyle = .rounded; startButton.controlSize = .large
        let startRow = row([startButton, statusLabel]); statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for meter in [inputMeter, outputMeter] { meter.levelIndicatorStyle = .continuousCapacity; meter.minValue = -60; meter.maxValue = 0; meter.warningValue = -6; meter.criticalValue = -1; meter.doubleValue = -60 }
        for level in [inputLevel, outputLevel] { level.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); level.widthAnchor.constraint(equalToConstant: 70).isActive = true }
        let inputRow = row([label("Input", size: 11), inputMeter, inputLevel]), outputRow = row([label("Output", size: 11), outputMeter, outputLevel])
        presetPicker.addItems(withTitles: ["Balanced", "Natural", "Warm Broadcast", "Custom"])
        presetPicker.menu?.autoenablesItems = false; presetPicker.item(at: 3)?.isEnabled = false
        presetPicker.target = self; presetPicker.action = #selector(presetChanged); presetPicker.setAccessibilityLabel("Sound preset")
        let presetRow = row([label("Sound preset", size: 13), presetPicker])
        let controls = [
            control(title: "Compression", slider: compression, left: "More compressed", right: "More dynamic range", help: "Make quiet and loud phrases more even, or keep their natural contrast."),
            control(title: "Tone", slider: tone, left: "Deeper", right: "More natural", help: "Add body and soften bright highs. Your pitch stays the same."),
            control(title: "Noise rejection", slider: rejection, left: "More rejection", right: "More room sound", help: "Quiet the room between phrases. Move right if soft words get cut off.")
        ]
        autoButton.target = self; loginButton.target = self
        autoButton.state = preferences.startProcessingOnOpen ? .on : .off
        loginStatus.font = .systemFont(ofSize: 11); loginStatus.textColor = .secondaryLabelColor
        let driver = NSButton(title: "Get BlackHole 2ch", target: self, action: #selector(getDriver)); driver.bezelStyle = .rounded
        let routing = row([label("In your call app, choose BlackHole 2ch as the microphone.\nKeep your usual camera and speakers.", secondary: true), driver])
        let note = label("All audio stays on your Mac. Closing this window keeps processing active. Quit stops it.", size: 11, secondary: true)
        let content = TopAlignedStack(views: [title, subtitle, microphoneRow, startRow, inputRow, outputRow, NSBox.separator(), presetRow] + controls + [NSBox.separator(), routing, autoButton, loginButton, loginStatus, note])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 22, left: 26, bottom: 24, right: 26)
        content.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = content
        content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        for view in [microphoneRow, startRow, inputRow, outputRow, routing] + controls { view.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -52).isActive = true }
        inputMeter.setContentHuggingPriority(.defaultLow, for: .horizontal); outputMeter.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }
    private func refreshDevices() {
        let devices = AudioDevice.all().filter(\.isMicrophone)
        let changed = devices.map { "\($0.uid):\($0.inputChannels)" } != knownDevices.map { "\($0.uid):\($0.inputChannels)" }
        guard changed || inputPicker.numberOfItems == 0 else { return }
        knownDevices = devices
        inputPicker.removeAllItems(); inputPicker.addItem(withTitle: "Choose a microphone…")
        for device in devices { inputPicker.addItem(withTitle: device.name); inputPicker.lastItem?.representedObject = device.uid }
        if let uid = preferences.inputUID {
            if let item = inputPicker.itemArray.first(where: { $0.representedObject as? String == uid }) { inputPicker.select(item) }
            else { inputPicker.addItem(withTitle: "Selected microphone disconnected"); inputPicker.lastItem?.representedObject = uid; inputPicker.selectItem(at: inputPicker.numberOfItems-1) }
        }
        updateChannels()
    }
    private func updateChannels() {
        channelPicker.removeAllItems()
        let count = knownDevices.first(where: { $0.uid == preferences.inputUID })?.inputChannels ?? 0
        if count > 0 && preferences.inputChannel >= count {
            preferences.inputChannel = 0; preferences.save()
            if host.isRunning { host.stop(); retryAt = Date() }
        }
        if count == 0 { channelPicker.addItem(withTitle: "Channel —") }
        else { for i in 0..<count { channelPicker.addItem(withTitle: "Channel \(i+1)") }; channelPicker.selectItem(at: min(preferences.inputChannel, count-1)) }
        channelPicker.isEnabled = count > 1
    }
    @objc private func deviceChanged() {
        host.stop(); preferences.inputUID = inputPicker.selectedItem?.representedObject as? String; preferences.inputChannel = 0
        preferences.save(); updateChannels()
        if wanted { requestStart() } else { updateStatus(preferences.inputUID == nil ? "Choose your microphone to begin" : "Ready when you are") }
    }
    @objc private func channelChanged() {
        host.stop(); preferences.inputChannel = channelPicker.indexOfSelectedItem; preferences.save()
        if wanted { requestStart() }
    }
    @objc private func soundChanged() {
        preferences.sound = VoiceSettings(compression: 1-compression.doubleValue, depth: 1-tone.doubleValue, rejection: 1-rejection.doubleValue).normalized
        preferences.save(); updatePresetName()
    }
    private func syncSliders() {
        compression.doubleValue = 1-preferences.sound.compression; tone.doubleValue = 1-preferences.sound.depth; rejection.doubleValue = 1-preferences.sound.rejection
        updatePresetName()
    }
    private func updatePresetName() {
        let presets = [VoiceSettings.balanced, .natural, .warmBroadcast]
        presetPicker.selectItem(at: presets.firstIndex(where: { $0.distance(to: preferences.sound) < 0.0001 }) ?? 3)
    }
    @objc private func presetChanged() {
        let presets = [VoiceSettings.balanced, .natural, .warmBroadcast]
        guard presetPicker.indexOfSelectedItem < presets.count else { return }
        preferences.sound = presets[presetPicker.indexOfSelectedItem]; preferences.save(); syncSliders()
    }
    @objc private func show() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func getDriver() { NSWorkspace.shared.open(URL(string: "https://existential.audio/blackhole/")!) }
    @objc private func setAutoStart() { preferences.startProcessingOnOpen = autoButton.state == .on; preferences.save() }
    @objc private func setLogin() {
        do { if loginButton.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { loginStatus.stringValue = "Login setting: \(error.localizedDescription)"; loginButton.state = SMAppService.mainApp.status == .enabled ? .on : .off; return }
        refreshLogin()
    }
    private func refreshLogin() {
        let status = SMAppService.mainApp.status
        loginButton.state = status == .enabled || status == .requiresApproval ? .on : .off
        loginStatus.stringValue = status == .requiresApproval ? "Allow SoundOff in System Settings → General → Login Items." : ""
    }
    @objc private func toggle() {
        if wanted { wanted = false; host.stop(); updateStatus("Microphone stopped") }
        else { wanted = true; requestStart() }
    }
    private func requestStart() {
        guard preferences.inputUID != nil else { wanted = false; updateStatus("Choose a microphone first"); return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: start()
        case .notDetermined:
            guard !permissionPending else { return }; permissionPending = true; updateStatus("Allow microphone access to continue")
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in DispatchQueue.main.async {
                guard let self else { return }; self.permissionPending = false
                if allowed { self.start() } else { self.wanted = false; self.updateStatus("Allow microphone access in System Settings → Privacy & Security.") }
            } }
        default: wanted = false; updateStatus("Allow microphone access in System Settings → Privacy & Security.")
        }
    }
    private func start() {
        guard wanted, !sleeping, !permissionPending, let uid = preferences.inputUID else { return }
        do {
            try host.start(inputUID: uid, inputChannel: preferences.inputChannel, settings: preferences.sound)
            appliedSound = preferences.sound; lastFrames = 0; updateStatus("Live · ready for your call")
        } catch { host.stop(); retryAt = Date().addingTimeInterval(3); updateStatus(error.localizedDescription) }
    }
    private func updateStatus(_ text: String) {
        statusLabel.stringValue = text; statusLabel.textColor = host.isRunning ? .systemGreen : .secondaryLabelColor
        startButton.title = wanted ? "Stop microphone" : "Start microphone"
        statusItem?.button?.image = NSImage(systemSymbolName: host.isRunning ? "mic.fill" : "mic.slash", accessibilityDescription: "SoundOff: \(text)")
    }
    private func refresh() {
        func db(_ value: Float) -> Double { max(-60, 20*log10(Double(max(value, 0.000001)))) }
        let a = db(host.inputPeak.load(ordering: .relaxed)), b = db(host.outputPeak.load(ordering: .relaxed))
        // Short peak hold makes speech peaks visible between UI updates.
        inputMeter.doubleValue = max(a, inputMeter.doubleValue-2); outputMeter.doubleValue = max(b, outputMeter.doubleValue-2)
        inputLevel.stringValue = String(format: "%5.1f dB", inputMeter.doubleValue); outputLevel.stringValue = String(format: "%5.1f dB", outputMeter.doubleValue)
        if host.isRunning, appliedSound != preferences.sound {
            appliedSound = appliedSound.distance(to: preferences.sound) < 0.001 ? preferences.sound : appliedSound.blended(toward: preferences.sound, fraction: 0.3)
            do { try host.apply(appliedSound) } catch { wanted = false; host.stop(); updateStatus(error.localizedDescription) }
        }
        tick += 1; guard tick % 40 == 0 else { return }
        refreshDevices(); refreshLogin()
        if host.isRunning {
            let devices = AudioDevice.all(), frames = host.renderedFrames.load(ordering: .relaxed)
            if !devices.contains(where: { $0.id == host.microphoneID }) || !devices.contains(where: { $0.id == host.outputID }) || host.callbackError.load(ordering: .relaxed) != 0 || frames == lastFrames {
                host.stop(); retryAt = Date().addingTimeInterval(3); updateStatus("Reconnecting your microphone…")
            }
            lastFrames = frames
        } else if wanted && !sleeping && !permissionPending && Date() >= retryAt && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { start() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
    func applicationWillTerminate(_ notification: Notification) { timer?.invalidate(); host.stop() }
}
private extension NSBox {
    static func separator() -> NSBox { let line = NSBox(); line.boxType = .separator; return line }
}

private final class TopAlignedStack: NSStackView {
    override var isFlipped: Bool { true }
}
