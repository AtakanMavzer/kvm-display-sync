import Foundation

enum LaunchAgent {
    static let label = "io.github.kvm-display-sync"

    static var plistPath: String {
        NSString(string: "~/Library/LaunchAgents/\(label).plist").expandingTildeInPath
    }

    static var installedBinaryPath: String {
        NSString(string: "~/.local/bin/kvm-display-sync").expandingTildeInPath
    }

    static var logPath: String {
        NSString(string: "~/Library/Logs/kvm-display-sync.log").expandingTildeInPath
    }

    /// Copies the running binary to ~/.local/bin, writes the plist with the given watch arguments,
    /// and bootstraps it into the user's launchd domain.
    static func install(watchArguments: [String]) throws {
        let fm = FileManager.default
        let source = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        let sourceResolved = (source as NSString).isAbsolutePath
            ? source
            : fm.currentDirectoryPath + "/" + source

        try fm.createDirectory(atPath: (installedBinaryPath as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true)
        try fm.createDirectory(atPath: (plistPath as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true)

        if fm.fileExists(atPath: installedBinaryPath) {
            try fm.removeItem(atPath: installedBinaryPath)
        }
        try fm.copyItem(atPath: sourceResolved, toPath: installedBinaryPath)
        Log.info("installed binary to \(installedBinaryPath)")

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [installedBinaryPath, "watch"] + watchArguments,
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive",
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: plistPath))
        Log.info("wrote \(plistPath)")

        try unload()
        // bootout returns before the old process has finished its shutdown (it restores the
        // display first). Bootstrapping too early fails, so retry briefly.
        var lastError: Error?
        for attempt in 1...5 {
            do {
                try Shell.run("launchctl bootstrap gui/\(getuid()) \"\(plistPath)\"")
                lastError = nil
                break
            } catch {
                lastError = error
                Log.debug("bootstrap attempt \(attempt) failed: \(error)")
                Thread.sleep(forTimeInterval: 1)
            }
        }
        if let lastError { throw lastError }
        Log.info("loaded launch agent \(label); log at \(logPath)")
    }

    /// Unloads the agent if present and waits for its process to go away.
    private static func unload() throws {
        _ = try? Shell.capture("launchctl bootout gui/\(getuid())/\(label)", timeout: 10)
        for _ in 0..<50 {
            let out = (try? Shell.capture("launchctl print gui/\(getuid())/\(label) 2>/dev/null | grep -c 'state = running' || true", timeout: 5)) ?? "0"
            if out.trimmingCharacters(in: .whitespacesAndNewlines) == "0" { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    static func uninstall() throws {
        try unload()
        let fm = FileManager.default
        if fm.fileExists(atPath: plistPath) {
            try fm.removeItem(atPath: plistPath)
            Log.info("removed \(plistPath)")
        }
        if fm.fileExists(atPath: installedBinaryPath) {
            try fm.removeItem(atPath: installedBinaryPath)
            Log.info("removed \(installedBinaryPath)")
        }
        Log.info("unloaded launch agent \(label)")
    }
}
