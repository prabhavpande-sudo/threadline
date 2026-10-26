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
// go of the mic. A calendar event (GET /api/upcoming) gets the same corner
// from a minute before it starts until five minutes after: "● Record & join"
// starts the take and opens the event's call link. Calendar wins over mic.
// Neither ever starts a recording by itself.
//   THREADLINE_MIC_PROMPT=0     turn the mic offer off
//   THREADLINE_MIC_APPS=a,b     bundle-ID prefixes that count as meeting apps
//   THREADLINE_CAL_PROMPT=0     turn the calendar offer off
//   THREADLINE_CAL_LEAD_SEC=60  how early the calendar offer appears
// During a take, if the meeting app that held the mic lets go of it for 10s,
// the panel counts down 15s ("Stopping in 12s", with Keep) and
// then stops. Takes with no meeting app on the mic never auto-stop.
//   THREADLINE_AUTO_STOP=0      turn auto-stop off
// Needs no permissions.
//
// Build:  swiftc -O capture/ThreadlinePanel.swift -o capture/threadline-panel

import Cocoa
import CoreAudio
import Foundation

let STATE_URL = URL(string: "http://127.0.0.1:4640/api/record/state")!
let STOP_URL = URL(string: "http://127.0.0.1:4640/api/record/stop")!
let START_URL = URL(string: "http://127.0.0.1:4640/api/record/start")!
let UPCOMING_URL = URL(string: "http://127.0.0.1:4640/api/upcoming")!

let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
func status(_ s: String) {
    FileHandle.standardError.write(("[panel] \(clock.string(from: Date())) " + s + "\n").data(using: .utf8)!)
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
    private let keepButton = NSButton(title: "Keep", target: nil, action: nil)
    private var startedAtMs: Double = 0
    private var stopping = false
    private var ticker: Timer?
    private var title = "Recording"
    /// Called when Keep is pressed during an auto-stop countdown.
    var onKeep: (() -> Void)?

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

        // Shares the timer's slot; only visible during an auto-stop countdown.
        keepButton.target = self
        keepButton.action = #selector(keepTapped)
        keepButton.frame = NSRect(x: 172, y: 15, width: 60, height: 30)
        keepButton.bezelStyle = .rounded
        keepButton.toolTip = "Keep recording"
        keepButton.isHidden = true
        blur.addSubview(keepButton)

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
            self.title = (title?.isEmpty == false ? title! : "Recording")
            if keepButton.isHidden { titleLabel.stringValue = self.title }
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
        showCountdown(nil)
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

    /// Auto-stop countdown text in place of the title, with Keep in place of
    /// the timer; nil restores the normal panel.
    func showCountdown(_ text: String?, reason: String = "") {
        if let text = text {
            if keepButton.isHidden { status("auto-stop countdown: \(reason)") }
            titleLabel.stringValue = text
            titleLabel.toolTip = reason
            timeLabel.isHidden = true
            keepButton.isHidden = false
        } else if !keepButton.isHidden {
            titleLabel.stringValue = title
            timeLabel.isHidden = false
            keepButton.isHidden = true
        }
    }

    @objc private func keepTapped() {
        status("auto-stop cancelled — keeping the recording")
        showCountdown(nil)
        onKeep?()
    }

    @objc private func stopTapped() { stop(notice: "■ Stopped — stitching the meeting…") }

    func stop(notice: String) {
        guard !stopping else { return }
        stopping = true
        hide()
        notify(notice)
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

// ── Offers: "record this?" prompts shown in the corner while idle ──────────
/// One prompt: what it says, what the primary button does, and what × does.
/// The key identifies the offer so a re-sent one updates in place.
struct Offer {
    let key: String
    let text: String
    let action: String
    let onAccept: () -> Void
    let onDismiss: () -> Void
}

var startInFlight = false

/// POST /api/record/start, narrating failures. `title` names the meeting.
func startRecording(title: String?, source: String) {
    startInFlight = true
    var req = URLRequest(url: START_URL)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try? JSONSerialization.data(withJSONObject: title.map { ["title": $0] } ?? [:])
    URLSession.shared.dataTask(with: req) { data, _, err in
        DispatchQueue.main.async { startInFlight = false }
        let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        if err != nil {
            notify("Threadline isn't reachable — is npm run dev running?")
        } else if body.contains("\"error\"") {
            status("start failed: \(body)")
            notify("Couldn't start recording — open Threadline for details")
        } else {
            status("recording started from \(source)")
        }
    }.resume()
}

/// "Mic in use · Zoom" after a meeting app holds the mic for two polls. The
/// take is named after the calendar event on now, if there is one.
final class MicOffer {
    private var candidate: String?    // app seen on the last poll, not yet confirmed
    private var dismissedApp: String? // × pressed; quiet until it leaves the mic
    private var wasRecording = false

    func offer(recording: Bool, micApp: String?, title: String?) -> Offer? {
        if recording {
            wasRecording = true
            candidate = nil
            return nil
        }
        if wasRecording {  // a take just ended: don't re-offer the call it came from
            wasRecording = false
            dismissedApp = micApp
        }
        guard let app = micApp else {
            candidate = nil
            dismissedApp = nil
            return nil
        }
        guard app != dismissedApp else { return nil }
        if app != candidate {  // first sighting: wait one more poll to skip blips
            candidate = app
            return nil
        }
        return Offer(key: "mic:\(app)", text: "Mic in use · \(app)", action: "● Record",
                     onAccept: { startRecording(title: title, source: "mic offer") },
                     onDismiss: { [weak self] in self?.dismissedApp = app })
    }
}

/// "Pricing sync · in 1 min" from a calendar event's lead time until five
/// minutes after it starts. Record & join also opens the event's call link.
struct UpcomingEvent {
    let title: String
    let atMs: Double
    let endMs: Double
    let joinURL: URL?
    var key: String { "\(title)@\(Int64(atMs))" }
}

final class CalendarOffer {
    var events: [UpcomingEvent] = []
    private var handled = Set<String>()  // dismissed, accepted, or recorded through
    private let leadMs = (Double(ProcessInfo.processInfo.environment["THREADLINE_CAL_LEAD_SEC"] ?? "") ?? 60) * 1000

    private func live(_ now: Double) -> [UpcomingEvent] {
        events.filter { now >= $0.atMs - leadMs && now <= $0.atMs + 300_000 && ($0.endMs == 0 || now < $0.endMs) }
    }

    /// The event on now, for naming a take started some other way — joining
    /// late counts too, so this runs to the event's end, not the offer window.
    func liveTitle(_ now: Double) -> String? {
        events.first { now >= $0.atMs - leadMs && now < ($0.endMs > 0 ? $0.endMs : $0.atMs + 300_000) }?.title
    }

    /// A live event the user waved off: its call shouldn't trigger the mic offer either.
    func dismissedLive(_ now: Double) -> Bool { live(now).contains { handled.contains($0.key) } }

    func offer(recording: Bool, now: Double) -> Offer? {
        let current = live(now)
        if recording {
            current.forEach { handled.insert($0.key) }
            return nil
        }
        guard let event = current.first(where: { !handled.contains($0.key) }) else { return nil }
        let key = event.key
        let mins = Int(((event.atMs - now) / 60_000).rounded())
        let when = mins >= 1 ? "in \(mins) min" : mins <= -1 ? "\(-mins) min ago" : "now"
        return Offer(
            key: "cal:\(key)", text: "\(event.title) · \(when)",
            action: event.joinURL == nil ? "● Record" : "● Record & join",
            onAccept: { [weak self] in
                self?.handled.insert(key)
                startRecording(title: event.title, source: "calendar offer")
                if let url = event.joinURL { NSWorkspace.shared.open(url) }
            },
            onDismiss: { [weak self] in self?.handled.insert(key) })
    }
}

/// Ends a take once the meeting app that held the mic during it lets go:
/// 10s of grace, then a 15s countdown in the panel with Keep. Takes where no
/// meeting app ever held the mic (an in-person room) never auto-stop.
/// It arms only once the app has held the mic for a minute of the take: Meet's
/// pre-join screen opens the mic, the offer comes up, and Chrome can let go
/// while joining — a take recorded on 2026-10-26 was ended there, before the
/// call, and discarded as too short.
final class AutoStop {
    enum Step { case idle, countdown(app: String, seconds: Int), stop(String) }
    private var app: String?        // meeting app seen on the mic this take
    private var absentSince: Double?
    private var heldMs = 0.0        // how long it has held the mic this take
    private var lastHeld: Double?
    private var kept = false
    private let armMs = 60_000.0
    private let graceMs = 10_000.0
    private let countdownMs = 15_000.0

    func step(recording: Bool, micApp: String?, now: Double) -> Step {
        guard recording else {
            app = nil
            absentSince = nil
            heldMs = 0
            lastHeld = nil
            kept = false
            return .idle
        }
        if let m = micApp {
            if let l = lastHeld { heldMs += now - l }
            lastHeld = now
            app = m
            absentSince = nil
            return .idle
        }
        lastHeld = nil
        guard let left = app, !kept, heldMs >= armMs else { return .idle }
        let since = absentSince ?? now
        absentSince = since
        let remaining = graceMs + countdownMs - (now - since)
        if remaining > countdownMs { return .idle }
        if remaining <= 0 {
            app = nil
            absentSince = nil
            return .stop(left)
        }
        return .countdown(app: left, seconds: Int((remaining / 1000).rounded(.up)))
    }

    /// Keep pressed: no auto-stop for the rest of this take.
    func keep() { kept = true }
}

/// The corner panel that shows the current offer, if any.
final class OfferPanel: NSObject {
    private let panel: FloatingPanel
    private let label = NSTextField(labelWithString: "")
    private let accept = NSButton(title: "● Record", target: nil, action: nil)
    private var current: Offer?
    private let size = OfferPanel.size
    private static let size = NSSize(width: 340, height: 60)

    override init() {
        let size = OfferPanel.size
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

        label.font = .systemFont(ofSize: 12.5, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        blur.addSubview(label)

        accept.target = self
        accept.action = #selector(acceptTapped)
        accept.bezelStyle = .rounded
        accept.contentTintColor = NSColor(red: 0.88, green: 0.27, blue: 0.24, alpha: 1)
        accept.toolTip = "Record this meeting"
        blur.addSubview(accept)

        let dismiss = NSButton(title: "×", target: self, action: #selector(dismissTapped))
        dismiss.frame = NSRect(x: size.width - 42, y: 15, width: 28, height: 30)
        dismiss.bezelStyle = .rounded
        dismiss.toolTip = "Not this one"
        blur.addSubview(dismiss)
        layout()
    }

    /// Accept button sized to its title; the label takes the rest of the row.
    private func layout() {
        accept.sizeToFit()
        let w = max(72, accept.frame.width + 8)
        accept.frame = NSRect(x: size.width - 42 - 4 - w, y: 15, width: w, height: 30)
        label.frame = NSRect(x: 14, y: 21, width: accept.frame.minX - 14 - 8, height: 18)
    }

    /// Show `offer` (updating in place if it's the same one), or hide when nil.
    func show(_ offer: Offer?) {
        guard let offer = offer else { return hide() }
        let isNew = current?.key != offer.key
        current = offer
        label.stringValue = offer.text
        if accept.title != offer.action { accept.title = offer.action; layout() }
        if isNew || !panel.isVisible {
            if let screen = NSScreen.main {
                let v = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: v.maxX - size.width - 16, y: v.maxY - size.height - 16))
            }
            panel.orderFrontRegardless()
            status("offered: \(offer.text)")
        }
    }

    private func hide() {
        current = nil
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    @objc private func acceptTapped() {
        let offer = current
        hide()
        offer?.onAccept()
    }

    @objc private func dismissTapped() {
        let offer = current
        status("dismissed: \(offer?.text ?? "offer")")
        hide()
        offer?.onDismiss()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // no Dock icon, no menu bar
let controller = PanelController()
let micPromptEnabled = ProcessInfo.processInfo.environment["THREADLINE_MIC_PROMPT"] != "0"
let calPromptEnabled = ProcessInfo.processInfo.environment["THREADLINE_CAL_PROMPT"] != "0"
let autoStopEnabled = ProcessInfo.processInfo.environment["THREADLINE_AUTO_STOP"] != "0"
let micOffer = MicOffer()
let calendarOffer = CalendarOffer()
let offerPanel = OfferPanel()
let autoStop = AutoStop()
controller.onKeep = { autoStop.keep() }

// Upcoming events change slowly; the server caches calendar fetches anyway.
func refreshUpcoming() {
    guard calPromptEnabled else { return }
    URLSession.shared.dataTask(with: UPCOMING_URL) { data, _, _ in
        guard let data = data, let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        let events = rows.compactMap { r -> UpcomingEvent? in
            guard let title = r["title"] as? String, let at = r["at_ms"] as? Double else { return nil }
            return UpcomingEvent(title: title, atMs: at, endMs: r["end_ms"] as? Double ?? 0,
                                 joinURL: (r["join_url"] as? String).flatMap(URL.init(string:)))
        }
        DispatchQueue.main.async { calendarOffer.events = events }
    }.resume()
}
refreshUpcoming()
Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in refreshUpcoming() }

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
        let serverUp = data != nil
        // Idle: who might want recording. Recording: whether the call is still on.
        let wantMic = serverUp && (recording ? autoStopEnabled : micPromptEnabled)
        let micApp = wantMic ? meetingAppOnMic() : nil
        DispatchQueue.main.async {
            controller.apply(recording: recording, title: title, startedAt: startedAt)
            switch autoStop.step(recording: recording, micApp: micApp, now: Date().timeIntervalSince1970 * 1000) {
            case .idle: controller.showCountdown(nil)
            case .countdown(let app, let seconds):
                controller.showCountdown("Stopping in \(seconds)s", reason: "\(app) left the mic")
            case .stop(let app):
                status("\(app) left the mic — auto-stopping")
                controller.stop(notice: "■ \(app) left the call — stitching the meeting…")
            }
            // Both state machines advance every poll; calendar wins the corner.
            let now = Date().timeIntervalSince1970 * 1000
            let cal = calendarOffer.offer(recording: recording, now: now)
            let mic = micOffer.offer(recording: recording, micApp: micApp, title: calendarOffer.liveTitle(now))
            // Only offer when the server answered: an unreachable server can't record.
            guard serverUp, !startInFlight else { return offerPanel.show(nil) }
            offerPanel.show(cal ?? (calendarOffer.dismissedLive(now) ? nil : mic))
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
