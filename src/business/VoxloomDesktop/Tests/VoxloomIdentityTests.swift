import AppKit
import Testing
@testable import VoxloomDesktop

@MainActor struct VoxloomIdentityTests {
    @Test func theMenuBarAndSentWaveformsShareTheShapeAndUseDifferentTints() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appending(path: "Voxloom.app")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let contents = root.appending(path: "Contents")
        let resources = contents.appending(path: "Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info = [
            "CFBundleIdentifier": "dev.voxloom.icon-test",
            "CFBundleDisplayName": "小声哔哔",
            "CFBundleIconFile": "AppIcon.icns",
            "CFBundlePackageType": "APPL",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "App/Resources")
        for name in ["AppIcon.icns", "MenuBarIcon.svg"] {
            try FileManager.default.copyItem(at: source.appending(path: name), to: resources.appending(path: name))
        }
        let bundle = try #require(Bundle(url: root))

        let icon = try #require(VoxloomIdentity.menuBarIcon(in: bundle))
        let image = try #require(icon.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: image))
        let empty = try #require(bitmap.colorAt(x: 3 * bitmap.pixelsWide / 4, y: bitmap.pixelsHigh / 4))
        let waveform = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
        #expect(empty.alphaComponent == 0)
        #expect(waveform.alphaComponent > 0.9)
        #expect(icon.size == NSSize(width: 22, height: 16))
        #expect(icon.isTemplate)
        #expect(VoxloomIdentity.displayName(in: bundle) == "小声哔哔")

        let brandWaveform = try #require(VoxloomIdentity.brandWaveform(in: bundle))
        #expect(!brandWaveform.isTemplate)
        let sentImage = try #require(brandWaveform.tiffRepresentation)
        let sentBitmap = try #require(NSBitmapImageRep(data: sentImage))
        let backdrop = try #require(sentBitmap.colorAt(x: 3 * sentBitmap.pixelsWide / 4, y: sentBitmap.pixelsHigh / 4))
        let sentWaveform = try #require(sentBitmap.colorAt(x: sentBitmap.pixelsWide / 2, y: sentBitmap.pixelsHigh / 2)?
            .usingColorSpace(.deviceRGB))
        #expect(backdrop.alphaComponent == 0)
        #expect(sentWaveform.greenComponent > sentWaveform.redComponent)
    }
}
