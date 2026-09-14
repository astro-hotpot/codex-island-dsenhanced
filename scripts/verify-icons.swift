import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let resources = root.appendingPathComponent("Contents/Resources")
let names = ["CodexIsland.icns", "codexisland_logo.png", "claude_logo.pdf",
             "openai_logo.pdf", "grok_logo.png", "antigravity_logo.png", "deepseek_logo.ico"]
for name in names {
    let url = resources.appendingPathComponent(name)
    guard let image = NSImage(contentsOf: url), image.isValid,
          image.size.width > 0, image.size.height > 0,
          image.tiffRepresentation != nil else {
        fputs("Invalid or missing icon: \(name)\n", stderr)
        exit(1)
    }
}
let plistURL = root.appendingPathComponent("Contents/Info.plist")
let data = try Data(contentsOf: plistURL)
let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
guard plist?["CFBundleIconFile"] as? String == "CodexIsland" else {
    fputs("Invalid application icon declaration\n", stderr)
    exit(1)
}
print("PASS: application icon and all five provider icons decode correctly")
