import AppKit

@MainActor public final class DemoApplicationDelegate: NSObject, NSApplicationDelegate {
    public private(set) var controller: DemoWindowController?
    private let makeController: @MainActor () -> DemoWindowController
    private let reply: @MainActor (Bool) -> Void
    private let activate: @MainActor () -> Void
    public init(makeController: @escaping @MainActor () -> DemoWindowController = {
        DemoWindowController(resources: .init(root: Bundle.main.resourceURL!))
    }, reply: @escaping @MainActor (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) },
       activate: @escaping @MainActor () -> Void = { NSApp.activate(ignoringOtherApps: true) }) {
        self.makeController = makeController
        self.reply = reply
        self.activate = activate
    }
    public func applicationDidFinishLaunching(_ notification: Notification) {
        controller = makeController()
        controller?.showWindow(nil)
        activate()
    }
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { await controller?.shutdown(); reply(true) }
        return .terminateLater
    }
}
