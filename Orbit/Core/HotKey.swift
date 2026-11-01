import Carbon.HIToolbox

/// Global keyboard shortcuts (⌥Space, ⌥P, …). Uses Carbon, which needs no extra permissions.
@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32

    private nonisolated(unsafe) static var actions: [UInt32: () -> Void] = [:]
    private nonisolated(unsafe) static var handlerInstalled = false
    private static var nextID: UInt32 = 1

    /// `keyCode` from Carbon (kVK_…), `modifiers` like `optionKey` or `optionKey | shiftKey`.
    init(keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(optionKey), action: @escaping () -> Void) {
        id = HotKey.nextID
        HotKey.nextID += 1
        HotKey.actions[id] = action
        HotKey.installHandler()
        let hotKeyID = EventHotKeyID(signature: OSType(0x5649_4B54), id: id) // "VIKT"
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        HotKey.actions[id] = nil
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKey.actions[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
        handlerInstalled = true
    }
}
