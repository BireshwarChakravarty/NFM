import AudioToolbox
import CoreAudio
import Foundation

/// Small Core Audio helpers shared by the enhancer and Audio Diagnostics.
enum AudioHelpers {
    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    @discardableResult
    static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> OSStatus {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
    }

    struct AudioProcess { let objectID: AudioObjectID; let pid: pid_t }

    /// The WebKit helper processes (GPU / WebContent) that play Netflix for
    /// this NFM. Safari and other apps are never touched.
    ///
    /// NFM's own process is always excluded: the enhancer plays its processed
    /// sound from NFM itself, so tapping NFM would mute that output and feed
    /// it back into its own input.
    static func ownAudioProcesses() -> [AudioProcess] {
        let me = getpid()
        return processObjects().compactMap { object in
            var pid: pid_t = -1
            guard get(object, kAudioProcessPropertyPID, &pid) == noErr, pid > 0 else { return nil }
            var bundle: Unmanaged<CFString>?
            let bundleID = get(object, kAudioProcessPropertyBundleID, &bundle) == noErr
                ? bundle?.takeRetainedValue() as String? : nil
            guard shouldTap(pid: pid, me: me, responsible: responsiblePID(for: pid), bundleID: bundleID) else { return nil }
            return AudioProcess(objectID: object, pid: pid)
        }
    }

    /// Only WebKit helpers that macOS holds NFM responsible for; never NFM itself.
    static func shouldTap(pid: pid_t, me: pid_t, responsible: pid_t, bundleID: String?) -> Bool {
        guard pid != me, responsible == me else { return false }
        if let bundleID, !bundleID.isEmpty { return bundleID.hasPrefix("com.apple.WebKit") }
        return true
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        var device = AudioObjectID(kAudioObjectUnknown)
        guard get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &device) == noErr,
              device != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return device
    }

    struct OutputDeviceInfo {
        var name = "Unknown"
        var transport = "Unknown"
        var channels = 0
        var sampleRate = 0.0
        var volume: Double?
        var muted: Bool?
        var isBluetooth: Bool { transport.hasPrefix("Bluetooth") }
    }

    static func outputDeviceInfo() -> OutputDeviceInfo? {
        guard let device = defaultOutputDevice() else { return nil }
        var info = OutputDeviceInfo()

        var name: Unmanaged<CFString>?
        if get(device, kAudioObjectPropertyName, &name) == noErr, let name {
            info.name = name.takeRetainedValue() as String
        }

        var transport: UInt32 = 0
        if get(device, kAudioDevicePropertyTransportType, &transport) == noErr {
            switch transport {
            case kAudioDeviceTransportTypeBuiltIn: info.transport = "Built-in"
            case kAudioDeviceTransportTypeBluetooth: info.transport = "Bluetooth"
            case kAudioDeviceTransportTypeBluetoothLE: info.transport = "Bluetooth LE"
            case kAudioDeviceTransportTypeUSB: info.transport = "USB"
            case kAudioDeviceTransportTypeHDMI: info.transport = "HDMI"
            case kAudioDeviceTransportTypeDisplayPort: info.transport = "DisplayPort"
            case kAudioDeviceTransportTypeAirPlay: info.transport = "AirPlay"
            case kAudioDeviceTransportTypeThunderbolt: info.transport = "Thunderbolt"
            case kAudioDeviceTransportTypeVirtual: info.transport = "Virtual"
            case kAudioDeviceTransportTypeAggregate: info.transport = "Aggregate"
            default: info.transport = "Other"
            }
        }

        var rate: Float64 = 0
        if get(device, kAudioDevicePropertyNominalSampleRate, &rate) == noErr { info.sampleRate = rate }

        var volume: Float32 = 0
        if get(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, &volume,
               scope: kAudioDevicePropertyScopeOutput) == noErr {
            info.volume = Double(volume)
        }
        var mute: UInt32 = 0
        if get(device, kAudioDevicePropertyMute, &mute, scope: kAudioDevicePropertyScopeOutput) == noErr {
            info.muted = mute != 0
        }

        // Output channel count from the stream configuration.
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        if AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 {
            let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { raw.deallocate() }
            if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr {
                let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
                info.channels = list.reduce(0) { $0 + Int($1.mNumberChannels) }
            }
        }
        return info
    }

    static func processObjects() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func defaultOutputDeviceUID() -> String? {
        var device = AudioObjectID(kAudioObjectUnknown)
        guard get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &device) == noErr,
              device != AudioObjectID(kAudioObjectUnknown) else { return nil }
        var uid: Unmanaged<CFString>?
        guard get(device, kAudioDevicePropertyDeviceUID, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    /// The app macOS holds responsible for a process: for WebKit's XPC
    /// helpers that is the app hosting the web view.
    static func responsiblePID(for pid: pid_t) -> pid_t {
        typealias Responsible = @convention(c) (pid_t) -> pid_t
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return -1
        }
        return unsafeBitCast(symbol, to: Responsible.self)(pid)
    }
}
