import Foundation
import IOKit
import IOKit.pwr_mgt

/// Debounced reconciler: USB event / wake / periodic tick -> re-check what the KVM wants and what the
/// display is doing -> act only when they differ. Never trusts its own memory when the system can be asked.
final class Daemon {
    private let watcher: USBWatcher
    private let actuator: Actuator
    private let debounce: TimeInterval
    private let connectDebounce: TimeInterval
    private let initialSync: Bool
    private let reconcileInterval: TimeInterval

    private let retryDelay: TimeInterval = 3
    private let maxRetryDelay: TimeInterval = 60
    private let wakeSettleDelay: TimeInterval = 5

    /// Fallback memory for actuators that can't report their state (command, betterdisplay).
    private var applied: Bool?
    private var pendingTimer: Timer?
    private var reconcileTimer: Timer?
    private var consecutiveFailures = 0
    private var asleep = false

    init(vendor: Int, product: Int, actuator: Actuator, debounce: TimeInterval,
         connectDebounce: TimeInterval, reconcileInterval: TimeInterval, initialSync: Bool) {
        self.actuator = actuator
        self.debounce = debounce
        self.connectDebounce = connectDebounce
        self.reconcileInterval = reconcileInterval
        self.initialSync = initialSync
        var handlerRef: (() -> Void)?
        self.watcher = USBWatcher(vendor: vendor, product: product) { handlerRef?() }
        handlerRef = { [weak self] in
            guard let self else { return }
            // Device present at event time means we're heading towards connect: act fast so the
            // mirrored image is on screen as briefly as possible. Disconnect keeps the full debounce.
            let towardsConnect = self.watcher.isPresent
            self.scheduleEvaluate(reason: towardsConnect ? "usb attach" : "usb detach",
                                  after: towardsConnect ? self.connectDebounce : nil)
        }
    }

    func run() throws {
        Log.info(String(format: "watching USB vendor=0x%04X product=0x%04X, actuator=%@, debounce=%.1fs (connect %.1fs), reconcile every %.0fs",
                        watcher.vendor, watcher.product, actuator.name, debounce, connectDebounce, reconcileInterval))
        try watcher.start()
        installSignalHandlers()
        installSleepWakeHandlers()

        if initialSync {
            // Let the run loop settle first; on login the USB tree can still be enumerating.
            scheduleEvaluate(reason: "startup")
        } else {
            applied = watcher.isPresent
            Log.info("initial sync disabled; assuming current state is kvm-on-mac=\(applied!)")
        }
        if reconcileInterval > 0 {
            reconcileTimer = Timer.scheduledTimer(withTimeInterval: reconcileInterval, repeats: true) { [weak self] _ in
                self?.evaluate(reason: "periodic")
            }
        }
        RunLoop.main.run()
    }

    // MARK: - Evaluation

    private func scheduleEvaluate(reason: String, after delay: TimeInterval? = nil) {
        pendingTimer?.invalidate()
        let wait = delay ?? debounce
        Log.debug("\(reason): evaluating in \(wait)s")
        pendingTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            self?.evaluate(reason: reason)
        }
    }

    private func evaluate(reason: String) {
        if asleep {
            Log.debug("\(reason): system is asleep, skipping")
            return
        }
        let desired = watcher.isPresent
        let actual = actuator.isConnected() ?? applied
        if let actual, actual == desired {
            if reason != "periodic" { Log.debug("in sync (kvm-on-mac=\(desired))") }
            consecutiveFailures = 0
            return
        }
        Log.info("KVM \(desired ? "on Mac" : "away"), display \(actual.map { $0 ? "connected" : "disconnected" } ?? "unknown") -> \(desired ? "connect" : "disconnect") [\(reason)]")
        do {
            if desired {
                try actuator.connect()
            } else {
                try actuator.disconnect()
            }
            applied = desired
            consecutiveFailures = 0
        } catch {
            consecutiveFailures += 1
            let delay = min(retryDelay * pow(2, Double(consecutiveFailures - 1)), maxRetryDelay)
            Log.error("\(desired ? "connect" : "disconnect") failed (attempt \(consecutiveFailures)): \(error); retrying in \(Int(delay))s")
            scheduleEvaluate(reason: "retry", after: delay)
        }
    }

    // MARK: - Sleep / wake

    private var powerNotifier: io_object_t = 0
    private var powerPort: IONotificationPortRef?
    private var powerConnection: io_connect_t = 0

    private func installSleepWakeHandlers() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceInterestCallback = { refcon, _, messageType, messageArgument in
            guard let refcon else { return }
            let daemon = Unmanaged<Daemon>.fromOpaque(refcon).takeUnretainedValue()
            daemon.handlePowerMessage(messageType, messageArgument)
        }
        powerConnection = IORegisterForSystemPower(refcon, &powerPort, callback, &powerNotifier)
        guard powerConnection != 0, let powerPort else {
            Log.error("IORegisterForSystemPower failed; sleep/wake handling disabled")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(powerPort).takeUnretainedValue(), .defaultMode)
    }

    // IOMessage.h defines these via macros Swift doesn't import.
    private static let msgCanSystemSleep: UInt32 = 0xE000_0270
    private static let msgSystemWillSleep: UInt32 = 0xE000_0280
    private static let msgSystemHasPoweredOn: UInt32 = 0xE000_0300

    private func handlePowerMessage(_ type: UInt32, _ argument: UnsafeMutableRawPointer?) {
        switch type {
        case Daemon.msgSystemWillSleep, Daemon.msgCanSystemSleep:
            if !asleep {
                Log.info("system going to sleep; pausing")
                asleep = true
                pendingTimer?.invalidate()
            }
            // We must acknowledge or the system waits up to 30s for us.
            IOAllowPowerChange(powerConnection, Int(bitPattern: argument))
        case Daemon.msgSystemHasPoweredOn:
            Log.info("system woke; re-checking in \(Int(wakeSettleDelay))s")
            asleep = false
            consecutiveFailures = 0
            scheduleEvaluate(reason: "wake", after: wakeSettleDelay)
        default:
            break
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
        if (actuator.isConnected() ?? applied) == false {
            // Don't leave the display stranded in a disconnected state when we go away.
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
