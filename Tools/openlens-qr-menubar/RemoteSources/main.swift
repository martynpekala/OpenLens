import AppKit

let application = NSApplication.shared
let delegate = MainActor.assumeIsolated { OpenLensRemoteAppDelegate() }
application.setActivationPolicy(.accessory)
application.delegate = delegate
application.run()
