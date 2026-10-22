// ThreadlinePanel — floating always-on-top recording companion.
//
// Watches GET /api/record/state (2s poll) and shows a small non-activating
// panel whenever a take is live — however it was started (macOS Shortcut,
// the web UI's Record button, a calendar notification). Red dot, title,
// elapsed timer, and a Stop button that ends the take. Hides itself the
// moment the recording stops, so stopping via the Shortcut also dismisses it.
//
// While idle it also watches which apps hold the microphone (CoreAudio's
// process list, macOS 14.2+). When a meeting app keeps the mic for two polls,
// it offers "● Record" in the same corner; × stays quiet until that app lets
// go of the mic. It never starts a recording by itself.
//   THREADLINE_MIC_PROMPT=0   turn the offer off
//   THREADLINE_MIC_APPS=a,b   bundle-ID prefixes that count as meeting apps
// Needs no permissions.
//
// Build:  swiftc -O capture/ThreadlinePanel.swift -o capture/threadline-panel

import Cocoa
import CoreAudio
import Foundation

let STATE_URL = URL(string: "http://127.0.0.1:4640/api/record/state")!
let STOP_URL = URL(string: "http://127.0.0.1:4640/api/record/stop")!
let START_URL = URL(string: "http://127.0.0.1:4640/api/record/start")!

func status(_ s: String) {
    FileHandle.standardError.write(("[panel] " + s + "\n").data(using: .utf8)!)
}

/// Same narration as the Shortcuts script: acting on the panel always answers
/// back with a notification, so a click is never a leap of faith.
func notify(_ text: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "display notification \"\(text)\" with title \"Threadline\""]
    try? p.run()
}

/// Narrate the /api/record/stop response — same messages the Shortcut shows.
func narrateStop(_ body: String) {
    if body.contains("\"exit\":\"discarded\"") {
        notify("Too short — discarded. Hold recordings ≥15s to keep them.")
    } else if body.contains("\"exit\":\"failed\"") {
        notify("Nothing was captured — check mic/screen permissions")
    } else if let r = body.range(of: "\"title\":\""), let end = body[r.upperBound...].range(of: "\"") {
        notify("✓ Saved: \(body[r.upperBound..<end.lowerBound])")
    } else {
        notify("✓ Meeting saved")
    }
}

// Borderless panels refuse key status by default; the Stop button wants it.
// .nonactivatingPanel keeps clicks from activating the app or stealing focus.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class PanelController: NSObject {
    private let panel: FloatingPanel
    private let titleLabel = NSTextField(labelWithString: "Recording")
    private let timeLabel = NSTextField(labelWithString: "00:00")
    private let dot = NSView(frame: NSRect(x: 14, y: 25, width: 10, height: 10))
    private var startedAtMs: Double = 0
    private var stopping = false
    private var ticker: Timer?

    override init() {
        let size = NSSize(width: 292, height: 60)
        panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        super.init()

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        blur.material = .hudWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 14
        blur.layer?.masksToBounds = true
        panel.contentView = blur

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor(red: 0.88, green: 0.27, blue: 0.24, alpha: 1).cgColor
        dot.layer?.cornerRadius = 5
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.35
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.layer?.add(pulse, forKey: "pulse")
        blur.addSubview(dot)

        titleLabel.frame = NSRect(x: 32, y: 21, width: 140, height: 18)
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        blur.addSubview(titleLabel)

        timeLabel.frame = NSRect(x: 176, y: 21, width: 52, height: 18)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        blur.addSubview(timeLabel)

        let stop = NSButton(title: "■", target: self, action: #selector(stopTapped))
        stop.frame = NSRect(x: 234, y: 15, width: 44, height: 30)
        stop.bezelStyle = .rounded
        stop.font = .systemFont(ofSize: 13, weight: .bold)
        stop.contentTintColor = NSColor(red: 0.88, green: 0.27, blue: 0.24, alpha: 1)
        stop.toolTip = "Stop recording"
        blur.addSubview(stop)

        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: v.maxX - size.width - 16, y: v.maxY - size.height - 16))
        }
    }

    /// Called on the main thread with the latest server state.
    func apply(recording: Bool, title: String?, startedAt: Double?) {
        if recording && !stopping {
            startedAtMs = startedAt ?? startedAtMs
            titleLabel.stringValue = (title?.isEmpty == false ? title! : "Recording")
            if !panel.isVisible {
                if startedAt == nil { startedAtMs = Date().timeIntervalSince1970 * 1000 }
                tickTime()
                panel.orderFrontRegardless()
                ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tickTime() }
                status("recording live — panel shown")
            }
        } else if !recording {
            stopping = false
            hide()
        }
    }

    private func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        ticker?.invalidate()
        ticker = nil
        status("recording ended — panel hidden")
    }

    private func tickTime() {
        let secs = max(0, Int((Date().timeIntervalSince1970 * 1000 - startedAtMs) / 1000))
        timeLabel.stringValue = String(format: "%02d:%02d", secs / 60, secs % 60)
    }

    @objc private func stopTapped() {
        guard !stopping else { return }
        stopping = true
        hide()
        notify("■ Stopped — stitching the meeting…")
        var req = URLRequest(url: STOP_URL)
        req.httpMethod = "POST"
        req.timeoutInterval = 300 // stop blocks through transcription + notes
        URLSession.shared.dataTask(with: req) { data, _, err in
            DispatchQueue.main.async { self.stopping = false }
            if let err = err {
                status("stop failed: \(err.localizedDescription)")
                notify("Threadline isn't reachable — is npm run dev running?")
                return
            }
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            status("stopped: \(body)")
            narrateStop(body)
        }.resume()
    }
}

// ── Meeting apps on the microphone ─────────────────────────────────────────
// Browsers count because Meet runs in one; their mic is held by a helper
// process whose bundle ID extends the browser's, hence prefix matching.
// Slack is left out: its helper can hold the mic outside a huddle, which
// would mean a standing false offer. Add it via THREADLINE_MIC_APPS.
let MEETING_APPS: [(prefix: String, name: String)] = {
    if let custom = ProcessInfo.processInfo.environment["THREADLINE_MIC_APPS"], !custom.isEmpty {
        return custom.split(separator: ",").map { (String($0).trimmingCharacters(in: .whitespaces), "meeting app") }
    }
    return [
        ("us.zoom.", "Zoom"), ("com.microsoft.teams", "Teams"), ("com.apple.FaceTime", "FaceTime"), ("com.cisco.", "Webex"), ("Cisco-Systems.Spark", "Webex"),
        ("com.hnc.Discord", "Discord"), ("net.whatsapp.WhatsApp", "WhatsApp"),
        ("com.google.Chrome", "Chrome"), ("com.apple.Safari", "Safari"), ("com.apple.WebKit", "Safari"),
        ("company.thebrowser.", "Arc"), ("com.microsoft.edgemac", "Edge"), ("org.mozilla.firefox", "Firefox"),
        ("com.brave.Browser", "Brave"),
    ]
}()

func audioProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    let code = withUnsafeMutableBytes(of: &value) {
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!)
    }
    return code == noErr ? value : nil
}

/// Display name of the first meeting app currently capturing from any input, or nil.
func meetingAppOnMic() -> String? {
    guard #available(macOS 14.2, *) else { return nil }
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    let system = AudioObjectID(kAudioObjectSystemObject)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
    var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return nil }
    for process in processes {
        guard audioProperty(process, kAudioProcessPropertyIsRunningInput, UInt32(0)) == 1,
              let ref = audioProperty(process, kAudioProcessPropertyBundleID, Unmanaged<CFString>?.none) ?? nil
        else { continue }
        let bundleID = ref.takeRetainedValue() as String
        if let app = MEETING_APPS.first(where: { bundleID.hasPrefix($0.prefix) }) { return app.name }
    }
    return nil
}

/// The "Mic in use · <app> — ● Record / ×" offer, shown only while idle.
final class MicPromptController: NSObject {
    private let panel: FloatingPanel
    private let label = NSTextField(labelWithString: "")
    private var candidate: String?   // app seen on the last poll, not yet confirmed
    private var offeredApp: String?  // app the visible offer is for
    private var dismissedApp: String? // × pressed; quiet until it leaves the mic
    private var starting = false
    private var wasRecording = false

    override init() {
        let size = NSSize(width: 292, height: 60)
        panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        super.init()
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        blur.material = .hudWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 14
        blur.layer?.masksToBounds = true
        panel.contentView = blur

        label.frame = NSRect(x: 14, y: 21, width: 164, height: 18)
        label.font = .systemFont(ofSize: 12.5, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        blur.addSubview(label)

        let record = NSButton(title: "● Record", target: self, action: #selector(recordTapped))
        record.frame = NSRect(x: 180, y: 15, width: 72, height: 30)
        record.bezelStyle = .rounded
        record.contentTintColor = NSColor(red: 0.88, green: 0.27, blue: 0.24, alpha: 1)
        record.toolTip = "Record this meeting"
        blur.addSubview(record)

        let dismiss = NSButton(title: "×", target: self, action: #selector(dismissTapped))
        dismiss.frame = NSRect(x: 254, y: 15, width: 28, height: 30)
        dismiss.bezelStyle = .rounded
        dismiss.toolTip = "Not this one"
        blur.addSubview(dismiss)

        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: v.maxX - size.width - 16, y: v.maxY - size.height - 16))
        }
    }

    /// Called on the main thread after each state poll.
    func apply(recording: Bool, micApp: String?) {
        if recording {
            wasRecording = true
            hide()
            candidate = nil
            return
        }
        if wasRecording {  // a take just ended: don't re-offer the call it came from
            wasRecording = false
            dismissedApp = micApp
        }
        guard let app = micApp else {
            hide()
            candidate = nil
            dismissedApp = nil
            return
        }
        guard app != dismissedApp, !starting else { return }
        if app != candidate {  // first sighting: wait one more poll to skip blips
            candidate = app
            return
        }
        if offeredApp != app {
            offeredApp = app
            label.stringValue = "Mic in use · \(app)"
            panel.orderFrontRegardless()
            status("\(app) is using the mic — offered to record")
        }
    }

    private func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        offeredApp = nil
    }

    @objc private func dismissTapped() {
        dismissedApp = offeredApp
        status("offer dismissed for \(offeredApp ?? "app")")
        hide()
    }

    @objc private func recordTapped() {
        guard !starting else { return }
        starting = true
        hide()
        var req = URLRequest(url: START_URL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        URLSession.shared.dataTask(with: req) { data, _, err in
            DispatchQueue.main.async { self.starting = false }
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if err != nil {
                notify("Threadline isn't reachable — is npm run dev running?")
            } else if body.contains("\"error\"") {
                status("start failed: \(body)")
                notify("Couldn't start recording — open Threadline for details")
            } else {
                status("recording started from mic offer")
            }
        }.resume()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // no Dock icon, no menu bar
let controller = PanelController()
let micPromptEnabled = ProcessInfo.processInfo.environment["THREADLINE_MIC_PROMPT"] != "0"
let micPrompt = MicPromptController()

// Poll the server for recording state. Unreachable server = treat as idle.
Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
    URLSession.shared.dataTask(with: STATE_URL) { data, _, _ in
        var recording = false
        var title: String? = nil
        var startedAt: Double? = nil
        if let data = data,
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            recording = obj["recording"] as? Bool ?? false
            title = obj["title"] as? String
            startedAt = obj["startedAt"] as? Double
        }
        // Only offer when the server answered: an unreachable server can't record.
        let micApp = micPromptEnabled && data != nil && !recording ? meetingAppOnMic() : nil
        DispatchQueue.main.async {
            controller.apply(recording: recording, title: title, startedAt: startedAt)
            micPrompt.apply(recording: recording, micApp: micApp)
        }
    }.resume()
}

status("watching for recordings")
// Parent closes stdin to stop us.
DispatchQueue.global().async {
    _ = try? FileHandle.standardInput.readToEnd()
    exit(0)
}
app.run()
