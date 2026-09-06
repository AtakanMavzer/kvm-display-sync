import Foundation
import CoreGraphics

/// Something that can take the external display out of, and back into, the macOS display layout.
protocol Actuator {
    var name: String { get }
    /// KVM is on the Mac: make the display usable again.
    func connect() throws
    /// KVM is away: make macOS stop treating the display as usable desktop space.
    func disconnect() throws
}

enum ActuatorError: Error, CustomStringConvertible {
    case externalDisplayNotFound
    case builtinDisplayNotFound
    case cg(String, CGError)
    case privateSymbolMissing(String)
    case commandFailed(String, Int32, String)
    case notConfigured(String)

    var description: String {
        switch self {
        case .externalDisplayNotFound: return "external display not found in the online display list"
        case .builtinDisplayNotFound: return "built-in display not found"
        case let .cg(what, err): return "\(what) failed: \(err.label)"
        case let .privateSymbolMissing(sym): return "private symbol \(sym) not available on this macOS"
        case let .commandFailed(cmd, code, out): return "command exited \(code): \(cmd)\n\(out)"
        case let .notConfigured(what): return what
        }
    }
}

struct DisplaySelector {
    let vendor: UInt32?
    let model: UInt32?

    func external() throws -> DisplayInfo {
        guard let d = Displays.external(vendor: vendor, model: model) else {
            throw ActuatorError.externalDisplayNotFound
        }
        return d
    }
}

// MARK: - Disable (private CoreGraphics API)

/// Uses the private `CGSConfigureDisplayEnabled` to remove the display from the layout entirely.
/// This is what the old DisableMonitor utility used. It is undocumented; `test off`/`test on`
/// verifies it on the current macOS before trusting it in the daemon.
final class DisableActuator: Actuator {
    let name = "disable"
    private typealias ConfigureEnabledFn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
    private let configureEnabled: ConfigureEnabledFn
    private let selector: DisplaySelector

    init(selector: DisplaySelector) throws {
        self.selector = selector
        let symbol = "CGSConfigureDisplayEnabled"
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let ptr = dlsym(handle, symbol) else {
            throw ActuatorError.privateSymbolMissing(symbol)
        }
        configureEnabled = unsafeBitCast(ptr, to: ConfigureEnabledFn.self)
    }

    func disconnect() throws {
        guard let ext = Displays.external(vendor: selector.vendor, model: selector.model) else {
            if State.disabled != nil {
                Log.info("display not in online list and a disabled record exists; treating as already disabled")
                return
            }
            throw ActuatorError.externalDisplayNotFound
        }
        if !ext.isActive {
            Log.info("display \(ext.id) already inactive; nothing to do")
            return
        }
        let builtin = Displays.builtin()
        let record = DisabledDisplay(
            id: ext.id, wasMain: ext.isMain,
            originX: Int32(ext.bounds.origin.x), originY: Int32(ext.bounds.origin.y),
            builtinOriginX: Int32(builtin?.bounds.origin.x ?? 0), builtinOriginY: Int32(builtin?.bounds.origin.y ?? 0))

        try transaction("disable display \(ext.id)") { config in
            // If the external is main, hand main over to the built-in first so the menu bar has a home.
            if ext.isMain, let builtin {
                let err = CGConfigureDisplayOrigin(config, builtin.id, 0, 0)
                guard err == .success else { throw ActuatorError.cg("CGConfigureDisplayOrigin(builtin)", err) }
            }
            let err = configureEnabled(config, ext.id, false)
            guard err == .success else { throw ActuatorError.cg("CGSConfigureDisplayEnabled(false)", err) }
        }
        // A disabled display drops out of CGGetOnlineDisplayList, so remember it for connect().
        State.disabled = record
    }

    func connect() throws {
        if let ext = Displays.external(vendor: selector.vendor, model: selector.model), ext.isActive {
            Log.info("display \(ext.id) already active; nothing to do")
            State.disabled = nil
            return
        }
        let record = State.disabled
        let id: CGDirectDisplayID
        if let ext = Displays.external(vendor: selector.vendor, model: selector.model) {
            id = ext.id
        } else if let record {
            id = record.id
            Log.debug("display not in online list; using remembered ID \(id)")
        } else {
            throw ActuatorError.externalDisplayNotFound
        }
        try transaction("enable display \(id)") { config in
            let err = configureEnabled(config, id, true)
            guard err == .success else { throw ActuatorError.cg("CGSConfigureDisplayEnabled(true)", err) }
        }
        // Verify it actually came back; the private call can report success without effect.
        Thread.sleep(forTimeInterval: 0.5)
        guard let ext = Displays.external(vendor: selector.vendor, model: selector.model), ext.isActive else {
            throw ActuatorError.cg("display \(id) still not active after enable", .failure)
        }
        if let record {
            restoreArrangement(ext: ext, record: record)
        }
        State.disabled = nil
    }

    /// Puts the external and built-in displays back where they were, including main status.
    /// Best effort: a failure here leaves the display usable, just arranged by macOS's defaults.
    private func restoreArrangement(ext: DisplayInfo, record: DisabledDisplay) {
        guard let builtin = Displays.builtin() else { return }
        let alreadyRight = ext.isMain == record.wasMain
            && Int32(ext.bounds.origin.x) == record.originX && Int32(ext.bounds.origin.y) == record.originY
        if alreadyRight { return }
        do {
            try transaction("restore arrangement (external main=\(record.wasMain))") { config in
                // Whichever display sits at 0,0 becomes main.
                var err = CGConfigureDisplayOrigin(config, ext.id, record.originX, record.originY)
                guard err == .success else { throw ActuatorError.cg("CGConfigureDisplayOrigin(external)", err) }
                err = CGConfigureDisplayOrigin(config, builtin.id, record.builtinOriginX, record.builtinOriginY)
                guard err == .success else { throw ActuatorError.cg("CGConfigureDisplayOrigin(builtin)", err) }
            }
        } catch {
            Log.error("arrangement restore failed (display is still usable): \(error)")
        }
    }

    private func transaction(_ label: String, _ body: (CGDisplayConfigRef) throws -> Void) throws {
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success, let config else { throw ActuatorError.cg("CGBeginDisplayConfiguration", begin) }
        do {
            try body(config)
        } catch {
            CGCancelDisplayConfiguration(config)
            throw error
        }
        let complete = CGCompleteDisplayConfiguration(config, .forSession)
        guard complete == .success else { throw ActuatorError.cg("CGCompleteDisplayConfiguration(\(label))", complete) }
        Log.info("\(label): ok")
    }
}

// MARK: - Mirror (public API)

/// Public-API fallback: mirror the external onto the built-in display so there is only one logical
/// screen. The monitor still receives a signal, but windows and the cursor can no longer get lost on it.
final class MirrorActuator: Actuator {
    let name = "mirror"
    private let selector: DisplaySelector

    init(selector: DisplaySelector) {
        self.selector = selector
    }

    func disconnect() throws {
        let ext = try selector.external()
        guard let builtin = Displays.builtin() else { throw ActuatorError.builtinDisplayNotFound }
        if ext.mirrorOf == builtin.id {
            Log.info("display \(ext.id) already mirroring built-in; nothing to do")
            return
        }
        try configure("mirror \(ext.id) onto \(builtin.id)") { config in
            CGConfigureDisplayMirrorOfDisplay(config, ext.id, builtin.id)
        }
    }

    func connect() throws {
        let ext = try selector.external()
        if ext.mirrorOf == kCGNullDirectDisplay {
            Log.info("display \(ext.id) not mirrored; nothing to do")
            return
        }
        try configure("unmirror \(ext.id)") { config in
            CGConfigureDisplayMirrorOfDisplay(config, ext.id, kCGNullDirectDisplay)
        }
    }

    private func configure(_ label: String, _ body: (CGDisplayConfigRef) -> CGError) throws {
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success, let config else { throw ActuatorError.cg("CGBeginDisplayConfiguration", begin) }
        let err = body(config)
        guard err == .success else {
            CGCancelDisplayConfiguration(config)
            throw ActuatorError.cg(label, err)
        }
        let complete = CGCompleteDisplayConfiguration(config, .forSession)
        guard complete == .success else { throw ActuatorError.cg("CGCompleteDisplayConfiguration(\(label))", complete) }
        Log.info("\(label): ok")
    }
}

// MARK: - Shell command

/// Runs user-supplied shell commands. Lets the daemon drive anything, including BetterDisplay's CLI.
final class CommandActuator: Actuator {
    let name = "command"
    private let onConnect: String?
    private let onDisconnect: String?

    init(onConnect: String?, onDisconnect: String?) {
        self.onConnect = onConnect
        self.onDisconnect = onDisconnect
    }

    func connect() throws {
        guard let cmd = onConnect else { throw ActuatorError.notConfigured("--on-connect not set") }
        try Shell.run(cmd)
    }

    func disconnect() throws {
        guard let cmd = onDisconnect else { throw ActuatorError.notConfigured("--on-disconnect not set") }
        try Shell.run(cmd)
    }
}

// MARK: - BetterDisplay CLI

/// Drives BetterDisplay's built-in CLI. Requires BetterDisplay Pro with
/// "Enable connect/disconnect option for displays" turned on.
final class BetterDisplayActuator: Actuator {
    let name = "betterdisplay"
    private let displayName: String
    private let binary = "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"

    init(displayName: String) {
        self.displayName = displayName
    }

    func connect() throws { try set("on") }
    func disconnect() throws { try set("off") }

    private func set(_ value: String) throws {
        let cmd = "\"\(binary)\" set --name=\(displayName) --connected=\(value)"
        let out = try Shell.capture(cmd, timeout: 10)
        if out.contains("Failed") {
            throw ActuatorError.commandFailed(cmd, 0, out.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        Log.info("betterdisplay connected=\(value): \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
}

// MARK: - Shell helper

enum Shell {
    static func run(_ command: String) throws {
        let out = try capture(command, timeout: 30)
        Log.debug("command output: \(out)")
    }

    static func capture(_ command: String, timeout: TimeInterval) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", command]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()

        // Drain the pipe off-thread so a chatty command can't fill the buffer and stall.
        var data = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning {
            proc.terminate()
            _ = group.wait(timeout: .now() + 1)
            throw ActuatorError.commandFailed(command, -1, "timed out after \(Int(timeout))s")
        }
        group.wait()
        let out = String(data: data, encoding: .utf8) ?? ""
        guard proc.terminationStatus == 0 else {
            throw ActuatorError.commandFailed(command, proc.terminationStatus, out)
        }
        return out
    }
}
