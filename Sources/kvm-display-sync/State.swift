import Foundation
import CoreGraphics

/// What we knew about the display right before disabling it, so connect() can put it back.
/// Disabled displays vanish from the online display list, so this has to live on disk.
struct DisabledDisplay: Codable {
    var id: CGDirectDisplayID
    var wasMain: Bool
    var originX: Int32
    var originY: Int32
    /// Where the built-in display sat relative to the external one, so the arrangement survives.
    var builtinOriginX: Int32
    var builtinOriginY: Int32
}

enum State {
    private static var directory: String {
        NSString(string: "~/Library/Application Support/kvm-display-sync").expandingTildeInPath
    }

    private static var path: String { directory + "/disabled-display.json" }

    static var disabled: DisabledDisplay? {
        get {
            guard let data = FileManager.default.contents(atPath: path) else { return nil }
            return try? JSONDecoder().decode(DisabledDisplay.self, from: data)
        }
        set {
            let fm = FileManager.default
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
                fm.createFile(atPath: path, contents: data)
            } else if fm.fileExists(atPath: path) {
                try? fm.removeItem(atPath: path)
            }
        }
    }
}
