import AppKit
import Carbon.HIToolbox
import IOKit.ps

/// The prompter key. Backtick (the key under Esc) moves forward, Shift plus backtick goes back.
/// It is registered only while recording, so it never steals the key the rest of the time.
final class PrompterKeys {
    static let shared = PrompterKeys()
    var onNext: (() -> Void)?
    var onBack: (() -> Void)?

    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    func enable() {
        guard refs.isEmpty else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var key = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            // Only this key's own hot keys; the remote's have their own signature.
            guard key.signature == OSType(0x4156_4152) else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async {
                if key.id == 1 { PrompterKeys.shared.onNext?() } else { PrompterKeys.shared.onBack?() }
            }
            return noErr
        }, 1, &spec, nil, &handler)
        register(id: 1, modifiers: 0)
        register(id: 2, modifiers: UInt32(shiftKey))
    }

    func disable() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    private func register(id: UInt32, modifiers: UInt32) {
        var ref: EventHotKeyRef?
        let key = EventHotKeyID(signature: OSType(0x4156_4152), id: id)
        if RegisterEventHotKey(UInt32(kVK_ANSI_Grave), modifiers, key, GetApplicationEventTarget(), 0, &ref) == noErr,
           let ref {
            refs.append(ref)
        }
    }
}

struct PowerState: Equatable {
    var pluggedIn: Bool
    var percent: Int?
    /// Low Power Mode slows the Mac down. On 5 Oct every take made on battery with it on had the
    /// camera freezing for up to 2.3 seconds once the screen was shared; on the charger, none did.
    var lowPower = false
}

enum Preflight {
    static func power() -> PowerState {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return PowerState(pluggedIn: true, percent: nil)
        }
        let source = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        var percent: Int?
        if let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for item in list {
                if let info = IOPSGetPowerSourceDescription(blob, item)?.takeUnretainedValue() as? [String: Any],
                   let current = info[kIOPSCurrentCapacityKey] as? Int,
                   let max = info[kIOPSMaxCapacityKey] as? Int, max > 0 {
                    percent = current * 100 / max
                }
            }
        }
        return PowerState(pluggedIn: source == kIOPMACPowerKey, percent: percent,
                          lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    static func freeGigabytes() -> Double? {
        let url = URL(fileURLWithPath: "/Users/Shared")
        guard let bytes = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage else { return nil }
        return Double(bytes) / 1_000_000_000
    }
}
