import AppKit
import VoiceDemoUI

@main struct VoiceDemoApplication {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = DemoApplicationDelegate()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "退出语音 Demo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        application.mainMenu = menu
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
