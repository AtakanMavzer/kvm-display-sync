import Foundation
import CoreGraphics

struct DisplayInfo {
    let id: CGDirectDisplayID
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32
    let isBuiltin: Bool
    let isMain: Bool
    let isActive: Bool
    let isOnline: Bool
    let mirrorOf: CGDirectDisplayID
    let bounds: CGRect

    var summary: String {
        var flags: [String] = []
        if isBuiltin { flags.append("builtin") }
        if isMain { flags.append("main") }
        flags.append(isActive ? "active" : "inactive")
        if mirrorOf != kCGNullDirectDisplay { flags.append("mirror-of:\(mirrorOf)") }
        return String(
            format: "id=%u vendor=%u (0x%04X) model=%u (0x%04X) serial=%u %@ bounds=%.0fx%.0f@%.0f,%.0f",
            id, vendor, vendor, model, model, serial, flags.joined(separator: ","),
            bounds.width, bounds.height, bounds.origin.x, bounds.origin.y)
    }
}

enum Displays {
    /// Every display macOS knows about right now, including inactive (disabled / mirrored) ones.
    static func online() -> [DisplayInfo] {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        guard CGGetOnlineDisplayList(32, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map(info(for:))
    }

    static func info(for id: CGDirectDisplayID) -> DisplayInfo {
        DisplayInfo(
            id: id,
            vendor: CGDisplayVendorNumber(id),
            model: CGDisplayModelNumber(id),
            serial: CGDisplaySerialNumber(id),
            isBuiltin: CGDisplayIsBuiltin(id) != 0,
            isMain: CGDisplayIsMain(id) != 0,
            isActive: CGDisplayIsActive(id) != 0,
            isOnline: CGDisplayIsOnline(id) != 0,
            mirrorOf: CGDisplayMirrorsDisplay(id),
            bounds: CGDisplayBounds(id))
    }

    static func builtin() -> DisplayInfo? {
        online().first(where: { $0.isBuiltin })
    }

    /// Finds the managed external display. With vendor/model given, matches exactly;
    /// otherwise falls back to the first non-builtin display.
    static func external(vendor: UInt32?, model: UInt32?) -> DisplayInfo? {
        let all = online()
        if let vendor, let model {
            return all.first(where: { $0.vendor == vendor && $0.model == model })
        }
        return all.first(where: { !$0.isBuiltin })
    }
}

extension CGError {
    var label: String {
        switch self {
        case .success: return "success"
        case .failure: return "failure"
        case .illegalArgument: return "illegalArgument"
        case .invalidConnection: return "invalidConnection"
        case .invalidContext: return "invalidContext"
        case .cannotComplete: return "cannotComplete"
        case .notImplemented: return "notImplemented"
        case .rangeCheck: return "rangeCheck"
        case .typeCheck: return "typeCheck"
        case .invalidOperation: return "invalidOperation"
        case .noneAvailable: return "noneAvailable"
        @unknown default: return "CGError(\(rawValue))"
        }
    }
}
