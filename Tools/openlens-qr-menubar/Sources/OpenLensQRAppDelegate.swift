import AppKit

final class OpenLensQRAppDelegate: NSObject, NSApplicationDelegate {
    private var menuController: OpenLensQRMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuController = OpenLensQRMenuController(store: OpenLensQRMenuStore())
    }
}
