// redline-mac.swift - REDLINE for Claude Code on macOS
// Native AppKit port of shift-gui.ps1. Draggable H-pattern shifter; drag the knob
// into a gate -> writes "/model <x>" into your frontmost terminal via the terminal's
// own AppleScript API (iTerm2 `write text` / Terminal.app `do script`). No keystroke
// injection, no Accessibility permission. Fuel gauge = context remaining (reads the
// newest ~/.claude session jsonl). Effort levers -> /effort. NOS -> /fast.
// Usage bars -> 5-hour + weekly limits (OAuth usage endpoint; token from Keychain).
//
// Run:  swift redline-mac.swift      (needs Xcode Command Line Tools: xcode-select --install)

import Cocoa

// ---- gears: gate position -> /model arg ----
struct Gear { let id: String; let name: String; let cmd: String; let col: Int; let row: Int }
let GEARS: [Gear] = [
    Gear(id: "1", name: "HAIKU",     cmd: "haiku",          col: 0, row: 0),
    Gear(id: "2", name: "SONNET",    cmd: "sonnet",         col: 0, row: 1),
    Gear(id: "3", name: "SONNET 1M", cmd: "sonnet[1m]",     col: 1, row: 0),
    Gear(id: "4", name: "OPUS",      cmd: "opus",           col: 1, row: 1),
    Gear(id: "5", name: "FABLE",     cmd: "claude-fable-5", col: 2, row: 0),
    Gear(id: "R", name: "DEFAULT",   cmd: "default",        col: 2, row: 1),
]
let EFFORTS: [(cmd: String, lbl: String)] = [("low","LOW"),("medium","MED"),("high","HIGH"),("xhigh","XHI")]

// ---- geometry (matches the Windows layout; top-left origin via a flipped view) ----
let COLS: [CGFloat] = [60, 120, 180]
let ROWY: [CGFloat] = [48, 200]
let NEUT = CGPoint(x: 120, y: 124)
let KR: CGFloat = 21
let SHIFT_ORIGIN_Y: CGFloat = 246   // shifter panel top within the window content

func col(_ i: Int) -> CGFloat { COLS[i] }

// ---- color helper ----
func C(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 255) -> NSColor {
    NSColor(calibratedRed: r/255, green: g/255, blue: b/255, alpha: a/255)
}

// ================= terminal write (native AppleScript) =================
func runOSA(_ script: String) {
    let p = Process()
    p.launchPath = "/usr/bin/osascript"
    p.arguments = ["-e", script]
    p.standardError = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
}

// front terminal app -> write text into its active session. Escapes quotes/backslashes.
func sendToTerminal(_ text: String) -> Bool {
    let ws = NSWorkspace.shared
    let bundle = ws.frontmostApplication?.bundleIdentifier ?? ""
    let esc = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    switch bundle {
    case "com.googlecode.iterm2":
        // write text feeds the running TUI through iTerm2's own scripting API
        runOSA("tell application \"iTerm2\" to tell current session of current window to write text \"\(esc)\"")
        runOSA("tell application \"iTerm2\" to tell current session of current window to write text \"\"")
        return true
    case "com.apple.Terminal":
        runOSA("tell application \"Terminal\" to do script \"\(esc)\" in front window")
        runOSA("tell application \"Terminal\" to do script \"\" in front window")
        return true
    default:
        return false   // not a supported terminal in front
    }
}

// ================= fuel: read newest ~/.claude session transcript =================
let HOME = FileManager.default.homeDirectoryForCurrentUser
let PROJECTS = HOME.appendingPathComponent(".claude/projects")

func tank(_ model: String) -> Int {
    if model.contains("haiku") { return 200_000 }
    return 1_000_000   // sonnet/opus/fable all 1M
}

var njCache: URL? = nil
var njStamp: Date = .distantPast
func newestJsonl() -> URL? {
    if Date().timeIntervalSince(njStamp) < 15, let c = njCache { return c }
    var best: URL? = nil
    var bestDate = Date.distantPast
    if let en = FileManager.default.enumerator(at: PROJECTS, includingPropertiesForKeys: [.contentModificationDateKey]) {
        for case let u as URL in en where u.pathExtension == "jsonl" {
            let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if d > bestDate { bestDate = d; best = u }
        }
    }
    njCache = best; njStamp = Date()
    return best
}

// last N bytes -> lines (transcripts get big; never read the whole file)
func tailLines(_ url: URL, _ bytes: Int = 1_048_576) -> [String] {
    guard let fh = try? FileHandle(forReadingFrom: url) else { return [] }
    defer { try? fh.close() }
    let size = (try? fh.seekToEnd()) ?? 0
    let take = UInt64(min(Int64(bytes), Int64(size)))
    if take == 0 { return [] }
    try? fh.seek(toOffset: size - take)
    let data = (try? fh.readToEnd()) ?? Data()
    guard let s = String(data: data, encoding: .utf8) else { return [] }
    return s.split(separator: "\n").map(String.init)
}

// ================= app state =================
var curGear: String? = nil
var fuel: Int? = nil
var curLimit: Int = 1_000_000
var effort: String? = nil
var lastCmd: String? = nil
var lim5h: Int? = nil
var limWk: Int? = nil

func updateFuel() {
    guard let f = newestJsonl() else { return }
    let lines = tailLines(f)
    let cand = lines.filter { $0.contains("\"input_tokens\"") }
    var tries = 0
    for line in cand.reversed() {
        tries += 1; if tries > 40 { break }
        guard let d = line.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
        if (o["isSidechain"] as? Bool) == true { continue }
        guard let msg = o["message"] as? [String: Any],
              let u = msg["usage"] as? [String: Any],
              let inTok = u["input_tokens"] as? Int else { continue }
        let model = (msg["model"] as? String) ?? ""
        curLimit = tank(model)
        let tot = inTok
            + ((u["cache_creation_input_tokens"] as? Int) ?? 0)
            + ((u["cache_read_input_tokens"] as? Int) ?? 0)
            + ((u["output_tokens"] as? Int) ?? 0)
        let usable = model.contains("sonnet") ? curLimit - 33_000 : curLimit
        fuel = max(0, 100 - Int((100.0 * Double(tot) / Double(usable)).rounded()))
        return
    }
    if lines.count < 20 && cand.isEmpty { fuel = 100 }
}

// ================= usage limits (OAuth endpoint; token from Keychain or file) =================
func claudeToken() -> String? {
    // file first, then macOS Keychain ("Claude Code-credentials")
    let credFile = HOME.appendingPathComponent(".claude/.credentials.json")
    if let d = try? Data(contentsOf: credFile),
       let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
       let o = j["claudeAiOauth"] as? [String: Any],
       let t = o["accessToken"] as? String { return t }
    let p = Process()
    p.launchPath = "/usr/bin/security"
    p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    if let s = String(data: data, encoding: .utf8),
       let jd = s.data(using: .utf8),
       let j = try? JSONSerialization.jsonObject(with: jd) as? [String: Any],
       let o = j["claudeAiOauth"] as? [String: Any],
       let t = o["accessToken"] as? String { return t }
    return nil
}

var lastLimitFetch: Date = .distantPast
func fetchLimits(_ done: @escaping () -> Void) {
    if Date().timeIntervalSince(lastLimitFetch) < 300 { return }   // 5-min cache
    lastLimitFetch = Date()
    guard let tok = claudeToken(),
          let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { return }
    var req = URLRequest(url: url, timeoutInterval: 8)
    req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    URLSession.shared.dataTask(with: req) { data, _, _ in
        guard let data = data,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let h = j["five_hour"] as? [String: Any], let u = h["utilization"] as? Double { lim5h = Int(u.rounded()) }
        if let w = j["seven_day"] as? [String: Any], let u = w["utilization"] as? Double { limWk = Int(u.rounded()) }
        DispatchQueue.main.async { done() }
    }.resume()
}

// ================= drawing helpers =================
func roundRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
}
func fillRR(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, _ color: NSColor) {
    color.setFill(); roundRect(x, y, w, h, r).fill()
}
func drawText(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ color: NSColor, bold: Bool = true, font: String = "Menlo") {
    let f = NSFont(name: bold ? "\(font)-Bold" : font, size: size) ?? NSFont.systemFont(ofSize: size)
    let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: color]
    s.draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
}
func textWidth(_ s: String, _ size: CGFloat, bold: Bool = true, font: String = "Menlo") -> CGFloat {
    let f = NSFont(name: bold ? "\(font)-Bold" : font, size: size) ?? NSFont.systemFont(ofSize: size)
    return (s as NSString).size(withAttributes: [.font: f]).width
}
func drawGlow(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ color: NSColor) {
    let glow = color.withAlphaComponent(0.28)
    for o in [(-1,0),(1,0),(0,-1),(0,1),(-1,-1),(1,1)] {
        drawText(s, x + CGFloat(o.0), y + CGFloat(o.1), size, glow)
    }
    drawText(s, x, y, size, color)
}

// ================= the whole GUI is one flipped view =================
class RedlineView: NSView {
    var knob = NEUT
    var dragging = false
    override var isFlipped: Bool { true }   // top-left origin, matches the Windows port

    // convert a window-content point to shifter-panel local (panel starts at y=SHIFT_ORIGIN_Y)
    func inShifter(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: p.y - SHIFT_ORIGIN_Y) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let W = bounds.width
        // background
        NSGradient(colors: [C(30,30,36), C(10,10,13)])?.draw(in: bounds, angle: -90)

        // ---- header ----
        C(220,70,70).setFill(); NSBezierPath(ovalIn: NSRect(x:10,y:10,width:8,height:8)).fill()
        drawText("REDLINE", 24, 6, 12, C(190,190,198))

        // ---- target readout ----
        drawText(targetLabel, 20, 30, 9, C(120,230,150))

        // ---- tach + gear panel ----
        drawDash()

        // ---- fuel gauge ----
        drawFuel()

        // ---- shifter disc ----
        drawShifter(ctx)

        // ---- effort levers ----
        drawLevers()

        // ---- NOS ----
        drawNOS()

        // ---- usage bars ----
        drawBar(W-68, "5H", lim5h)
        drawBar(W-34, "WK", limWk)
    }

    func drawDash() {
        let x: CGFloat = 16, y: CGFloat = 52, w: CGFloat = 208, h: CGFloat = 100
        fillRR(x, y, w, h, 14, C(28,28,34))
        C(60,60,68).setStroke(); roundRect(x, y, w, h, 14).stroke()
        // big gear digit + name
        let gid = curGear ?? "N"
        let gnm = curGear.flatMap { g in GEARS.first { $0.id == g }?.name } ?? "NEUTRAL"
        let green = C(110,240,150)
        drawGlow(gid, x + w - 40, y + 6, 30, green)
        drawGlow(gnm, x + w - 8 - textWidth(gnm, 10), y + 46, 10, green)
        // breadcrumb
        fillRR(x+6, y+70, 196, 22, 6, C(8,8,10))
        drawText(lastCmd ?? "awaiting shift...", x+12, y+73, 8, C(0,220,150), bold: false)
    }

    func drawFuel() {
        let x: CGFloat = 16, y: CGFloat = 162, w: CGFloat = 208
        drawText("FUEL // CONTEXT REMAINING", x, y, 8, C(140,140,148))
        let tankTxt = curLimit >= 1_000_000 ? "1M TANK" : "200K TANK"
        drawText(tankTxt, x + w - textWidth(tankTxt, 8) - 4, y, 8, C(120,200,255))
        // track
        fillRR(x, y+16, 204, 20, 9, C(20,20,24))
        C(55,55,62).setStroke(); roundRect(x, y+16, 204, 20, 9).stroke()
        if let fu = fuel {
            let fw = max(4, CGFloat(198 * fu / 100))
            let (c1, c2) = fu > 50 ? (C(70,210,110), C(130,240,160))
                         : fu > 20 ? (C(220,150,40), C(250,190,90))
                         :           (C(200,40,50),  C(240,90,90))
            NSGradient(colors: [c1, c2])?.draw(in: roundRect(x+3, y+19, fw, 14, 6), angle: -90)
            _ = c2
            drawText("\(fu)%", x+168, y+19, 9, .white)
        } else {
            drawText("--", x+96, y+19, 9, .gray)
        }
    }

    func drawShifter(_ ctx: CGContext) {
        let oy = SHIFT_ORIGIN_Y
        let cx: CGFloat = 120, cy = oy + 124, R: CGFloat = 104
        // chrome disc
        let disc = NSRect(x: cx-R, y: cy-R, width: 2*R, height: 2*R)
        let chrome = NSGradient(colors: [C(95,97,103), C(235,236,240), C(160,162,168), C(110,112,118)])
        chrome?.draw(in: NSBezierPath(ovalIn: disc), angle: 35)
        C(35,35,40).setStroke(); NSBezierPath(ovalIn: disc).stroke()
        // etched H slots
        let slot = NSBezierPath()
        slot.lineWidth = 15; slot.lineCapStyle = .round
        C(30,30,35).setStroke()
        for c in COLS { slot.move(to: CGPoint(x: c, y: oy+ROWY[0])); slot.line(to: CGPoint(x: c, y: oy+ROWY[1])) }
        slot.move(to: CGPoint(x: COLS[0], y: oy+NEUT.y)); slot.line(to: CGPoint(x: COLS[2], y: oy+NEUT.y))
        slot.stroke()
        // gate dimples + chips
        for g in GEARS {
            let gx = COLS[g.col], gy = oy + ROWY[g.row]
            C(16,16,20).setFill(); NSBezierPath(ovalIn: NSRect(x: gx-4, y: gy-4, width: 8, height: 8)).fill()
            let active = curGear == g.id
            let txt = "\(g.id) \(g.name)"
            let tw = textWidth(txt, 8) + 8
            var chipX = gx - tw/2
            chipX = max(2, min(chipX, bounds.width - tw))
            let chipY = g.row == 0 ? gy - 34 : gy + 19
            fillRR(chipX, chipY, tw, 15, 7, C(12,12,15, 235))
            (active ? C(90,235,140) : C(70,70,78)).setStroke()
            roundRect(chipX, chipY, tw, 15, 7).stroke()
            let col = active ? C(120,245,165) : C(185,185,192)
            if active { drawGlow(txt, chipX + (tw - textWidth(txt,8))/2, chipY+2, 8, col) }
            else { drawText(txt, chipX + (tw - textWidth(txt,8))/2, chipY+2, 8, col) }
        }
        // knob
        let kb = NSRect(x: knob.x-KR, y: oy+knob.y-KR, width: 2*KR, height: 2*KR)
        C(0,0,0,90).setFill(); NSBezierPath(ovalIn: kb.offsetBy(dx:0,dy:3)).fill()
        NSGradient(colors: [C(255,255,255), C(80,82,90)])?.draw(in: NSBezierPath(ovalIn: kb), relativeCenterPosition: NSPoint(x: -0.3, y: -0.3))
        C(25,25,30).setStroke(); NSBezierPath(ovalIn: kb).stroke()
    }

    func drawLevers() {
        let ox: CGFloat = 8, oy: CGFloat = 522
        for (i, lv) in EFFORTS.enumerated() {
            let y = oy + CGFloat(i*24)
            let on = effort == lv.cmd
            fillRR(ox+2, y+3, 20, 18, 4, C(50,50,58))
            C(150,152,160).setFill(); NSBezierPath(ovalIn: NSRect(x: ox+8, y: y+8, width: 8, height: 8)).fill()
            let px = ox+12, py = y+12
            let tipY = on ? py-8 : py+8
            let lever = NSBezierPath(); lever.lineWidth = 3; lever.lineCapStyle = .round
            C(210,212,218).setStroke(); lever.move(to: CGPoint(x: px, y: py)); lever.line(to: CGPoint(x: px, y: tipY)); lever.stroke()
            C(235,236,240).setFill(); NSBezierPath(ovalIn: NSRect(x: px-3, y: tipY-3, width: 6, height: 6)).fill()
            let col = on ? C(110,240,150) : C(110,110,118)
            if on { drawGlow(lv.lbl, ox+26, y+7, 8, col) } else { drawText(lv.lbl, ox+26, y+7, 8, col) }
        }
    }

    func drawNOS() {
        let bx: CGFloat = 75+23, by: CGFloat = 522+16, bw: CGFloat = 44, bh: CGFloat = 64
        NSGradient(colors: [C(25,60,110), C(140,190,235), C(18,45,85)])?.draw(in: roundRect(bx, by, bw, bh, 18), angle: 0)
        C(15,15,20).setStroke(); roundRect(bx, by, bw, bh, 18).stroke()
        let oval = NSRect(x: bx+2, y: by+bh*0.34, width: bw-4, height: bh*0.30)
        NSGradient(colors: [C(225,35,45), C(140,10,20)])?.draw(in: NSBezierPath(ovalIn: oval), angle: -90)
        .white.setStroke(); NSBezierPath(ovalIn: oval).stroke()
        drawText("NOS", bx + (bw - textWidth("NOS",9))/2, by+bh*0.36, 9, .white)
        let cap = purge > 0 ? ">> PURGE <<" : "PURGE // /fast"
        drawText(cap, 120 - textWidth(cap,7)/2, 522+86, 7, purge>0 ? C(120,220,255) : C(110,110,118))
    }

    func drawBar(_ x: CGFloat, _ label: String, _ val: Int?) {
        let oy: CGFloat = 522
        drawText(label, x + 14 - textWidth(label,7)/2, oy, 7, C(140,140,148))
        fillRR(x+5, oy+14, 18, 62, 8, C(18,18,22))
        C(55,55,62).setStroke(); roundRect(x+5, oy+14, 18, 62, 8).stroke()
        if let v = val {
            let h = max(3, CGFloat(56 * v / 100))
            let (c1,c2) = v < 50 ? (C(70,210,110),C(130,240,160)) : v < 80 ? (C(220,150,40),C(250,190,90)) : (C(200,40,50),C(240,90,90))
            NSGradient(colors: [c2, c1])?.draw(in: roundRect(x+8, oy+14+56-h+3, 12, h, 5), angle: -90)
            drawText("\(v)%", x + 14 - textWidth("\(v)%",7)/2, oy+80, 7, C(190,190,198))
        } else {
            drawText("--", x+14 - textWidth("--",7)/2, oy+80, 7, .gray)
        }
    }

    // ---- mouse: drag the knob within the shifter panel ----
    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        // levers
        if p.x >= 8 && p.x <= 70 && p.y >= 522 && p.y <= 618 {
            let i = Int((p.y - 522) / 24)
            if i >= 0 && i < EFFORTS.count {
                let lv = EFFORTS[i]
                if effort != lv.cmd, sendToTerminal("/effort \(lv.cmd)") { effort = lv.cmd; lastCmd = "/effort \(lv.cmd)"; needsDisplay = true }
            }
            return
        }
        // NOS
        if p.x >= 75 && p.x <= 165 && p.y >= 522 && p.y <= 618 {
            if sendToTerminal("/fast") { purge = 8; lastCmd = "/fast"; needsDisplay = true }
            return
        }
        // knob
        let s = inShifter(p)
        let dx = s.x - knob.x, dy = s.y - knob.y
        if dx*dx + dy*dy <= KR*KR*2.5 { dragging = true }
    }
    override func mouseDragged(with e: NSEvent) {
        guard dragging else { return }
        let s = inShifter(convert(e.locationInWindow, from: nil))
        var x = s.x, y = s.y
        if abs(y - NEUT.y) < 22 { x = max(COLS[0], min(COLS[2], x)); y = NEUT.y }
        else {
            var near = COLS[0]; for c in COLS where abs(x-c) < abs(x-near) { near = c }
            x = near; y = max(ROWY[0], min(ROWY[1], y))
        }
        knob = CGPoint(x: x, y: y); needsDisplay = true
    }
    override func mouseUp(with e: NSEvent) {
        guard dragging else { return }
        dragging = false
        var hit: Gear? = nil
        for g in GEARS {
            let dx = knob.x - COLS[g.col], dy = knob.y - ROWY[g.row]
            if dx*dx + dy*dy < 1600 { hit = g; break }
        }
        if let g = hit {
            knob = CGPoint(x: COLS[g.col], y: ROWY[g.row])
            if sendToTerminal("/model \(g.cmd)") {
                curGear = g.id; lastCmd = "/model \(g.cmd)"; curLimit = tank(g.cmd)
            }
        } else {
            knob = NEUT
        }
        needsDisplay = true
    }
}

// ---- purge animation counter ----
var purge = 0

// ---- target label: last terminal app that was frontmost ----
var targetLabel = "TARGET: (focus a terminal)"

// ================= app bootstrap =================
let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no dock icon; panel won't steal focus

let panel = NSPanel(
    contentRect: NSRect(x: 60, y: 200, width: 240, height: 640),
    styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
    backing: .buffered, defer: false)
panel.title = "REDLINE"
panel.level = .floating
panel.isFloatingPanel = true
panel.hidesOnDeactivate = false

let view = RedlineView(frame: NSRect(x: 0, y: 0, width: 240, height: 640))
panel.contentView = view
panel.makeKeyAndOrderFront(nil)

// track the last terminal app that was frontmost (so we write to the right one)
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
    guard let appl = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
    let bid = appl.bundleIdentifier ?? ""
    if bid == "com.googlecode.iterm2" || bid == "com.apple.Terminal" {
        targetLabel = "TARGET: \(appl.localizedName ?? bid)"
        view.needsDisplay = true
    }
}

// refresh timer: fuel every 5s, limits every 5min, purge animation
Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
    if purge > 0 { purge -= 1; view.needsDisplay = true }
}
Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
    updateFuel()
    fetchLimits { view.needsDisplay = true }
    view.needsDisplay = true
}
updateFuel()
fetchLimits { view.needsDisplay = true }

app.run()
