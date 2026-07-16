import AppKit

@MainActor
final class OpenLensRemoteAppDelegate: NSObject, NSApplicationDelegate {
    private var menuController: RemoteMenuController?
    private var store: RemoteAgentStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let store = try RemoteAgentStore()
            self.store = store
            menuController = RemoteMenuController(store: store)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "OpenLens Remote could not start"
            alert.runModal()
            NSApplication.shared.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.stopAll()
    }
}
