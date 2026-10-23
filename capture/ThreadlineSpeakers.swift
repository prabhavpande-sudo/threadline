// ThreadlineSpeakers — reads who the meeting app shows as speaking, through
// the Accessibility API, and prints one JSON line per sample on stdout:
//   {"t_ms":1792650745123,"app":"zoom","name":"Sharon"}
// The server runs it alongside the capture helper during a take; diarization
// later votes these samples onto the "Speaker N" voices.
//
//   --dump [bundle-prefix]   print the meeting app's accessibility tree once,
//                            for calibrating the speaking rules on a real call
//
// Zoom/Teams: an element labelled like "Sharon, speaking" or "Active speaker:
// Sharon". Meet labels no one as speaking; it moves a class onto the active
// speaker's tile instead (see meetActiveSpeaker). Matching nothing means no
// hints — never a guess. Chrome only exposes a page's tree with
// AXEnhancedUserInterface on, so that is set for windows whose title shows a
// Meet call, and nothing else.
// Needs Accessibility permission for the app running npm run dev.
//
// Build:  swiftc -O capture/ThreadlineSpeakers.swift -o capture/threadline-speakers

import AppKit
import ApplicationServices
import Foundation

let APPS: [(prefix: String, label: String, chromium: Bool)] = [
    ("us.zoom.xos", "zoom", false), ("com.microsoft.teams", "teams", false),
    ("com.google.Chrome", "meet", true), ("company.thebrowser.Browser", "meet", true),
    ("com.microsoft.edgemac", "meet", true), ("com.brave.Browser", "meet", true),
]
let MAX_NODES = 4000
let MAX_DEPTH = 40

func status(_ s: String) {
    FileHandle.standardError.write(("[speakers] " + s + "\n").data(using: .utf8)!)
}

func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}
func text(_ el: AXUIElement, _ name: String) -> String? {
    (attr(el, name) as? String).flatMap { $0.isEmpty ? nil : $0 }
}
func children(_ el: AXUIElement) -> [AXUIElement] { (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func windows(_ app: AXUIElement) -> [AXUIElement] { (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] }

/// Depth-first walk under a node budget; `visit` returns false to stop.
func walk(_ root: AXUIElement, _ visit: (AXUIElement, Int) -> Bool) {
    var stack: [(AXUIElement, Int)] = [(root, 0)]
    var seen = 0
    while let (el, depth) = stack.popLast(), seen < MAX_NODES {
        seen += 1
        if !visit(el, depth) { return }
        if depth < MAX_DEPTH { stack.append(contentsOf: children(el).reversed().map { ($0, depth + 1) }) }
    }
}

/// Meet windows only: Chrome's title is the active tab's ("Meet – abc-defg-hij").
func callWindows(_ app: AXUIElement, chromium: Bool) -> [AXUIElement] {
    let all = windows(app)
    guard chromium else { return all }
    let meet = all.filter { (text($0, kAXTitleAttribute) ?? "").range(of: #"Meet\b"#, options: .regularExpression) != nil }
    if !meet.isEmpty {
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }
    return meet
}

let SPEAKING: [NSRegularExpression] = [
    try! NSRegularExpression(pattern: #"^(.{2,60}?)[,:]?\s+(?:is\s+)?(?:speaking|talking)\b"#, options: .caseInsensitive),
    try! NSRegularExpression(pattern: #"\b(?:active speaker|now speaking|speaking now)[:,]?\s+(.{2,60})$"#, options: .caseInsensitive),
]

/// "Sharon (Host), speaking" → "Sharon"; nil for the owner's own tile.
func speakingName(_ label: String) -> String? {
    let range = NSRange(label.startIndex..., in: label)
    for re in SPEAKING {
        guard let m = re.firstMatch(in: label, range: range), let r = Range(m.range(at: 1), in: label) else { continue }
        let name = label[r]
            .replacingOccurrences(of: #"\s*\((host|co-host|me|you|guest)\)"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if name.count >= 2, !["you", "me"].contains(name.lowercased()) { return name }
    }
    return nil
}

// ── Meet: the active-speaker class on one participant tile ────────────────
// Calibrated on a real call (2026-10-23, 4 Hz samples of each tile against
// the owner's mic): exactly one tile carries "v5h6Xc" at every moment and it
// moves to whoever speaks. Meet's class names are build artefacts that change
// between releases, so when the known class vanishes the marker is
// rediscovered: the class that sits on exactly one tile nearly every sample
// and has moved between at least two tiles. The owner's own tile counts too;
// the server drops hints in the owner's name, since that voice is the mic.
let KNOWN_MEET_MARKERS: Set<String> = ["v5h6Xc"]
let TILE_DEPTH = 7          // name text → tile root, measured on Meet's tree
let MARKER_WINDOW = 60      // samples (one a second) used to rediscover the marker

struct Tile { let name: String; let classes: Set<String> }
var tileHistory: [[Tile]] = []

func domClasses(_ el: AXUIElement) -> [String] { (attr(el, "AXDOMClassList") as? [String]) ?? [] }

/// A tile's display name: "Rachita Mahajan (Presenting)" → "Rachita Mahajan".
func tileName(_ text: String) -> String? {
    let name = text.replacingOccurrences(of: #"\s*\(.*\)\s*$"#, with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard (2...60).contains(name.count), name.rangeOfCharacter(from: .letters) != nil,
          name.range(of: #"^\d{1,2}:\d{2}$|says in chat|^(AM|PM)$"#, options: .regularExpression) == nil
    else { return nil }
    return name
}

/// Each participant tile: the subtree TILE_DEPTH levels above a text node that
/// holds exactly one candidate name, with every DOM class inside it.
func meetTiles(_ window: AXUIElement) -> [Tile] {
    var groups: [(root: AXUIElement, names: [String])] = []
    walk(window) { el, _ in
        guard text(el, kAXRoleAttribute) == "AXStaticText", let v = text(el, kAXValueAttribute), let name = tileName(v)
        else { return true }
        var root = el
        for _ in 0..<TILE_DEPTH { if let p = attr(root, kAXParentAttribute) { root = p as! AXUIElement } }
        if let i = groups.firstIndex(where: { CFEqual($0.root, root) }) { groups[i].names.append(name) }
        else { groups.append((root, [name])) }
        return true
    }
    return groups.filter { $0.names.count == 1 }.map { g in
        var classes = Set<String>()
        var stack = [g.root]
        var n = 0
        while let x = stack.popLast(), n < 300 {
            n += 1
            classes.formUnion(domClasses(x))
            stack.append(contentsOf: children(x))
        }
        return Tile(name: g.names[0], classes: classes)
    }
}

/// The class marking the active speaker in recent history, known one first.
func activeMarker() -> String? {
    let recent = tileHistory.suffix(MARKER_WINDOW)
    if recent.contains(where: { $0.contains { !$0.classes.isDisjoint(with: KNOWN_MEET_MARKERS) } }) {
        return KNOWN_MEET_MARKERS.first { k in recent.contains { $0.contains { $0.classes.contains(k) } } }
    }
    guard recent.count >= 20 else { return nil }
    var exclusive: [String: Int] = [:], holders: [String: Set<String>] = [:]
    for sample in recent {
        var on: [String: [String]] = [:]
        for t in sample { for c in t.classes { on[c, default: []].append(t.name) } }
        for (c, names) in on where names.count == 1 {
            exclusive[c, default: 0] += 1
            holders[c, default: []].insert(names[0])
        }
    }
    return exclusive
        .filter { Double($0.value) >= 0.9 * Double(recent.count) && (holders[$0.key]?.count ?? 0) >= 2 }
        .max { $0.value < $1.value }?.key
}

func meetActiveSpeaker(_ windows: [AXUIElement]) -> String? {
    let tiles = windows.flatMap(meetTiles)
    guard tiles.count >= 2 else { return nil }
    tileHistory.append(tiles)
    if tileHistory.count > MARKER_WINDOW { tileHistory.removeFirst() }
    guard let marker = activeMarker() else { return nil }
    let holding = tiles.filter { $0.classes.contains(marker) }
    return holding.count == 1 ? holding[0].name : nil
}

func currentSpeaker(_ app: AXUIElement, chromium: Bool) -> String? {
    if chromium { return meetActiveSpeaker(callWindows(app, chromium: true)) }
    var found: String?
    for w in callWindows(app, chromium: chromium) {
        walk(w) { el, _ in
            for key in [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute, kAXHelpAttribute] {
                if let label = text(el, key), let name = speakingName(label) { found = name; return false }
            }
            return true
        }
        if found != nil { break }
    }
    return found
}

func runningMeetingApps(prefix: String? = nil) -> [(NSRunningApplication, String, Bool)] {
    NSWorkspace.shared.runningApplications.compactMap { app in
        guard let id = app.bundleIdentifier else { return nil }
        if let p = prefix { return id.hasPrefix(p) ? (app, id, APPS.first { id.hasPrefix($0.prefix) }?.chromium ?? false) : nil }
        guard let known = APPS.first(where: { id.hasPrefix($0.prefix) }) else { return nil }
        return (app, known.label, known.chromium)
    }
}

guard AXIsProcessTrusted() else {
    status("needs Accessibility permission (System Settings → Privacy & Security → Accessibility)")
    exit(3)
}

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--dump") {
    let prefix = args.count > i + 1 ? args[i + 1] : nil
    let apps = runningMeetingApps(prefix: prefix)
    if apps.isEmpty { status("no matching meeting app running") }
    for (app, label, chromium) in apps {
        let el = AXUIElementCreateApplication(app.processIdentifier)
        print("## \(label) pid \(app.processIdentifier)")
        for w in callWindows(el, chromium: chromium) {
            walk(w) { node, depth in
                let fields = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute]
                    .compactMap { k in text(node, k).map { "\(k.replacingOccurrences(of: "AX", with: ""))=\"\($0.prefix(80))\"" } }
                print(String(repeating: "  ", count: min(depth, 30)) + fields.joined(separator: " "))
                return true
            }
        }
    }
    exit(0)
}

// Watch: one sample a second for the life of the take.
var last: String?
Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
    for (app, label, chromium) in runningMeetingApps() {
        guard let name = currentSpeaker(AXUIElementCreateApplication(app.processIdentifier), chromium: chromium) else { continue }
        let line: [String: Any] = ["t_ms": Int64(Date().timeIntervalSince1970 * 1000), "app": label, "name": name]
        if let data = try? JSONSerialization.data(withJSONObject: line) {
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        }
        if name != last { status("\(label): \(name) speaking"); last = name }
        break
    }
}
status("watching meeting apps for the active speaker")
// Parent closes stdin to stop us.
DispatchQueue.global().async {
    _ = try? FileHandle.standardInput.readToEnd()
    exit(0)
}
RunLoop.main.run()
