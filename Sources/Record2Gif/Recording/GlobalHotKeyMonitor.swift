import AppKit
import Carbon
import Foundation

/// Monitors the global shortcut ⌃⌘Esc (Control + Command + Escape) to stop recording.
///
/// Uses Carbon's `RegisterEventHotKey` so that no Accessibility (TCC) permission is required
/// on macOS, supplemented by a local `NSEvent` keyDown monitor when the app itself is active.
@MainActor
final class GlobalHotKeyMonitor {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var localEventMonitor: Any?
    private var onTrigger: (() -> Void)?

    private static let hotKeySignature: OSType = 0x5232_4746 // "R2GF"
    private static let hotKeyIDValue: UInt32 = 1

    init() {}

    /// Registers the global ⌃⌘Esc hotkey. Returns `false` and cleans up any partial state
    /// if either `InstallEventHandler` or `RegisterEventHotKey` fails.
    @discardableResult
    func register(onTrigger: @escaping @MainActor () -> Void) -> Bool {
        unregister()
        self.onTrigger = onTrigger

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let callback: EventHandlerUPP = { _, eventRef, userData in
            guard let eventRef, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                eventRef,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr,
                  hotKeyID.signature == GlobalHotKeyMonitor.hotKeySignature,
                  hotKeyID.id == GlobalHotKeyMonitor.hotKeyIDValue else {
                return noErr
            }

            let monitor = Unmanaged<GlobalHotKeyMonitor>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in
                monitor.onTrigger?()
            }
            return noErr
        }

        var installedHandler: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            selfPtr,
            &installedHandler
        )
        guard installStatus == noErr, let installedHandler else {
            unregister()
            return false
        }
        self.eventHandlerRef = installedHandler

        let hotKeyID = EventHotKeyID(
            signature: Self.hotKeySignature,
            id: Self.hotKeyIDValue
        )
        var registeredHotKey: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_Escape),
            UInt32(cmdKey | controlKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &registeredHotKey
        )
        guard registerStatus == noErr, let registeredHotKey else {
            unregister()
            return false
        }
        self.hotKeyRef = registeredHotKey

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == UInt16(kVK_Escape) && flags.contains([.command, .control]) {
                Task { @MainActor in
                    self?.onTrigger?()
                }
                return nil
            }
            return event
        }

        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        onTrigger = nil
    }
}
