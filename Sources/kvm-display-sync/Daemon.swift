import Foundation

/// Debounced state machine: USB event -> wait -> re-check presence -> act only on real transitions.
final class Daemon {
    private let watcher: USBWatcher
    private let actuator: Actuator
    private let debounce: TimeInterval
    private let initialSync: Bool
    private let maxRetries = 5
    private let retryDelay: TimeInterval = 3

    /// The last "KVM on Mac" state we successfully applied. nil until the first successful action.
    private var applied: Bool?
    private var pendingTimer: Timer?
    private var retriesLeft = 0

    init(vendor: Int, product: Int, actuator: Actuator, debounce: TimeInterval, initialSync: Bool) {
        self.actuator = actuator
        self.debounce = debounce
        self.initialSync = initialSync
        var handlerRef: (() -> Void)?
        self.watcher = USBWatcher(vendor: vendor, product: product) { handlerRef?() }
        handlerRef = { [weak self] in self?.scheduleEvaluate(reason: "usb event") }
    }

    func run() throws {
        Log.info(String(format: "watching USB vendor=0x%04X product=0x%04X, actuator=%@, debounce=%.1fs",
                        watcher.vendor, watcher.product, actuator.name, debounce))
        try watcher.start()
        installSignalHandlers()

        if initialSync {
            // Let the run loop settle first; on login the USB tree can still be enumerating.
            scheduleEvaluate(reason: "startup")
        } else {
            applied = watcher.isPresent
            Log.info("initial sync disabled; assuming current state is kvm-on-mac=\(applied!)")
        }
        RunLoop.main.run()
    }

    private func scheduleEvaluate(reason: String, after delay: TimeInterval? = nil) {
        pendingTimer?.invalidate()
        let wait = delay ?? debounce
        Log.debug("\(reason): evaluating in \(wait)s")
        pendingTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            self?.evaluate()
        }
    }

    private func evaluate() {
        let present = watcher.isPresent
        if let applied, applied == present {
            Log.debug("state unchanged (kvm-on-mac=\(present))")
            retriesLeft = 0
            return
        }
        Log.info("KVM \(present ? "switched to Mac" : "switched away") -> \(present ? "connect" : "disconnect")")
        do {
            if present {
                try actuator.connect()
            } else {
                try actuator.disconnect()
            }
            applied = present
            retriesLeft = 0
        } catch {
            Log.error("\(present ? "connect" : "disconnect") failed: \(error)")
            if retriesLeft == 0 {
                retriesLeft = maxRetries
            }
            retriesLeft -= 1
            if retriesLeft > 0 {
                scheduleEvaluate(reason: "retry (\(retriesLeft) left)", after: retryDelay)
            } else {
                Log.error("giving up until the next USB event")
                // Record the state so we don't loop; the next real transition re-arms us.
                applied = present
            }
        }
    }

    // MARK: - Shutdown

    private var signalSources: [DispatchSourceSignal] = []

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in self?.shutdown() }
            src.resume()
            signalSources.append(src)
        }
    }

    private func shutdown() {
        Log.info("shutting down")
        if applied == false {
            // Don't leave the display stranded in a disabled state when we go away.
            do {
                try actuator.connect()
                Log.info("restored display on exit")
            } catch {
                Log.error("could not restore display on exit: \(error)")
            }
        }
        exit(0)
    }
}
