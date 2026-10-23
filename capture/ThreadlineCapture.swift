// ThreadlineCapture — captures BOTH sides of a meeting with no bot in the call:
//   channel 0: system audio (the other people, via a CoreAudio process tap on
//              macOS 14.2+, ScreenCaptureKit otherwise or if the tap fails)
//   channel 1: microphone   (you, via AVAudioEngine)
//
// Output on stdout, framed: [1 byte channel][4 bytes LE payload length][PCM16 mono @16kHz]
// Status lines go to stderr. Stop with SIGINT/SIGTERM or closing stdin.
// THREADLINE_SYSTEM_AUDIO=sck forces ScreenCaptureKit; =tap forbids the fallback.
//
// Build:  swiftc -O capture/ThreadlineCapture.swift -o capture/threadline-capture
// Needs: macOS 13+, Microphone permission for the terminal, plus System Audio
// Recording (process tap) or Screen Recording (ScreenCaptureKit fallback).

import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import ScreenCaptureKit

let TARGET_RATE = 16_000.0
let outLock = NSLock()

func emit(_ channel: UInt8, _ pcm: Data) {
    guard !pcm.isEmpty else { return }
    var header = Data([channel])
    var len = UInt32(pcm.count).littleEndian
    withUnsafeBytes(of: &len) { header.append(contentsOf: $0) }
    outLock.lock()
    FileHandle.standardOutput.write(header + pcm)
    outLock.unlock()
}

func status(_ s: String) {
    FileHandle.standardError.write(("[capture] " + s + "\n").data(using: .utf8)!)
}

/// Converts any incoming PCM format to 16 kHz mono Int16.
final class Downsampler {
    private var converter: AVAudioConverter?
    private var inFormat: AVAudioFormat?
    private let outFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: TARGET_RATE, channels: 1, interleaved: true)!

    func convert(_ buffer: AVAudioPCMBuffer) -> Data {
        if converter == nil || inFormat != buffer.format {
            inFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: outFormat)
            converter?.downmix = true  // mix stereo to mono instead of keeping only the left channel
        }
        guard let conv = converter else { return Data() }
        let ratio = TARGET_RATE / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return Data() }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, statusPtr in
            if fed { statusPtr.pointee = .noDataNow; return nil }
            fed = true
            statusPtr.pointee = .haveData
            return buffer
        }
        if err != nil { return Data() }
        guard let ch = out.int16ChannelData else { return Data() }
        return Data(bytes: ch[0], count: Int(out.frameLength) * 2)
    }
}

// ── Microphone (channel 1) ────────────────────────────────────────────────
let engine = AVAudioEngine()
let micDown = Downsampler()
let micQueue = DispatchQueue(label: "mic")
var lastMicBuffer = Date()

/// (Re)install the tap with the input's current format and start the engine.
func runMic() -> Bool {
    let input = engine.inputNode
    // NOTE: do not enable setVoiceProcessingEnabled here — on macOS it can
    // silence the input entirely (observed: all-zero samples). Echo between
    // speakers and mic is handled by the server-side echo gate instead.
    engine.stop()
    input.removeTap(onBus: 0)
    let fmt = input.outputFormat(forBus: 0)
    guard fmt.sampleRate > 0 else { return false }
    input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { buf, _ in
        lastMicBuffer = Date()
        emit(1, micDown.convert(buf))
    }
    do {
        try engine.start()
        lastMicBuffer = Date()
        status("mic capturing at \(Int(fmt.sampleRate))Hz")
        return true
    } catch {
        status("mic failed: \(error.localizedDescription)")
        return false
    }
}

func startMic() {
    // Joining a call reconfigures the input (Chrome/Meet opens it with voice
    // processing; headsets switch devices) and macOS stops this engine for
    // good. Restart on the change notice, and on a stall as a backstop: the
    // tap delivers buffers continuously, silence included, so 3s without one
    // means the mic stopped.
    NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in
        micQueue.asyncAfter(deadline: .now() + 0.3) {
            status("mic configuration changed — restarting the mic")
            _ = runMic()
        }
    }
    micQueue.async {
        if !runMic() { status("continuing with system audio only until the mic recovers") }
    }
    let watchdog = DispatchSource.makeTimerSource(queue: micQueue)
    watchdog.schedule(deadline: .now() + 3, repeating: 2)
    watchdog.setEventHandler {
        guard Date().timeIntervalSince(lastMicBuffer) > 3 else { return }
        status("mic stalled — restarting the mic")
        _ = runMic()
    }
    watchdog.resume()
    micWatchdog = watchdog
}
var micWatchdog: DispatchSourceTimer?

// ── System audio (channel 0) ──────────────────────────────────────────────
final class SystemAudio: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let down = Downsampler()

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw NSError(domain: "threadline", code: 1) }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        // Video is mandatory in the API; keep it tiny and drop the frames.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 5)
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "audio"))
        try await s.startCapture()
        stream = s
        status("system audio capturing")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid else { return }
        guard let desc = sb.formatDescription,
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return }
        var asbd = asbdPtr.pointee
        guard let fmt = AVAudioFormat(streamDescription: &asbd) else { return }
        let frames = AVAudioFrameCount(sb.numSamples)
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return }
        buf.frameLength = frames
        let ablPtr = buf.mutableAudioBufferList
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: ablPtr) == noErr
        else { return }
        emit(0, down.convert(buf))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        status("system stream stopped: \(error.localizedDescription)")
        exit(2)
    }
}

// ── System audio via process tap (channel 0, macOS 14.2+) ─────────────────
// Taps the system output mix (minus this process) into a private aggregate
// device. Needs only the System Audio Recording permission, not Screen
// Recording. The tap and aggregate are private to this process, so the OS
// tears them down when it exits.
struct CoreAudioError: Error, CustomStringConvertible {
    let step: String
    let code: OSStatus
    var description: String { "\(step) failed (OSStatus \(code))" }
}

func check(_ code: OSStatus, _ step: String) throws {
    if code != noErr { throw CoreAudioError(step: step, code: code) }
}

func getProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    qualifier: UnsafeRawPointer? = nil, qualifierSize: UInt32 = 0,
                    _ initial: T) throws -> T {
    var address = AudioObjectPropertyAddress(
        mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    let code = withUnsafeMutableBytes(of: &value) {
        AudioObjectGetPropertyData(object, &address, qualifierSize, qualifier, &size, $0.baseAddress!)
    }
    try check(code, "read property \(selector)")
    return value
}

@available(macOS 14.2, *)
final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let down = Downsampler()

    func start() throws {
        var pid = getpid()
        let me = try getProperty(AudioObjectID(kAudioObjectSystemObject),
                                 kAudioHardwarePropertyTranslatePIDToProcessObject,
                                 qualifier: &pid, qualifierSize: UInt32(MemoryLayout<pid_t>.size),
                                 AudioObjectID(kAudioObjectUnknown))
        let tap = CATapDescription(stereoGlobalTapButExcludeProcesses: me == kAudioObjectUnknown ? [] : [me])
        tap.uuid = UUID()
        tap.isPrivate = true
        tap.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(tap, &tapID), "create process tap")

        let output = try getProperty(AudioObjectID(kAudioObjectSystemObject),
                                     kAudioHardwarePropertyDefaultSystemOutputDevice,
                                     AudioObjectID(kAudioObjectUnknown))
        guard let uidRef = try getProperty(output, kAudioDevicePropertyDeviceUID, Unmanaged<CFString>?.none) else {
            throw CoreAudioError(step: "read output device UID", code: kAudioHardwareBadDeviceError)
        }
        let outputUID = uidRef.takeRetainedValue() as String
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Threadline system audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tap.uuid.uuidString],
            ],
        ]
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID),
                  "create aggregate device")

        var asbd = try getProperty(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription())
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw CoreAudioError(step: "read tap format", code: kAudioHardwareUnsupportedOperationError)
        }
        let down = self.down
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, DispatchQueue(label: "tap")) {
            _, input, _, _, _ in
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil)
            else { return }
            emit(0, down.convert(buf))
        }, "create IO proc")
        try check(AudioDeviceStart(aggregateID, procID), "start aggregate device")
        status("system audio capturing via process tap at \(Int(format.sampleRate))Hz")
    }
}

/// System Audio Recording permission for this process's responsible app, via the
/// private TCC preflight (0 = granted). An unauthorized tap delivers silence
/// rather than an error, so auto mode only taps when this confirms access.
func systemAudioRecordingGranted() -> Bool? {
    typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    guard let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
          let sym = dlsym(tcc, "TCCAccessPreflight") else { return nil }
    return unsafeBitCast(sym, to: Preflight.self)("kTCCServiceAudioCapture" as CFString, nil) == 0
}

/// Process tap first; ScreenCaptureKit when the tap is unavailable, unpermitted or fails.
func startSystemAudio() async {
    let mode = ProcessInfo.processInfo.environment["THREADLINE_SYSTEM_AUDIO"] ?? "auto"
    let permitted = systemAudioRecordingGranted()
    if mode == "auto" && permitted != true {
        status(permitted == nil
            ? "can't confirm System Audio Recording permission — using ScreenCaptureKit"
            : "no System Audio Recording permission — using ScreenCaptureKit")
    }
    if mode == "tap" || (mode == "auto" && permitted == true) {
        if #available(macOS 14.2, *) {
            let tap = SystemAudioTap()
            do {
                try tap.start()
                activeTap = tap
                return
            } catch {
                status("process tap unavailable: \(error)")
                if mode == "tap" { return }
                status("falling back to ScreenCaptureKit")
            }
        }
    }
    do {
        try await sys.start()
    } catch {
        status("system audio failed: \(error.localizedDescription)")
        status("grant Screen Recording permission: System Settings → Privacy & Security → Screen Recording")
        // Mic-only is still useful; don't exit.
    }
}

// ── Lifecycle ─────────────────────────────────────────────────────────────
var activeTap: AnyObject?
let sys = SystemAudio()
signal(SIGINT) { _ in status("stopping"); exit(0) }
signal(SIGTERM) { _ in status("stopping"); exit(0) }
// Parent closes our stdin to stop us.
DispatchQueue.global().async {
    _ = try? FileHandle.standardInput.readToEnd()
    status("stdin closed, stopping")
    exit(0)
}

Task {
    await startSystemAudio()
    startMic()
}
RunLoop.main.run()
