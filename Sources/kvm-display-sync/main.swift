import Foundation
import CoreGraphics

// MARK: - Options

struct Options {
    // USB device whose presence means "KVM is routed to this Mac".
    // Default: ASUS "ROG Gaming Display Aura Device" inside the XG27UCDMG.
    var usbVendor = 0x0B05
    var usbProduct = 0x1BFE

    // External display to manage. Default: ASUS XG27UCDMG (EDID vendor 1715, model 10230).
    var displayVendor: UInt32? = 1715
    var displayModel: UInt32? = 10230
    var displayName = "XG27UCDMG"

    var actuator = "mirror"
    var onConnect: String?
    var onDisconnect: String?
    var debounce: TimeInterval = 2.0
    var initialSync = true
    var verbose = false

    /// The subset of arguments that `watch` needs, for the launch agent plist.
    var watchArguments: [String] {
        var args = [
            "--usb-vendor", String(format: "0x%04X", usbVendor),
            "--usb-product", String(format: "0x%04X", usbProduct),
            "--actuator", actuator,
            "--debounce", String(debounce),
            "--display-name", displayName,
        ]
        if let v = displayVendor, let m = displayModel {
            args += ["--display-vendor", String(v), "--display-model", String(m)]
        } else {
            args += ["--any-external"]
        }
        if let c = onConnect { args += ["--on-connect", c] }
        if let d = onDisconnect { args += ["--on-disconnect", d] }
        if !initialSync { args.append("--no-initial-sync") }
        if verbose { args.append("--verbose") }
        return args
    }
}

enum UsageError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        if case let .message(m) = self { return m }
        return ""
    }
}

func parseInt(_ s: String, flag: String) throws -> Int {
    let str = s.lowercased()
    if str.hasPrefix("0x"), let v = Int(str.dropFirst(2), radix: 16) { return v }
    if let v = Int(str) { return v }
    throw UsageError.message("\(flag): expected integer, got '\(s)'")
}

func parse(_ argv: [String]) throws -> (command: String, positional: [String], options: Options) {
    var opts = Options()
    var positional: [String] = []
    var i = 0
    func next(_ flag: String) throws -> String {
        i += 1
        guard i < argv.count else { throw UsageError.message("\(flag) requires a value") }
        return argv[i]
    }
    while i < argv.count {
        let a = argv[i]
        switch a {
        case "--usb-vendor": opts.usbVendor = try parseInt(try next(a), flag: a)
        case "--usb-product": opts.usbProduct = try parseInt(try next(a), flag: a)
        case "--display-vendor": opts.displayVendor = UInt32(try parseInt(try next(a), flag: a))
        case "--display-model": opts.displayModel = UInt32(try parseInt(try next(a), flag: a))
        case "--display-name": opts.displayName = try next(a)
        case "--any-external": opts.displayVendor = nil; opts.displayModel = nil
        case "--actuator": opts.actuator = try next(a)
        case "--on-connect": opts.onConnect = try next(a)
        case "--on-disconnect": opts.onDisconnect = try next(a)
        case "--debounce":
            let s = try next(a)
            guard let d = Double(s), d >= 0 else { throw UsageError.message("--debounce: expected seconds, got '\(s)'") }
            opts.debounce = d
        case "--no-initial-sync": opts.initialSync = false
        case "--verbose", "-v": opts.verbose = true
        case "--help", "-h": positional.insert("help", at: 0)
        default:
            if a.hasPrefix("-") { throw UsageError.message("unknown flag \(a)") }
            positional.append(a)
        }
        i += 1
    }
    let command = positional.first ?? "help"
    return (command, Array(positional.dropFirst()), opts)
}

func makeActuator(_ opts: Options) throws -> Actuator {
    let selector = DisplaySelector(vendor: opts.displayVendor, model: opts.displayModel)
    switch opts.actuator {
    case "disable": return try DisableActuator(selector: selector)
    case "mirror": return MirrorActuator(selector: selector)
    case "command": return CommandActuator(onConnect: opts.onConnect, onDisconnect: opts.onDisconnect)
    case "betterdisplay": return BetterDisplayActuator(displayName: opts.displayName)
    default: throw UsageError.message("unknown actuator '\(opts.actuator)' (disable|mirror|command|betterdisplay)")
    }
}

let usage = """
kvm-display-sync — keep macOS's display layout in sync with a monitor's KVM switch.

Detects the monitor's USB hub (via IOKit) appearing/disappearing and enables or
disables the external display accordingly.

USAGE
  kvm-display-sync <command> [options]

COMMANDS
  watch        Run in the foreground (what the launch agent runs).
  status       Show USB presence, display state, and what watch would do.
  displays     List displays macOS currently knows about.
  usb          List USB devices in the IORegistry (find your vendor/product IDs).
  test off     Run the actuator's disconnect step once.
  test on      Run the actuator's connect step once.
  install      Copy the binary to ~/.local/bin and load a launchd agent with the given options.
  uninstall    Unload and remove the launchd agent.

OPTIONS
  --usb-vendor <id>       USB vendor ID to watch (default 0x0B05, ASUS)
  --usb-product <id>      USB product ID to watch (default 0x1BFE, ROG Gaming Display Aura Device)
  --display-vendor <n>    EDID vendor of the display to manage (default 1715)
  --display-model <n>     EDID model of the display to manage (default 10230)
  --any-external          Manage the first non-builtin display instead of matching vendor/model
  --display-name <name>   Display name for the betterdisplay actuator (default XG27UCDMG)
  --actuator <kind>       mirror | disable | command | betterdisplay (default mirror)
                            disable       private CGSConfigureDisplayEnabled, removes the display
                            mirror        public API, mirrors external onto built-in
                            command       run --on-connect / --on-disconnect shell commands
                            betterdisplay BetterDisplay Pro CLI (needs Pro + connection management)
  --on-connect <cmd>      Shell command for the command actuator (KVM back on Mac)
  --on-disconnect <cmd>   Shell command for the command actuator (KVM away)
  --debounce <seconds>    Wait after a USB event before acting (default 2.0)
  --no-initial-sync       Don't apply the current state at startup
  --verbose, -v           Debug logging
"""

func printStatus(_ opts: Options) {
    let present = USBWatcher.isPresent(vendor: opts.usbVendor, product: opts.usbProduct)
    print(String(format: "USB device 0x%04X:0x%04X present: %@  ->  KVM is %@",
                 opts.usbVendor, opts.usbProduct, present ? "yes" : "no", present ? "on this Mac" : "away"))
    if let ext = Displays.external(vendor: opts.displayVendor, model: opts.displayModel) {
        print("managed display: \(ext.summary)")
        let want = present ? "connected" : "disconnected"
        let isConnected = ext.isActive && ext.mirrorOf == kCGNullDirectDisplay
        print("desired: \(want), currently: \(isConnected ? "connected" : "disconnected")\(isConnected == present ? " (in sync)" : " (OUT OF SYNC)")")
    } else {
        print("managed display: not found in online display list")
    }
    if let b = Displays.builtin() {
        print("built-in display: \(b.summary)")
    }
    print("actuator: \(opts.actuator)")
    let agentLoaded = (try? Shell.capture("launchctl print gui/\(getuid())/\(LaunchAgent.label) >/dev/null 2>&1 && echo yes || echo no", timeout: 5))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
    print("launch agent loaded: \(agentLoaded)")
}

// MARK: - Main

do {
    let (command, positional, opts) = try parse(Array(CommandLine.arguments.dropFirst()))
    Log.verbose = opts.verbose

    switch command {
    case "help":
        print(usage)

    case "watch":
        let actuator = try makeActuator(opts)
        let daemon = Daemon(vendor: opts.usbVendor, product: opts.usbProduct, actuator: actuator,
                            debounce: opts.debounce, initialSync: opts.initialSync)
        try daemon.run()

    case "status":
        printStatus(opts)

    case "displays":
        for d in Displays.online() { print(d.summary) }

    case "usb":
        for d in USBWatcher.listAll().sorted(by: { $0.name < $1.name }) {
            print(String(format: "0x%04X:0x%04X  %@", d.vendor, d.product, d.name))
        }

    case "test":
        guard let which = positional.first, ["on", "off"].contains(which) else {
            throw UsageError.message("usage: kvm-display-sync test on|off")
        }
        let actuator = try makeActuator(opts)
        if which == "off" { try actuator.disconnect() } else { try actuator.connect() }

    case "install":
        _ = try makeActuator(opts) // validate before writing anything
        try LaunchAgent.install(watchArguments: opts.watchArguments)

    case "uninstall":
        try LaunchAgent.uninstall()

    default:
        throw UsageError.message("unknown command '\(command)'\n\n\(usage)")
    }
} catch let e as UsageError {
    FileHandle.standardError.write(Data("error: \(e)\n".utf8))
    exit(2)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
