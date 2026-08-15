import AppKit
import CoreImage

@MainActor
final class RemoteMenuController: NSObject, NSMenuDelegate {
    private let store: RemoteAgentStore
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var pairingWindowController: NSWindowController?

    init(store: RemoteAgentStore) {
        self.store = store
        super.init()
        configureStatusItem()
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: "OpenLens Remote")
        image?.isTemplate = true
        button.image = image
        button.toolTip = "OpenLens Remote"
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let status = NSMenuItem(title: store.statusTitle, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        if let lastError = store.lastError {
            let error = NSMenuItem(title: String(lastError.prefix(100)), action: nil, keyEquivalent: "")
            error.isEnabled = false
            error.toolTip = lastError
            menu.addItem(error)
        }

        menu.addItem(.separator())
        let enabled = item(
            title: "Remote Access Enabled",
            action: #selector(toggleRemoteAccess(_:))
        )
        enabled.state = store.remoteEnabled ? .on : .off
        menu.addItem(enabled)

        let pair = item(title: "Pair Device…", action: #selector(pairDevice(_:)))
        pair.isEnabled = store.remoteEnabled
            && store.gatewayRunning
            && store.tunnelRunning
            && store.hasTunnelConfiguration
            && !store.accessRotationRequired
        menu.addItem(pair)
        menu.addItem(item(title: "Configure Cloudflare Access…", action: #selector(configureTunnel(_:))))

        menu.addItem(.separator())
        menu.addItem(workspacesMenuItem())
        menu.addItem(devicesMenuItem())

        menu.addItem(.separator())
        let launchAtLogin = item(title: "Launch After Login", action: #selector(toggleLaunchAtLogin(_:)))
        launchAtLogin.state = RemoteAgentLifecycle.launchesAtLogin ? .on : .off
        menu.addItem(launchAtLogin)
        menu.addItem(item(title: "Export Redacted Diagnostics…", action: #selector(exportDiagnostics(_:))))
        menu.addItem(item(title: "Check for Updates…", action: #selector(checkForUpdates(_:))))

        menu.addItem(.separator())
        menu.addItem(item(title: "Quit OpenLens Remote", action: #selector(quit(_:)), keyEquivalent: "q"))
    }

    private func workspacesMenuItem() -> NSMenuItem {
        let root = NSMenuItem(title: "Workspaces", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Workspaces")
        let workspaces = store.workspaceRegistry.all()
        if workspaces.isEmpty {
            let empty = NSMenuItem(title: "No allowed workspaces", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for workspace in workspaces {
                let row = item(title: workspace.displayName, action: #selector(removeWorkspace(_:)))
                row.representedObject = workspace.id
                row.toolTip = "Remove \(workspace.path) from the Remote allowlist"
                submenu.addItem(row)
            }
        }
        submenu.addItem(.separator())
        submenu.addItem(item(title: "Add Workspace…", action: #selector(addWorkspace(_:))))
        root.submenu = submenu
        return root
    }

    private func devicesMenuItem() -> NSMenuItem {
        let root = NSMenuItem(title: "Trusted Devices", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Trusted Devices")
        let devices = store.deviceRegistry.all()
        if devices.isEmpty {
            let empty = NSMenuItem(title: "No paired devices", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for device in devices {
                let row = NSMenuItem(title: device.name, action: nil, keyEquivalent: "")
                let actions = NSMenu(title: device.name)
                let remove = item(title: "Remove Device…", action: #selector(revokeDevice(_:)))
                remove.representedObject = device.id
                actions.addItem(remove)
                let compromised = item(
                    title: "Lost or Compromised…",
                    action: #selector(markDeviceCompromised(_:))
                )
                compromised.representedObject = device.id
                actions.addItem(compromised)
                row.submenu = actions
                submenu.addItem(row)
            }
            submenu.addItem(.separator())
            submenu.addItem(item(title: "Revoke All Devices…", action: #selector(revokeAllDevices(_:))))
        }
        root.submenu = submenu
        return root
    }

    @objc private func toggleRemoteAccess(_ sender: NSMenuItem) {
        store.setRemoteEnabled(!store.remoteEnabled)
        rebuildMenu()
    }

    @objc private func configureTunnel(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Configure Cloudflare Tunnel and Access"
        alert.informativeText = "Protect the entire hostname with a Service Auth policy and enable Protect with Access on the Tunnel route to http://127.0.0.1:49634. OpenLens will verify the public path before enabling Remote access."
        alert.addButton(withTitle: "Save and Verify")
        alert.addButton(withTitle: "Cancel")

        let form = CloudflareConfigurationForm(
            hostname: store.hostname,
            teamDomain: store.accessTeamDomain,
            audience: store.accessAudience,
            hasTunnelConfiguration: store.hasTunnelConfiguration,
            hasClientID: store.accessClientID != nil,
            requiresAccessRotation: store.accessRotationRequired
        )
        alert.accessoryView = form

        NSApplication.shared.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                try await store.configureCloudflare(
                    hostname: form.hostnameField.stringValue,
                    connectorToken: form.tunnelTokenField.stringValue,
                    teamDomain: form.teamDomainField.stringValue,
                    audience: form.audienceField.stringValue,
                    clientID: form.clientIDField.stringValue,
                    clientSecret: form.clientSecretField.stringValue
                )
            } catch {
                store.report(error)
                showError(error)
            }
            rebuildMenu()
        }
    }

    @objc private func pairDevice(_ sender: Any?) {
        do {
            let offer = try store.makePairingOffer()
            guard let link = offer.deepLinkURL?.absoluteString,
                  let qrImage = qrImage(from: link) else {
                throw RemoteProtocolError.invalidPairingOffer
            }
            showPairingWindow(image: qrImage, offer: offer)
        } catch {
            store.report(error)
            showError(error)
        }
    }

    @objc private func addWorkspace(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Allow Workspace"
        panel.message = "Remote devices can fully operate only in explicitly allowed workspaces."
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.addWorkspace(url: url)
        } catch {
            store.report(error)
            showError(error)
        }
        rebuildMenu()
    }

    @objc private func removeWorkspace(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        store.removeWorkspace(id: id)
        rebuildMenu()
    }

    @objc private func revokeDevice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Revoke this device?"
        alert.informativeText = "Its active Remote connection will be closed and it cannot reconnect without a new physical QR pairing."
        alert.addButton(withTitle: "Revoke")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.revokeDevice(id: id)
        rebuildMenu()
    }

    @objc private func revokeAllDevices(_ sender: Any?) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Revoke all devices?"
        alert.informativeText = "Every active Remote connection will be closed. Each iPhone and iPad must be paired again at this Mac."
        alert.addButton(withTitle: "Revoke All")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.revokeAllDevices()
        rebuildMenu()
    }

    @objc private func markDeviceCompromised(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Mark this device as lost or compromised?"
        alert.informativeText = "Remote access will stop immediately, all devices will be revoked, and a new Cloudflare Access Service Token must be created. Every device must then be paired again."
        alert.addButton(withTitle: "Stop Remote Access")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.markDeviceLostOrCompromised(id: id)
        rebuildMenu()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            try store.setLaunchesAtLogin(!RemoteAgentLifecycle.launchesAtLogin)
        } catch {
            store.report(error)
            showError(error)
        }
        rebuildMenu()
    }

    @objc private func exportDiagnostics(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "OpenLens-Remote-diagnostics.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportDiagnostics(to: url)
        } catch {
            store.report(error)
            showError(error)
        }
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        Task {
            do {
                let release = try await ManualUpdateChecker().latestRelease()
                let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
                let isCurrent = release.matches(version: current)
                let alert = NSAlert()
                alert.messageText = isCurrent
                    ? "OpenLens Remote is up to date"
                    : "OpenLens Remote \(release.tagName) is available"
                alert.informativeText = release.name ?? "Updates are downloaded and installed only after your confirmation. macOS verifies the signed and notarized app."
                alert.addButton(withTitle: isCurrent ? "OK" : "Open Release")
                if !isCurrent { alert.addButton(withTitle: "Cancel") }
                if alert.runModal() == .alertFirstButtonReturn, !isCurrent {
                    NSWorkspace.shared.open(release.pageURL)
                }
            } catch {
                store.report(error)
                showError(error)
            }
        }
    }

    @objc private func quit(_ sender: Any?) {
        store.stopAll()
        NSApplication.shared.terminate(sender)
    }

    private func showPairingWindow(image: NSImage, offer: RemotePairingOffer) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 550),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pair OpenLens Device"
        window.isReleasedWhenClosed = false

        window.contentView = RemotePairingViewFactory.make(
            image: image,
            gatewayFingerprint: store.gatewayFingerprint,
            expiresAt: offer.expiresAt
        )

        pairingWindowController = NSWindowController(window: window)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func qrImage(from string: String) -> NSImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }

    private func item(title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        NSApplication.shared.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

@MainActor
final class CloudflareConfigurationForm: NSView {
    let hostnameField: NSTextField
    let tunnelTokenField: NSSecureTextField
    let teamDomainField: NSTextField
    let audienceField: NSTextField
    let clientIDField: NSTextField
    let clientSecretField: NSSecureTextField

    init(
        hostname: String?,
        teamDomain: String?,
        audience: String?,
        hasTunnelConfiguration: Bool,
        hasClientID: Bool,
        requiresAccessRotation: Bool
    ) {
        hostnameField = NSTextField(string: hostname ?? "")
        tunnelTokenField = NSSecureTextField(string: "")
        teamDomainField = NSTextField(string: teamDomain ?? "")
        audienceField = NSTextField(string: audience ?? "")
        clientIDField = NSTextField(string: "")
        clientSecretField = NSSecureTextField(string: "")
        super.init(frame: NSRect(x: 0, y: 0, width: 520, height: 228))
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        hostnameField.placeholderString = "remote.example.com"
        tunnelTokenField.placeholderString = hasTunnelConfiguration
            ? "Leave blank to keep saved token"
            : "Paste Tunnel token"
        teamDomainField.placeholderString = "your-team.cloudflareaccess.com"
        audienceField.placeholderString = "Access application AUD"
        clientIDField.placeholderString = requiresAccessRotation
            ? "Enter NEW Service Token Client ID"
            : (hasClientID ? "Leave blank to keep saved Client ID" : "Service Token Client ID")
        clientSecretField.placeholderString = requiresAccessRotation
            ? "Enter NEW Service Token Client Secret"
            : (hasTunnelConfiguration
                ? "Leave blank to keep saved Client Secret"
                : "Service Token Client Secret")

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Public hostname"), hostnameField],
            [NSTextField(labelWithString: "Tunnel token"), tunnelTokenField],
            [NSTextField(labelWithString: "Access team domain"), teamDomainField],
            [NSTextField(labelWithString: "Application AUD"), audienceField],
            [NSTextField(labelWithString: "Service Token ID"), clientIDField],
            [NSTextField(labelWithString: "Service Token secret"), clientSecretField],
        ])
        grid.frame = bounds
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 340
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        for rowIndex in 0..<grid.numberOfRows {
            grid.row(at: rowIndex).height = 28
            grid.row(at: rowIndex).yPlacement = .center
        }
        addSubview(grid)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
enum RemotePairingViewFactory {
    static func make(
        image: NSImage,
        gatewayFingerprint: String,
        expiresAt: Date
    ) -> NSView {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 550))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let title = NSTextField(labelWithString: "Scan with OpenLens")
        title.font = .boldSystemFont(ofSize: 20)
        title.alignment = .center
        title.frame = NSRect(x: 30, y: 500, width: 360, height: 30)
        let subtitle = NSTextField(wrappingLabelWithString: "This code contains the Cloudflare Access token and expires for pairing in 5 minutes. Scan it only while physically at this Mac.")
        subtitle.alignment = .center
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: 45, y: 430, width: 330, height: 60)
        let imageView = NSImageView(frame: NSRect(x: 50, y: 100, width: 320, height: 320))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        let fingerprint = NSTextField(labelWithString: "Gateway fingerprint: \(gatewayFingerprint)")
        fingerprint.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        fingerprint.alignment = .center
        fingerprint.textColor = .secondaryLabelColor
        fingerprint.frame = NSRect(x: 20, y: 58, width: 380, height: 20)
        let expiry = NSTextField(labelWithString: "Expires \(DateFormatter.localizedString(from: expiresAt, dateStyle: .none, timeStyle: .medium))")
        expiry.alignment = .center
        expiry.frame = NSRect(x: 20, y: 30, width: 380, height: 18)
        content.addSubview(title)
        content.addSubview(subtitle)
        content.addSubview(imageView)
        content.addSubview(fingerprint)
        content.addSubview(expiry)
        return content
    }
}
