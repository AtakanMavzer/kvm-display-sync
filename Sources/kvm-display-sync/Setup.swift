import Foundation
import CoreGraphics

/// Interactive first-run wizard: picks the external display, discovers which USB device follows
/// the KVM by diffing the registry across one switch, then installs the launch agent.
enum Setup {
    static func run(base: Options) throws {
        var opts = base
        print("""

        kvm-display-sync setup
        ======================
        This takes about a minute. Keep this window on your Mac's built-in screen
        and use the built-in keyboard: your USB keyboard will follow the KVM.

        """)

        // Step 1: display
        print("Step 1/3  Which display does the KVM control?")
        let externals = Displays.online().filter { !$0.isBuiltin }
        let display: DisplayInfo
        switch externals.count {
        case 0:
            throw UsageError.message("no external display is online. Make sure the monitor is showing this Mac, then run setup again.")
        case 1:
            display = externals[0]
            print("  Found one external display, using it:")
            print("    \(describe(display))")
        default:
            for (i, d) in externals.enumerated() { print("  [\(i + 1)] \(describe(d))") }
            let n = try Prompt.number("  Pick the KVM monitor", range: 1...externals.count)
            display = externals[n - 1]
        }
        opts.displayVendor = display.vendor
        opts.displayModel = display.model
        opts.displayName = Displays.name(for: display.id) ?? opts.displayName
        print()

        // Step 2: USB device
        print("Step 2/3  Which USB device follows the KVM?")
        print("  Make sure the monitor is currently showing THIS Mac.")
        try Prompt.enter("  Press Enter when it is")
        let before = USBWatcher.listAll()
        print("  Now switch the monitor to the OTHER computer using its KVM / input button.")
        try Prompt.enter("  Press Enter (on the built-in keyboard) once it has switched")
        let after = USBWatcher.listAll()

        let gone = before.filter { b in !after.contains(where: { $0.vendor == b.vendor && $0.product == b.product }) }
        let ranked = rank(gone)
        let chosen: (vendor: Int, product: Int, name: String)
        if ranked.isEmpty {
            print("  No USB device disappeared. Either the KVM did not switch USB, or the monitor's")
            print("  KVM setting routes USB to the other upstream port for this input.")
            print("  Check the monitor's OSD KVM assignment and run setup again.")
            throw UsageError.message("setup aborted: no USB change detected")
        } else if ranked.count == 1 || looksLikeMonitorDevice(ranked[0].name) {
            chosen = ranked[0]
            print("  Devices that disappeared:")
            for d in ranked { print("    \(fmt(d))") }
            print("  Using: \(chosen.name)")
        } else {
            print("  Several devices disappeared. Pick the one that belongs to the monitor itself")
            print("  (a hub, an OSD/lighting/'display' device), not a keyboard or mouse:")
            for (i, d) in ranked.enumerated() { print("  [\(i + 1)] \(fmt(d))") }
            let n = try Prompt.number("  Pick", range: 1...ranked.count)
            chosen = ranked[n - 1]
        }
        opts.usbVendor = chosen.vendor
        opts.usbProduct = chosen.product

        print("  Switch the monitor back to this Mac.")
        try Prompt.enter("  Press Enter once it has switched back")
        Thread.sleep(forTimeInterval: 1.5)
        if USBWatcher.isPresent(vendor: chosen.vendor, product: chosen.product) {
            print("  Confirmed: \(chosen.name) is back.")
        } else {
            print("  Warning: \(chosen.name) has not reappeared yet. Continuing anyway; check `status` afterwards.")
        }
        print()

        // Step 3: actuator + install
        print("Step 3/3  Install")
        if Displays.builtin() == nil, opts.actuator == "mirror" {
            print("  This Mac has no built-in display, so the mirror actuator cannot work.")
            print("  Installing with --actuator disable. If your monitor shows 'No Signal' after")
            print("  switching back, use --actuator command with a tool of your choice instead.")
            opts.actuator = "disable"
        }
        print("  Display : vendor \(opts.displayVendor!) model \(opts.displayModel!) (\(opts.displayName))")
        print("  USB     : \(fmt(chosen))")
        print("  Actuator: \(opts.actuator)")
        _ = try makeActuator(opts)
        try LaunchAgent.install(watchArguments: opts.watchArguments)
        print()
        print("Done. The daemon is running and will start at login.")
        print("  status : \(LaunchAgent.installedBinaryPath) status")
        print("  log    : \(LaunchAgent.logPath)")
        print("  remove : \(LaunchAgent.installedBinaryPath) uninstall")
        print("If macOS shows a 'background item added' notice, leave it allowed.")
    }

    // MARK: - Helpers

    private static func describe(_ d: DisplayInfo) -> String {
        let name = Displays.name(for: d.id) ?? "display \(d.id)"
        return String(format: "%@  vendor %u  model %u  %.0fx%.0f%@", name, d.vendor, d.model,
                      d.bounds.width, d.bounds.height, d.isMain ? "  (main)" : "")
    }

    private static func fmt(_ d: (vendor: Int, product: Int, name: String)) -> String {
        String(format: "0x%04X:0x%04X  %@", d.vendor, d.product, d.name)
    }

    private static let peripheralWords = ["keyboard", "mouse", "controller", "gamepad", "receiver", "dongle",
                                          "headset", "webcam", "camera", "audio", "microphone", "trackpad"]
    private static let monitorWords = ["display", "monitor", "aura", "osd", "lighting", "rgb"]

    static func looksLikeMonitorDevice(_ name: String) -> Bool {
        let n = name.lowercased()
        return monitorWords.contains(where: { n.contains($0) })
    }

    static func looksLikePeripheral(_ name: String) -> Bool {
        let n = name.lowercased()
        return peripheralWords.contains(where: { n.contains($0) })
    }

    /// Monitor-ish devices first, then hubs, then everything else, with obvious peripherals last.
    static func rank(_ devices: [(vendor: Int, product: Int, name: String)]) -> [(vendor: Int, product: Int, name: String)] {
        func score(_ d: (vendor: Int, product: Int, name: String)) -> Int {
            if looksLikeMonitorDevice(d.name) { return 0 }
            if looksLikePeripheral(d.name) { return 3 }
            if d.name.lowercased().contains("hub") { return 1 }
            return 2
        }
        return devices.sorted { score($0) < score($1) }
    }
}

enum Prompt {
    /// Reads from the controlling terminal even when stdin is a pipe (curl | sh), falling back to stdin.
    private static let input: UnsafeMutablePointer<FILE> = {
        if isatty(STDIN_FILENO) != 0 { return stdin }
        if let tty = fopen("/dev/tty", "r") { return tty }
        return stdin
    }()

    static func line(_ prompt: String) throws -> String {
        print(prompt, terminator: ": ")
        fflush(stdout)
        var buffer = [CChar](repeating: 0, count: 256)
        guard fgets(&buffer, Int32(buffer.count), input) != nil else {
            throw UsageError.message("input closed")
        }
        return String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func enter(_ prompt: String) throws {
        _ = try line(prompt)
    }

    static func number(_ prompt: String, range: ClosedRange<Int>) throws -> Int {
        while true {
            let s = try line("\(prompt) [\(range.lowerBound)-\(range.upperBound)]")
            if let n = Int(s), range.contains(n) { return n }
            print("  Enter a number between \(range.lowerBound) and \(range.upperBound).")
        }
    }
}
