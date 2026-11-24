import AppKit

@MainActor enum VoxloomIdentity {
    static func displayName(in bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Voxloom"
    }

    static func menuBarIcon(in bundle: Bundle = .main) -> NSImage? {
        guard let image = brandWaveform(in: bundle) else { return nil }
        image.isTemplate = true
        image.accessibilityDescription = displayName(in: bundle)
        return image
    }

    static func brandWaveform(in bundle: Bundle = .main) -> NSImage? {
        guard let url = bundle.url(forResource: "MenuBarIcon", withExtension: "svg") else { return nil }
        return NSImage(contentsOf: url)
    }
}
