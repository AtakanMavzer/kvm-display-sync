import Foundation
import IOKit
import IOKit.usb

/// Watches IOKit for a specific USB device (by vendor/product ID) appearing or disappearing.
/// The handler is called with no argument; callers should re-query `isPresent` after a debounce,
/// because the registry is still settling when the notification fires.
final class USBWatcher {
    typealias Handler = () -> Void

    let vendor: Int
    let product: Int

    private let handler: Handler
    private var port: IONotificationPortRef?
    private var matchedIterator: io_iterator_t = 0
    private var terminatedIterator: io_iterator_t = 0

    init(vendor: Int, product: Int, handler: @escaping Handler) {
        self.vendor = vendor
        self.product = product
        self.handler = handler
    }

    deinit {
        if matchedIterator != 0 { IOObjectRelease(matchedIterator) }
        if terminatedIterator != 0 { IOObjectRelease(terminatedIterator) }
        if let port { IONotificationPortDestroy(port) }
    }

    // MARK: - Matching

    static func matchingDictionary(vendor: Int, product: Int) -> NSMutableDictionary {
        let dict = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
        dict[kUSBVendorID] = NSNumber(value: vendor)
        dict[kUSBProductID] = NSNumber(value: product)
        return dict
    }

    /// Number of matching devices currently in the IORegistry.
    static func count(vendor: Int, product: Int) -> Int {
        var iterator: io_iterator_t = 0
        let dict = matchingDictionary(vendor: vendor, product: product)
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, dict, &iterator)
        guard kr == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iterator) }
        var n = 0
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            n += 1
            IOObjectRelease(service)
        }
        return n
    }

    static func isPresent(vendor: Int, product: Int) -> Bool {
        count(vendor: vendor, product: product) > 0
    }

    var isPresent: Bool {
        USBWatcher.isPresent(vendor: vendor, product: product)
    }

    /// Lists every USB device in the registry as (vendor, product, name).
    static func listAll() -> [(vendor: Int, product: Int, name: String)] {
        var iterator: io_iterator_t = 0
        let dict = IOServiceMatching("IOUSBHostDevice")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, dict, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var out: [(Int, Int, String)] = []
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            let v = (IORegistryEntryCreateCFProperty(service, kUSBVendorID as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber)?.intValue ?? 0
            let p = (IORegistryEntryCreateCFProperty(service, kUSBProductID as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber)?.intValue ?? 0
            let name = (IORegistryEntryCreateCFProperty(service, kUSBProductString as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String) ?? "?"
            out.append((v, p, name))
        }
        return out
    }

    // MARK: - Notifications

    func start() throws {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            throw WatcherError.portCreationFailed
        }
        self.port = port
        let source = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let watcher = Unmanaged<USBWatcher>.fromOpaque(refcon).takeUnretainedValue()
            let n = watcher.drain(iterator)
            Log.debug("IOKit notification fired (\(n) service(s) in iterator)")
            watcher.handler()
        }

        var kr = IOServiceAddMatchingNotification(
            port, kIOMatchedNotification,
            USBWatcher.matchingDictionary(vendor: vendor, product: product),
            callback, refcon, &matchedIterator)
        guard kr == KERN_SUCCESS else { throw WatcherError.registrationFailed("matched", kr) }
        _ = drain(matchedIterator) // arms the notification

        kr = IOServiceAddMatchingNotification(
            port, kIOTerminatedNotification,
            USBWatcher.matchingDictionary(vendor: vendor, product: product),
            callback, refcon, &terminatedIterator)
        guard kr == KERN_SUCCESS else { throw WatcherError.registrationFailed("terminated", kr) }
        _ = drain(terminatedIterator)
    }

    @discardableResult
    private func drain(_ iterator: io_iterator_t) -> Int {
        var n = 0
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            n += 1
            IOObjectRelease(service)
        }
        return n
    }
}

enum WatcherError: Error, CustomStringConvertible {
    case portCreationFailed
    case registrationFailed(String, kern_return_t)

    var description: String {
        switch self {
        case .portCreationFailed:
            return "IONotificationPortCreate failed"
        case let .registrationFailed(kind, kr):
            return "IOServiceAddMatchingNotification(\(kind)) failed: kern_return \(kr)"
        }
    }
}
