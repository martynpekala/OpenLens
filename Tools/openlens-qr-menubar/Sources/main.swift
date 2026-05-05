import AppKit

let app = NSApplication.shared
let delegate = OpenLensQRAppDelegate()

app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
