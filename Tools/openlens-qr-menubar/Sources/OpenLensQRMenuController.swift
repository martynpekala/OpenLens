import AppKit
import CoreImage

@MainActor
final class OpenLensQRMenuController: NSObject, NSMenuDelegate {
    private let store: OpenLensQRMenuStore
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var windowController: NSWindowController?

    private let qrPreviewItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let qrSectionSeparatorItem = NSMenuItem.separator()
    private let workspaceNameItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let workspacePathItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let chooseFolderItem = NSMenuItem(title: "Choose Folder…", action: nil, keyEquivalent: "")
    private let launchItem = NSMenuItem(title: "Launch openlens-qr", action: nil, keyEquivalent: "")
    private let refreshQRItem = NSMenuItem(title: "Refresh QR Code", action: nil, keyEquivalent: "")
    private let clearSelectionItem = NSMenuItem(title: "Clear Saved Folder", action: nil, keyEquivalent: "")
    private let statusMessageItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "Quit OpenLens QR", action: nil, keyEquivalent: "q")

    private var chooseFolderTitle: String {
        store.canClearSelection ? "Change Folder…" : "Choose Folder…"
    }

    init(store: OpenLensQRMenuStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureStatusItem()
        configureMenu()
        refreshMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshMenu()
    }

    @objc
    func chooseFolder(_ sender: Any?) {
        store.chooseDirectory()
        refreshMenu()
        presentErrorAlertIfNeeded()
    }

    @objc
    func launchOpenLensQR(_ sender: Any?) {
        store.launchOpenLensQR()
        refreshMenu()
        presentErrorAlertIfNeeded()
    }

    @objc
    func clearSavedFolder(_ sender: Any?) {
        store.clearSelection()
        refreshMenu()
    }

    @objc
    func refreshQRCode(_ sender: Any?) {
        store.refreshQRCode()
        refreshMenu()
        presentErrorAlertIfNeeded()
    }

    @objc
    func quit(_ sender: Any?) {
        NSApplication.shared.terminate(sender)
    }

    @objc
    func openControlWindow(_ sender: Any?) {
        let window = makeControlWindow()
        windowController = NSWindowController(window: window)
        window.center()
        window.makeKeyAndOrderFront(sender)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }

        if let image = NSImage(systemSymbolName: "qrcode", accessibilityDescription: "OpenLens QR") {
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.title = " QR"
        } else {
            button.title = "QR"
        }

        button.toolTip = "OpenLens QR"
        statusItem.isVisible = true
        statusItem.menu = menu
    }

    private func configureMenu() {
        menu.delegate = self

        qrPreviewItem.isEnabled = false
        workspaceNameItem.isEnabled = false
        workspacePathItem.isEnabled = false
        statusMessageItem.isEnabled = false

        chooseFolderItem.target = self
        chooseFolderItem.action = #selector(chooseFolder(_:))

        launchItem.target = self
        launchItem.action = #selector(launchOpenLensQR(_:))

        refreshQRItem.target = self
        refreshQRItem.action = #selector(refreshQRCode(_:))

        clearSelectionItem.target = self
        clearSelectionItem.action = #selector(clearSavedFolder(_:))

        let openWindowItem = NSMenuItem(title: "Open Control Window", action: #selector(openControlWindow(_:)), keyEquivalent: "")
        openWindowItem.target = self

        quitItem.target = self
        quitItem.action = #selector(quit(_:))

        menu.items = [
            qrPreviewItem,
            refreshQRItem,
            qrSectionSeparatorItem,
            workspaceNameItem,
            workspacePathItem,
            .separator(),
            chooseFolderItem,
            launchItem,
            clearSelectionItem,
            openWindowItem,
            .separator(),
            statusMessageItem,
            .separator(),
            quitItem,
        ]
    }

    private func refreshMenu() {
        qrPreviewItem.isHidden = !store.hasLastGeneratedQRCode
        qrPreviewItem.view = store.lastGeneratedQRPayload.map(makeQRPreviewView(payload:))
        refreshQRItem.isHidden = !store.hasLastGeneratedQRCode
        qrSectionSeparatorItem.isHidden = !store.hasLastGeneratedQRCode

        workspaceNameItem.title = store.selectedDirectoryName
        workspacePathItem.title = abbreviatedPath(store.selectedDirectoryPath)
        workspacePathItem.toolTip = store.selectedDirectoryPath

        launchItem.isEnabled = store.canLaunch
        refreshQRItem.isEnabled = store.hasLastGeneratedQRCode
        clearSelectionItem.isEnabled = store.canClearSelection
        chooseFolderItem.title = chooseFolderTitle
        statusMessageItem.title = store.footerMessage
    }

    private func abbreviatedPath(_ path: String) -> String {
        let prefix = NSHomeDirectory()
        if path.hasPrefix(prefix) {
            return "~" + path.dropFirst(prefix.count)
        }

        return path
    }

    private func presentErrorAlertIfNeeded() {
        guard store.isShowingError else {
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "OpenLens QR"
        alert.informativeText = store.footerMessage
        alert.addButton(withTitle: "OK")
        NSApplication.shared.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func makeControlWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 220),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = "OpenLens QR"
        window.isReleasedWhenClosed = false

        let contentView = NSView(frame: window.contentView?.bounds ?? .zero)
        contentView.autoresizingMask = [.width, .height]

        let nameField = labelField(text: store.selectedDirectoryName, frame: NSRect(x: 20, y: 160, width: 420, height: 24), font: .boldSystemFont(ofSize: 14))
        let pathField = labelField(text: store.selectedDirectoryPath, frame: NSRect(x: 20, y: 130, width: 420, height: 36), font: .systemFont(ofSize: 12))
        pathField.lineBreakMode = .byTruncatingMiddle

        let statusField = labelField(text: store.footerMessage, frame: NSRect(x: 20, y: 30, width: 420, height: 44), font: .systemFont(ofSize: 12))
        statusField.lineBreakMode = .byWordWrapping
        statusField.maximumNumberOfLines = 2
        statusField.textColor = store.isShowingError ? .systemRed : .secondaryLabelColor

        let chooseButton = NSButton(title: chooseFolderTitle, target: self, action: #selector(chooseFolder(_:)))
        chooseButton.frame = NSRect(x: 20, y: 84, width: 130, height: 32)

        let launchButton = NSButton(title: "Launch", target: self, action: #selector(launchOpenLensQR(_:)))
        launchButton.frame = NSRect(x: 160, y: 84, width: 100, height: 32)
        launchButton.bezelStyle = .rounded
        launchButton.isEnabled = store.canLaunch

        let clearButton = NSButton(title: "Clear Saved Folder", target: self, action: #selector(clearSavedFolder(_:)))
        clearButton.frame = NSRect(x: 270, y: 84, width: 150, height: 32)
        clearButton.isEnabled = store.canClearSelection

        contentView.addSubview(nameField)
        contentView.addSubview(pathField)
        contentView.addSubview(statusField)
        contentView.addSubview(chooseButton)
        contentView.addSubview(launchButton)
        contentView.addSubview(clearButton)

        window.contentView = contentView
        return window
    }

    private func labelField(text: String, frame: NSRect, font: NSFont) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.frame = frame
        field.font = font
        field.isBezeled = false
        field.drawsBackground = false
        field.isEditable = false
        field.isSelectable = true
        return field
    }

    private func makeQRPreviewView(payload: OpenLensQRPayloadModel) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 280))

        let titleField = labelField(text: "Last generated QR", frame: NSRect(x: 20, y: 248, width: 200, height: 20), font: .boldSystemFont(ofSize: 13))
        titleField.alignment = .center

        let serverField = labelField(text: payload.serverURL, frame: NSRect(x: 20, y: 228, width: 200, height: 18), font: .systemFont(ofSize: 11))
        serverField.alignment = .center
        serverField.textColor = .secondaryLabelColor

        let qrImageView = NSImageView(frame: NSRect(x: 30, y: 28, width: 180, height: 180))
        qrImageView.imageScaling = .scaleProportionallyUpOrDown
        qrImageView.image = qrImage(from: payload.deepLink)

        let generatedAtField = labelField(
            text: DateFormatter.localizedString(from: payload.generatedAt, dateStyle: .none, timeStyle: .short),
            frame: NSRect(x: 20, y: 8, width: 200, height: 16),
            font: .systemFont(ofSize: 10)
        )
        generatedAtField.alignment = .center
        generatedAtField.textColor = .secondaryLabelColor

        view.addSubview(titleField)
        view.addSubview(serverField)
        view.addSubview(qrImageView)
        view.addSubview(generatedAtField)
        return view
    }

    private func qrImage(from string: String) -> NSImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else {
            return nil
        }

        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let ciImage = filter.outputImage else {
            return nil
        }

        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext(options: nil)

        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: scaledImage.extent.width, height: scaledImage.extent.height))
    }
}
