import AVFoundation
import AudioToolbox
import CoreAudio
import os.log

private let logger = Logger(subsystem: "com.aihelper.app", category: "SystemAudioCapture")

enum SystemAudioCaptureError: LocalizedError {
    case coreAudio(String, OSStatus)
    case noOutputDevice
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .coreAudio(let step, let status):
            return "Core Audio could not \(step) (error \(status))."
        case .noOutputDevice:
            return "No audio output device found."
        case .unsupportedFormat:
            return "The system audio format is not supported."
        }
    }
}

/// Records what the Mac plays — every app's audio except AIHelper's own — through a Core
/// Audio process tap. Unlike ScreenCaptureKit this needs no Screen Recording permission, only
/// "System Audio Recording" (System Settings › Privacy & Security › Screen & System Audio
/// Recording), which macOS asks for the first time a tap is created.
///
/// Without that permission the tap still runs but delivers silence; the meeting transcript
/// then only has the microphone side.
///
/// The tap feeds a private aggregate device whose IO block hands each buffer to `onBuffer` on
/// a private serial queue. A buffer is only valid during that call. When the default output
/// device changes (headphones plugged in, AirPods connecting) the tap is rebuilt.
@available(macOS 14.2, *)
final class SystemAudioCapture {
    private let ioQueue = DispatchQueue(label: "com.aihelper.system-audio.io", qos: .userInitiated)
    private let controlQueue = DispatchQueue(label: "com.aihelper.system-audio.control")

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var deviceListener: AudioObjectPropertyListenerBlock?

    deinit {
        // Nothing else can reach the object any more, so no need to hop onto controlQueue.
        stopListeningForOutputDeviceChanges()
        tearDownTap()
    }

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        try controlQueue.sync {
            self.onBuffer = onBuffer
            try buildTap()
            listenForOutputDeviceChanges()
        }
    }

    func stop() {
        controlQueue.sync {
            stopListeningForOutputDeviceChanges()
            tearDownTap()
            onBuffer = nil
        }
    }

    // MARK: - Tap

    /// Must run on `controlQueue`.
    private func buildTap() throws {
        tearDownTap()

        let description = CATapDescription(monoGlobalTapButExcludeProcesses: ownProcessObjectIDs())
        description.uuid = UUID()
        description.name = "AIHelper meeting capture"
        description.isPrivate = true

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr else { throw SystemAudioCaptureError.coreAudio("create the audio tap", status) }
        tapID = newTapID

        do {
            let format = try tapFormat()
            let outputUID = try defaultOutputDeviceUID()

            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "AIHelper Meeting Capture",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                // Not auto-start: that makes AudioDeviceStart wait until something plays.
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]],
            ]

            var newAggregateID = AudioObjectID(kAudioObjectUnknown)
            status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
            guard status == noErr else { throw SystemAudioCaptureError.coreAudio("create the capture device", status) }
            aggregateID = newAggregateID

            let handler = onBuffer
            var newProcID: AudioDeviceIOProcID?
            status = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateID, ioQueue) { _, inputData, _, _, _ in
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil),
                      buffer.frameLength > 0 else { return }
                handler?(buffer)
            }
            guard status == noErr, let newProcID else { throw SystemAudioCaptureError.coreAudio("attach to the capture device", status) }
            ioProcID = newProcID

            status = AudioDeviceStart(aggregateID, newProcID)
            guard status == noErr else { throw SystemAudioCaptureError.coreAudio("start capturing", status) }

            logger.info("System audio tap running: \(format.sampleRate, privacy: .public) Hz, \(format.channelCount, privacy: .public) ch, clocked by \(outputUID, privacy: .public)")
        } catch {
            tearDownTap()
            throw error
        }
    }

    /// Must run on `controlQueue`.
    private func tearDownTap() {
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func tapFormat() throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &description)
        guard status == noErr else { throw SystemAudioCaptureError.coreAudio("read the tap format", status) }
        guard let format = AVAudioFormat(streamDescription: &description) else { throw SystemAudioCaptureError.unsupportedFormat }
        return format
    }

    // MARK: - Devices and processes

    private func defaultOutputDeviceUID() throws -> String {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { throw SystemAudioCaptureError.noOutputDevice }

        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard status == noErr, let uid else { throw SystemAudioCaptureError.coreAudio("read the output device", status) }
        return uid.takeRetainedValue() as String
    }

    /// AIHelper's own audio object, so its sounds stay out of the recording. Empty when the
    /// process has not played anything yet (it then has no audio object to exclude).
    private func ownProcessObjectIDs() -> [AudioObjectID] {
        var pid = ProcessInfo.processInfo.processIdentifier
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &objectID
        )
        guard status == noErr, objectID != kAudioObjectUnknown else { return [] }
        return [objectID]
    }

    /// Must run on `controlQueue`.
    private func listenForOutputDeviceChanges() {
        guard deviceListener == nil else { return }
        var address = Self.defaultOutputAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.onBuffer != nil else { return }
            logger.info("Default output device changed — rebuilding the system audio tap")
            do {
                try self.buildTap()
            } catch {
                logger.error("Rebuilding the system audio tap failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, listener)
        if status == noErr {
            deviceListener = listener
        } else {
            logger.error("Could not watch the output device (error \(status, privacy: .public))")
        }
    }

    /// Must run on `controlQueue`.
    private func stopListeningForOutputDeviceChanges() {
        guard let deviceListener else { return }
        var address = Self.defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, deviceListener)
        self.deviceListener = nil
    }

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
