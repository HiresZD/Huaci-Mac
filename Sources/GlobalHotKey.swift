import AppKit
import Carbon

@MainActor
final class GlobalHotKey {
    var onPress: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private(set) var registered = false

    init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData = userData else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { owner.onPress?() }
            return noErr
        }, 1, &eventType, pointer, &eventHandler)
        guard handlerStatus == noErr else { return }
        let identifier = EventHotKeyID(signature: OSType(0x48554143), id: 1)
        let result = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), identifier,
                                         GetApplicationEventTarget(), 0, &hotKey)
        registered = result == noErr
    }

    func stop() {
        if let hotKey = hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler = eventHandler { RemoveEventHandler(eventHandler) }
        hotKey = nil
        eventHandler = nil
        registered = false
    }
}
