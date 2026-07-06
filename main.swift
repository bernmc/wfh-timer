// WFH Timer — inconspicuous menu bar timer for work-from-home hours.
// Records sessions to a CSV on Synology Drive; generates BAS-quarter / AU-FY reports.
// Built by build.sh (no Xcode project). See README.md.

import AppKit
import CoreGraphics
import ServiceManagement

// MARK: - Configuration

// Records live in ~/Documents/WFH Timer by default; changeable from the menu
// ("Choose Data Folder…"), stored in UserDefaults.
let defaultDataDir = ("~/Documents/WFH Timer" as NSString).expandingTildeInPath
var dataDir: String {
    UserDefaults.standard.string(forKey: "dataFolder") ?? defaultDataDir
}
var csvPath: String { dataDir + "/wfh_hours.csv" }
var statePath: String { dataDir + "/.current_session.json" }
var reportsDir: String { dataDir + "/reports" }

let idleThreshold: TimeInterval = 30 * 60      // offer to deduct after 30 min without input
let sleepThreshold: TimeInterval = 5 * 60      // offer to deduct sleeps longer than 5 min
let nudgeAfter: TimeInterval = 6 * 60 * 60     // soft warning after 6 h continuous

// MARK: - Formatting helpers

func makeFormatter(_ fmt: String) -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = fmt
    return f
}
let dateFmt = makeFormatter("yyyy-MM-dd")   // internal/CSV format (sortable)
let auDateFmt = makeFormatter("dd/MM/yyyy") // all user-facing display and entry
let timeFmt = makeFormatter("HH:mm")
let monthFmt = makeFormatter("yyyy-MM")
let monthLabelFmt = makeFormatter("MMMM yyyy")
let stampFmt = makeFormatter("d MMM yyyy, HH:mm")

func hm(_ t: TimeInterval) -> String {
    let m = Int((t / 60).rounded())
    return "\(m / 60) h \(String(format: "%02d", m % 60)) m"
}
func hmMinutes(_ minutes: Int) -> String {
    "\(minutes / 60) h \(String(format: "%02d", minutes % 60)) m"
}
func hmShort(_ t: TimeInterval) -> String {
    let m = Int(t / 60)
    return "\(m / 60):" + String(format: "%02d", m % 60)
}
func hms(_ t: TimeInterval) -> String {
    let s = Int(t)
    return "\(s / 3600):" + String(format: "%02d:%02d", (s % 3600) / 60, s % 60)
}
func decimalHours(_ minutes: Int) -> String {
    String(format: "%.2f", Double(minutes) / 60.0)
}

// Display an internal yyyy-MM-dd date as DD/MM/YYYY.
func auDate(_ iso: String) -> String {
    dateFmt.date(from: iso).map { auDateFmt.string(from: $0) } ?? iso
}

// Accept Australian date entry: 5/7/2026, 05/07/2026, 5-7-26, 5.7, 5/7 (current year),
// plus ISO yyyy-mm-dd. Returns internal yyyy-MM-dd, or nil for nonsense (incl. 31/02).
func parseFlexibleDate(_ raw: String) -> String? {
    let parts = raw.trimmingCharacters(in: .whitespaces)
        .components(separatedBy: CharacterSet(charactersIn: "/-."))
        .filter { !$0.isEmpty }
    let cal = Calendar.current
    var d: Int?, m: Int?, y: Int?
    switch parts.count {
    case 3:
        if parts[0].count == 4 { y = Int(parts[0]); m = Int(parts[1]); d = Int(parts[2]) }
        else {
            d = Int(parts[0]); m = Int(parts[1]); y = Int(parts[2])
            if parts[2].count == 2, let yy = y { y = 2000 + yy }
        }
    case 2:
        d = Int(parts[0]); m = Int(parts[1]); y = cal.component(.year, from: Date())
    default:
        return nil
    }
    guard let dd = d, let mm = m, let yy = y,
          (1...31).contains(dd), (1...12).contains(mm), (2000...2100).contains(yy),
          let date = cal.date(from: DateComponents(year: yy, month: mm, day: dd)),
          cal.component(.day, from: date) == dd,
          cal.component(.month, from: date) == mm else { return nil }
    return dateFmt.string(from: date)
}

// Accept shorthand times: "9" / "14" → on the hour, "0930" / "1430" → HHMM,
// "9:30" / "9.30" / "14:30" → as given. Rejects ambiguous 3-digit ("140") and
// out-of-range values. Returns normalised "HH:mm".
func parseFlexibleTime(_ raw: String) -> String? {
    let s = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: ":")
    var h = -1, m = -1
    if s.contains(":") {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1].count == 2,
              let hh = Int(parts[0]), let mm = Int(parts[1]) else { return nil }
        h = hh; m = mm
    } else {
        guard !s.isEmpty, s.allSatisfy({ $0.isNumber }) else { return nil }
        switch s.count {
        case 1, 2: h = Int(s)!; m = 0
        case 4:    h = Int(s.prefix(2))!; m = Int(s.suffix(2))!
        default:   return nil
        }
    }
    guard (0...23).contains(h), (0...59).contains(m) else { return nil }
    return String(format: "%02d:%02d", h, m)
}

// MARK: - Data model & CSV

struct Session {
    var date: String   // yyyy-MM-dd (date the session started)
    var start: String  // HH:mm
    var stop: String   // HH:mm
    var minutes: Int
    var note: String
}

func csvEscape(_ s: String) -> String {
    if s.contains(",") || s.contains("\"") || s.contains("\n") {
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    return s
}

func parseCSVLine(_ line: String) -> [String] {
    var fields: [String] = []
    var cur = ""
    var inQuotes = false
    var i = line.startIndex
    while i < line.endIndex {
        let c = line[i]
        if inQuotes {
            if c == "\"" {
                let next = line.index(after: i)
                if next < line.endIndex && line[next] == "\"" { cur.append("\""); i = next }
                else { inQuotes = false }
            } else { cur.append(c) }
        } else {
            if c == "\"" { inQuotes = true }
            else if c == "," { fields.append(cur); cur = "" }
            else { cur.append(c) }
        }
        i = line.index(after: i)
    }
    fields.append(cur)
    return fields
}

func ensureCSV() {
    if !FileManager.default.fileExists(atPath: csvPath) {
        try? "date,start,stop,duration_min,note\n".write(toFile: csvPath, atomically: true, encoding: .utf8)
    }
}

func loadSessions() -> [Session] {
    guard let text = try? String(contentsOfFile: csvPath, encoding: .utf8) else { return [] }
    var out: [Session] = []
    for (i, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
        if i == 0 { continue } // header
        let line = String(rawLine).trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        let f = parseCSVLine(line)
        if f.count >= 4, let m = Int(f[3].trimmingCharacters(in: .whitespaces)) {
            out.append(Session(date: f[0], start: f[1], stop: f[2], minutes: m,
                               note: f.count > 4 ? f[4] : ""))
        }
    }
    return out
}

func appendSession(_ s: Session) {
    ensureCSV()
    let line = "\(s.date),\(s.start),\(s.stop),\(s.minutes),\(csvEscape(s.note))\n"
    if let h = FileHandle(forWritingAtPath: csvPath) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        h.closeFile()
    }
}

// MARK: - Australian FY periods

struct Period {
    let label: String
    let from: String   // yyyy-MM-dd inclusive
    let to: String     // yyyy-MM-dd inclusive
}

func fyLabel(startYear fy: Int) -> String {
    "FY\(fy)-" + String(format: "%02d", (fy + 1) % 100)
}

// Quarter label for a session date: Q1 = Jul–Sep, Q2 = Oct–Dec, Q3 = Jan–Mar, Q4 = Apr–Jun.
func fyQuarterLabel(_ d: String) -> String {
    let y = Int(d.prefix(4)) ?? 0
    let m = Int(d.dropFirst(5).prefix(2)) ?? 1
    let fy = m >= 7 ? y : y - 1
    let q = m >= 7 ? (m - 7) / 3 + 1 : (m - 1) / 3 + 3
    return "Q\(q) " + fyLabel(startYear: fy)
}

func quarterPeriod(offset: Int) -> Period {
    let cal = Calendar.current
    let now = Date()
    let y = cal.component(.year, from: now)
    let m = cal.component(.month, from: now)
    let startMonth = m >= 7 ? ((m - 7) / 3) * 3 + 7 : ((m - 1) / 3) * 3 + 1
    var startDate = cal.date(from: DateComponents(year: y, month: startMonth, day: 1))!
    if offset != 0 { startDate = cal.date(byAdding: .month, value: 3 * offset, to: startDate)! }
    let endDate = cal.date(byAdding: DateComponents(month: 3, day: -1), to: startDate)!
    return Period(label: fyQuarterLabel(dateFmt.string(from: startDate)),
                  from: dateFmt.string(from: startDate),
                  to: dateFmt.string(from: endDate))
}

func fyPeriod(offset: Int) -> Period {
    let cal = Calendar.current
    let now = Date()
    let y = cal.component(.year, from: now)
    let m = cal.component(.month, from: now)
    let fy = (m >= 7 ? y : y - 1) + offset
    return Period(label: fyLabel(startYear: fy),
                  from: String(format: "%04d-07-01", fy),
                  to: String(format: "%04d-06-30", fy + 1))
}

// MARK: - Report generation (printable HTML)

func htmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
     .replacingOccurrences(of: "<", with: "&lt;")
     .replacingOccurrences(of: ">", with: "&gt;")
}

func generateReport(_ p: Period) -> String {
    let sessions = loadSessions()
        .filter { $0.date >= p.from && $0.date <= p.to }
        .sorted { ($0.date, $0.start) < ($1.date, $1.start) }
    let totalMin = sessions.reduce(0) { $0 + $1.minutes }
    let days = Set(sessions.map { $0.date }).count

    var html = """
    <!DOCTYPE html><html><head><meta charset="utf-8">
    <title>WFH Hours — \(htmlEscape(p.label))</title>
    <style>
      body { font-family: -apple-system, Helvetica, sans-serif; margin: 40px auto; max-width: 760px; color: #1a1a1a; }
      h1 { font-size: 22px; margin-bottom: 2px; }
      h2 { font-size: 15px; margin-top: 28px; border-bottom: 1px solid #ccc; padding-bottom: 4px; }
      .meta { color: #666; font-size: 12px; margin-top: 0; }
      .total { background: #f2f6ff; border: 1px solid #c8d8f8; border-radius: 8px; padding: 12px 16px; font-size: 15px; margin: 18px 0; }
      table { border-collapse: collapse; width: 100%; font-size: 12.5px; }
      th, td { border: 1px solid #ddd; padding: 5px 8px; text-align: left; }
      th { background: #f5f5f5; }
      td.num, th.num { text-align: right; font-variant-numeric: tabular-nums; }
      .tip { color: #888; font-size: 11px; margin-top: 30px; }
      @media print { .tip { display: none; } body { margin: 0; } }
    </style></head><body>
    <h1>Work-from-home hours — \(htmlEscape(p.label))</h1>
    <p class="meta">Period \(auDate(p.from)) to \(auDate(p.to)) · Generated \(stampFmt.string(from: Date())) · Source: wfh_hours.csv</p>
    """

    if sessions.isEmpty {
        html += "<div class='total'>No sessions recorded in this period.</div>"
    } else {
        html += """
        <div class="total"><b>Total: \(hmMinutes(totalMin)) (\(decimalHours(totalMin)) hours)</b>
        &nbsp;·&nbsp; \(sessions.count) sessions over \(days) days</div>
        """

        // Monthly totals
        let byMonth = Dictionary(grouping: sessions) { String($0.date.prefix(7)) }
        html += "<h2>Monthly totals</h2><table><tr><th>Month</th><th class='num'>Sessions</th><th class='num'>Hours (h:mm)</th><th class='num'>Hours (decimal)</th></tr>"
        for key in byMonth.keys.sorted() {
            let ss = byMonth[key]!
            let mins = ss.reduce(0) { $0 + $1.minutes }
            let label = monthFmt.date(from: key).map { monthLabelFmt.string(from: $0) } ?? key
            html += "<tr><td>\(label)</td><td class='num'>\(ss.count)</td><td class='num'>\(hmMinutes(mins))</td><td class='num'>\(decimalHours(mins))</td></tr>"
        }
        html += "<tr><th>Total</th><th class='num'>\(sessions.count)</th><th class='num'>\(hmMinutes(totalMin))</th><th class='num'>\(decimalHours(totalMin))</th></tr></table>"

        // Quarterly totals when the period spans more than one quarter
        let byQuarter = Dictionary(grouping: sessions) { fyQuarterLabel($0.date) }
        if byQuarter.count > 1 {
            html += "<h2>Quarterly totals (BAS)</h2><table><tr><th>Quarter</th><th class='num'>Sessions</th><th class='num'>Hours (h:mm)</th><th class='num'>Hours (decimal)</th></tr>"
            let ordered = byQuarter.keys.sorted { a, b in
                (byQuarter[a]!.first!.date) < (byQuarter[b]!.first!.date)
            }
            for key in ordered {
                let ss = byQuarter[key]!
                let mins = ss.reduce(0) { $0 + $1.minutes }
                html += "<tr><td>\(key)</td><td class='num'>\(ss.count)</td><td class='num'>\(hmMinutes(mins))</td><td class='num'>\(decimalHours(mins))</td></tr>"
            }
            html += "</table>"
        }

        // Session detail
        html += "<h2>Session detail</h2><table><tr><th>Date</th><th>Start</th><th>Stop</th><th class='num'>Minutes</th><th class='num'>Hours</th><th>Note</th></tr>"
        for s in sessions {
            html += "<tr><td>\(auDate(s.date))</td><td>\(s.start)</td><td>\(s.stop)</td><td class='num'>\(s.minutes)</td><td class='num'>\(decimalHours(s.minutes))</td><td>\(htmlEscape(s.note))</td></tr>"
        }
        html += "</table>"
    }

    html += "<p class='tip'>To save as PDF: File ▸ Print ▸ Save as PDF.</p></body></html>"
    return html
}

// MARK: - Analogue clock view

// A live clock face. While a session runs, a coloured wedge follows the MINUTE hand
// (60-min dial) clockwise from the start time — 5 minutes reads as a visible 30° slice.
// Each completed hour tints the whole face; the current partial hour sits deeper on top.
final class ClockView: NSView {
    var sessionStart: Date?

    private func minuteAngle(for date: Date) -> CGFloat {
        let cal = Calendar.current
        let m = Double(cal.component(.minute, from: date))
        let s = Double(cal.component(.second, from: date))
        return CGFloat(90 - ((m + s / 60) / 60) * 360)
    }

    private func point(angle deg: CGFloat, radius: CGFloat, center: CGPoint) -> CGPoint {
        let rad = deg * .pi / 180
        return CGPoint(x: center.x + cos(rad) * radius, y: center.y + sin(rad) * radius)
    }

    private func drawHand(angle: CGFloat, length: CGFloat, width: CGFloat, color: NSColor, center: CGPoint) {
        let p = NSBezierPath()
        p.move(to: center)
        p.line(to: point(angle: angle, radius: length, center: center))
        p.lineWidth = width
        p.lineCapStyle = .round
        color.setStroke()
        p.stroke()
    }

    private func drawCenteredText(_ s: String, at p: CGPoint, font: NSFont, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (s as NSString).size(withAttributes: attrs)
        (s as NSString).draw(at: NSPoint(x: p.x - size.width / 2, y: p.y - size.height / 2),
                             withAttributes: attrs)
    }

    private func tickLine(from p1: CGPoint, to p2: CGPoint, dy: CGFloat, width: CGFloat, color: NSColor) {
        let p = NSBezierPath()
        p.move(to: CGPoint(x: p1.x, y: p1.y + dy))
        p.line(to: CGPoint(x: p2.x, y: p2.y + dy))
        p.lineWidth = width
        p.lineCapStyle = .round
        color.setStroke()
        p.stroke()
    }

    // Engraving is drawn in two passes so the elapsed arc can slide between them:
    // groove (dark slot shifted up = shadowed upper lip, plus a faint light catch on
    // the lower edge) goes UNDER the arc; the bright mark face goes OVER it.
    private func tickGroove(from p1: CGPoint, to p2: CGPoint, width: CGFloat) {
        tickLine(from: p1, to: p2, dy: 1.6, width: width + 2.6,
                 color: NSColor.black.withAlphaComponent(0.95))
        tickLine(from: p1, to: p2, dy: -1.9, width: width + 1.0,
                 color: NSColor.white.withAlphaComponent(0.20))
    }

    private func tickFace(from p1: CGPoint, to p2: CGPoint, width: CGFloat, bright: NSColor) {
        tickLine(from: p1, to: p2, dy: -0.6, width: width, color: bright)
    }

    private func engravedText(_ s: String, at p: CGPoint, font: NSFont, bright: NSColor) {
        drawCenteredText(s, at: CGPoint(x: p.x, y: p.y + 1.5), font: font,
                         color: NSColor.black.withAlphaComponent(0.95))
        drawCenteredText(s, at: CGPoint(x: p.x, y: p.y - 1.7), font: font,
                         color: NSColor.white.withAlphaComponent(0.20))
        drawCenteredText(s, at: CGPoint(x: p.x, y: p.y - 0.4), font: font, color: bright)
    }

    override func draw(_ dirtyRect: NSRect) {
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let r = min(bounds.width, bounds.height) / 2 - 6
        let faceRect = NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        let bezelW: CGFloat = 3
        let innerRect = faceRect.insetBy(dx: bezelW, dy: bezelW)
        let innerR = r - bezelW

        // Bezel — glossy black ring with a light catch on the lower lip.
        let ringPath = NSBezierPath(ovalIn: faceRect)
        ringPath.append(NSBezierPath(ovalIn: innerRect).reversed)
        NSGradient(starting: NSColor.black.withAlphaComponent(0.95),
                   ending: NSColor.white.withAlphaComponent(0.30))?
            .draw(in: ringPath, angle: -90)

        // Face — always-dark Garmin-style dial, light drifting to the upper half.
        NSGradient(starting: NSColor(white: 0.17, alpha: 1),
                   ending: NSColor(white: 0.04, alpha: 1))?
            .draw(in: NSBezierPath(ovalIn: innerRect), relativeCenterPosition: NSPoint(x: 0, y: 0.25))

        // Soft inner shadow from the top rim keeps the recessed feel.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: innerRect).addClip()
        let innerShadow = NSShadow()
        innerShadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        innerShadow.shadowBlurRadius = 8
        innerShadow.shadowOffset = NSSize(width: 0, height: -5)
        innerShadow.set()
        let donut = NSBezierPath(ovalIn: innerRect.insetBy(dx: -24, dy: -24))
        donut.append(NSBezierPath(ovalIn: innerRect).reversed)
        NSColor.black.setFill()
        donut.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Layer 1 of the minute track: engraved grooves (under the arc).
        for i in 0..<60 {
            let a = CGFloat(90 - i * 6)
            let five = i % 5 == 0
            tickGroove(from: point(angle: a, radius: innerR * (five ? 0.865 : 0.905), center: c),
                       to: point(angle: a, radius: innerR * 0.965, center: c),
                       width: five ? 2 : 1)
        }

        // Elapsed time as a red-orange rim arc (Garmin style): the current partial
        // hour sweeps with the minute hand; a completed hour leaves a dim full ring.
        // Sits between the grooves and the bright tick faces, so the band stays solid
        // while the marks remain visible across it.
        if let start = sessionStart {
            let elapsed = Date().timeIntervalSince(start)
            let arcR = innerR * 0.93
            let arcColor = NSColor(calibratedRed: 1.0, green: 0.27, blue: 0.10, alpha: 1)
            if elapsed >= 3600 {
                let full = NSBezierPath(ovalIn: NSRect(x: c.x - arcR, y: c.y - arcR,
                                                       width: 2 * arcR, height: 2 * arcR))
                full.lineWidth = 6
                arcColor.withAlphaComponent(0.30).setStroke()
                full.stroke()
            }
            let sweep = CGFloat(elapsed.truncatingRemainder(dividingBy: 3600) / 3600 * 360)
            if sweep > 0.5 {
                let a0 = minuteAngle(for: start)
                let arc = NSBezierPath()
                arc.appendArc(withCenter: c, radius: arcR, startAngle: a0,
                              endAngle: a0 - sweep, clockwise: true)
                arc.lineWidth = 6
                arcColor.setStroke()
                arc.stroke()
            }
        }

        // Layer 2 of the minute track: bright mark faces (over the arc) + numerals.
        for i in 0..<60 {
            let a = CGFloat(90 - i * 6)
            let five = i % 5 == 0
            tickFace(from: point(angle: a, radius: innerR * (five ? 0.865 : 0.905), center: c),
                     to: point(angle: a, radius: innerR * 0.965, center: c),
                     width: five ? 2 : 1,
                     bright: NSColor(white: five ? 0.90 : 0.62, alpha: 1))
        }
        let numFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        for i in stride(from: 5, through: 60, by: 5) {
            let a = CGFloat(90 - i * 6)
            engravedText(String(format: "%02d", i == 60 ? 60 : i),
                         at: point(angle: a, radius: innerR * 0.75, center: c),
                         font: numFont, bright: NSColor(white: 0.92, alpha: 1))
        }

        // Hairline around the outside.
        let outline = NSBezierPath(ovalIn: faceRect)
        outline.lineWidth = 1
        NSColor(white: 0.55, alpha: 0.8).setStroke()
        outline.stroke()

        // Hands float just above the dial — soft drop shadow.
        NSGraphicsContext.saveGraphicsState()
        let handShadow = NSShadow()
        handShadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        handShadow.shadowBlurRadius = 3
        handShadow.shadowOffset = NSSize(width: 0, height: -2)
        handShadow.set()
        let now = Date()
        let cal = Calendar.current
        let h = Double(cal.component(.hour, from: now) % 12)
        let m = Double(cal.component(.minute, from: now))
        let s = Double(cal.component(.second, from: now))
        let handColor = NSColor(white: 0.93, alpha: 1)
        drawHand(angle: CGFloat(90 - ((h + m / 60) / 12) * 360), length: innerR * 0.45, width: 5.5, color: handColor, center: c)
        drawHand(angle: CGFloat(90 - ((m + s / 60) / 60) * 360), length: innerR * 0.66, width: 4, color: handColor, center: c)
        drawHand(angle: CGFloat(90 - (s / 60) * 360), length: innerR * 0.80, width: 1.5, color: .systemRed, center: c)

        let hub = NSBezierPath(ovalIn: NSRect(x: c.x - 4.5, y: c.y - 4.5, width: 9, height: 9))
        handColor.setFill()
        hub.fill()
        let hubDot = NSBezierPath(ovalIn: NSRect(x: c.x - 1.5, y: c.y - 1.5, width: 3, height: 3))
        NSColor(white: 0.1, alpha: 1).setFill()
        hubDot.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var statusMenu: NSMenu!
    var tickTimer: Timer?
    var uiTimer: Timer?

    var timerWindow: NSWindow!
    var clockView: ClockView!
    var digitalLabel: NSTextField!
    var windowStatusLabel: NSTextField!
    var startStopButton: NSButton!

    var sessionStart: Date?
    var deducted: TimeInterval = 0
    var nudged = false
    var sleepBegan: Date?
    var idleBegan: Date?

    // MARK: Lifecycle

    func ensureDirs() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: reportsDir, withIntermediateDirectories: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ensureDirs()
        ensureCSV()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        statusMenu = NSMenu()
        statusMenu.delegate = self
        // Left-click toggles the timer window; right-click (or ⌃-click) shows the menu.
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        makeTimerWindow()
        restoreState()
        updateTitle()

        tickTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(tickTimer!, forMode: .common)

        uiTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.timerWindow.isVisible else { return }
            self.updateWindowUI()
        }
        RunLoop.main.add(uiTimer!, forMode: .common)

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    // Reopening the app (Launchpad, Finder, `open -a`) brings up the timer window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showTimerWindow()
        return true
    }

    @objc func statusItemClicked() {
        if let e = NSApp.currentEvent,
           e.type == .rightMouseUp || e.modifierFlags.contains(.control) {
            guard let button = statusItem.button else { return }
            statusMenu.popUp(positioning: nil,
                             at: NSPoint(x: 0, y: button.bounds.height + 5),
                             in: button)
        } else {
            toggleTimerWindow()
        }
    }

    // MARK: Timer window

    func makeTimerWindow() {
        let size = NSSize(width: 264, height: 384)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "WFH Timer"
        w.isReleasedWhenClosed = false
        w.level = UserDefaults.standard.bool(forKey: "alwaysOnTop") ? .floating : .normal
        w.center()

        let content = NSView(frame: NSRect(origin: .zero, size: size))

        clockView = ClockView(frame: NSRect(x: 22, y: 156, width: 220, height: 220))
        content.addSubview(clockView)

        digitalLabel = NSTextField(labelWithString: "0:00:00")
        digitalLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 32, weight: .medium)
        digitalLabel.alignment = .center
        digitalLabel.frame = NSRect(x: 0, y: 100, width: size.width, height: 42)
        content.addSubview(digitalLabel)

        windowStatusLabel = NSTextField(labelWithString: "Not running")
        windowStatusLabel.font = NSFont.systemFont(ofSize: 11)
        windowStatusLabel.textColor = .secondaryLabelColor
        windowStatusLabel.alignment = .center
        windowStatusLabel.frame = NSRect(x: 0, y: 80, width: size.width, height: 16)
        content.addSubview(windowStatusLabel)

        startStopButton = NSButton(title: "Start", target: self, action: #selector(toggleTimer))
        startStopButton.bezelStyle = .rounded
        startStopButton.keyEquivalent = "\r"
        startStopButton.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        startStopButton.frame = NSRect(x: 77, y: 28, width: 110, height: 36)
        content.addSubview(startStopButton)

        let more = NSButton(title: "⋯", target: self, action: #selector(showActionsMenu(_:)))
        more.bezelStyle = .rounded
        more.frame = NSRect(x: 220, y: 31, width: 32, height: 30)
        more.toolTip = "Reports and more"
        content.addSubview(more)

        w.contentView = content
        timerWindow = w
    }

    func showTimerWindow() {
        NSApp.activate(ignoringOtherApps: true)
        updateWindowUI()
        timerWindow.makeKeyAndOrderFront(nil)
    }

    @objc func toggleTimerWindow() {
        if timerWindow.isVisible { timerWindow.orderOut(nil) } else { showTimerWindow() }
    }

    @objc func toggleAlwaysOnTop() {
        let on = !UserDefaults.standard.bool(forKey: "alwaysOnTop")
        UserDefaults.standard.set(on, forKey: "alwaysOnTop")
        timerWindow.level = on ? .floating : .normal
    }

    @objc func showActionsMenu(_ sender: NSButton) {
        statusMenu.popUp(positioning: nil,
                         at: NSPoint(x: 0, y: sender.bounds.height + 4),
                         in: sender)
    }

    func updateWindowUI() {
        if let start = sessionStart {
            let net = max(0, Date().timeIntervalSince(start) - deducted)
            digitalLabel.stringValue = hms(net)
            digitalLabel.textColor = .labelColor
            var status = "Started \(timeFmt.string(from: start))"
            if deducted > 0 { status += " · −\(hm(deducted)) away" }
            if net >= nudgeAfter { status += " ⚠️" }
            windowStatusLabel.stringValue = status
            startStopButton.title = "Stop"
            startStopButton.bezelColor = .systemRed
            clockView.sessionStart = start
        } else {
            digitalLabel.stringValue = "0:00:00"
            digitalLabel.textColor = .tertiaryLabelColor
            windowStatusLabel.stringValue = "Not running"
            startStopButton.title = "Start"
            startStopButton.bezelColor = .systemGreen
            clockView.sessionStart = nil
        }
        clockView.needsDisplay = true
    }

    // MARK: Menu

    func menuItem(_ title: String, _ action: Selector?, _ key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        return it
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()

        if let start = sessionStart {
            let net = max(0, Date().timeIntervalSince(start) - deducted)
            var info = "Running — started \(timeFmt.string(from: start)), \(hm(net))"
            if deducted > 0 { info += " (−\(hm(deducted)) away)" }
            menu.addItem(menuItem(info, nil))
            menu.addItem(menuItem("Stop Timer…", #selector(toggleTimer), "s"))
        } else {
            menu.addItem(menuItem("Start Timer", #selector(toggleTimer), "s"))
        }
        menu.addItem(menuItem("Show Timer Window", #selector(toggleTimerWindow), "w"))
        let pin = menuItem("Keep Window on Top", #selector(toggleAlwaysOnTop))
        pin.state = UserDefaults.standard.bool(forKey: "alwaysOnTop") ? .on : .off
        menu.addItem(pin)
        menu.addItem(.separator())
        menu.addItem(menuItem("Add Past Session…", #selector(addPastSession)))
        menu.addItem(menuItem("Open Data File", #selector(openDataFile)))
        menu.addItem(menuItem("Choose Data Folder…", #selector(chooseDataFolder)))
        menu.addItem(.separator())

        let reports = NSMenuItem(title: "Reports", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.addItem(menuItem("This BAS Quarter", #selector(reportThisQuarter)))
        sub.addItem(menuItem("Last BAS Quarter", #selector(reportLastQuarter)))
        sub.addItem(menuItem("This Financial Year", #selector(reportThisFY)))
        sub.addItem(menuItem("Last Financial Year", #selector(reportLastFY)))
        sub.addItem(.separator())
        sub.addItem(menuItem("Custom Range…", #selector(reportCustomRange)))
        sub.addItem(menuItem("All Time", #selector(reportAllTime)))
        menu.setSubmenu(sub, for: reports)
        menu.addItem(reports)

        menu.addItem(.separator())
        let login = menuItem("Start at Login", #selector(toggleLoginItem))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(menuItem("Quit WFH Timer", #selector(quitApp), "q"))
    }

    // MARK: Status display

    func houseIcon(filled: Bool) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .bold)
        let img = NSImage(systemSymbolName: filled ? "house.fill" : "house",
                          accessibilityDescription: "WFH Timer")?.withSymbolConfiguration(cfg)
        img?.isTemplate = true
        return img
    }

    func updateTitle() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageLeft
        if let start = sessionStart {
            let net = max(0, Date().timeIntervalSince(start) - deducted)
            let warn = net >= nudgeAfter ? " ⚠️" : ""
            button.image = houseIcon(filled: true)
            button.title = " " + hmShort(net) + warn
        } else {
            button.image = houseIcon(filled: false)
            button.title = ""
        }
        if timerWindow != nil { updateWindowUI() }
    }

    func tick() {
        updateTitle()
        guard let start = sessionStart else { idleBegan = nil; return }
        let net = Date().timeIntervalSince(start) - deducted
        if !nudged && net >= nudgeAfter {
            nudged = true
            saveState()
            NSSound(named: "Ping")?.play()
        }
        checkIdle()
    }

    // MARK: Start / stop

    @objc func toggleTimer() {
        if sessionStart == nil {
            sessionStart = Date()
            deducted = 0
            nudged = false
            idleBegan = nil
            saveState()
            updateTitle()
        } else {
            stopFlow()
        }
    }

    func stopFlow() {
        guard let start = sessionStart else { return }
        let stop = Date()
        let net = max(0, stop.timeIntervalSince(start) - deducted)

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Stop timer?"
        alert.informativeText = "Recorded \(hm(net)) (started \(timeFmt.string(from: start)))."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Optional note (what you worked on)"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save Session")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard")
        alert.window.initialFirstResponder = field

        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            let minutes = max(1, Int((net / 60).rounded()))
            appendSession(Session(date: dateFmt.string(from: start),
                                  start: timeFmt.string(from: start),
                                  stop: timeFmt.string(from: stop),
                                  minutes: minutes,
                                  note: field.stringValue))
            clearSession()
        } else if resp == .alertThirdButtonReturn {
            clearSession()
        }
        updateTitle()
    }

    // MARK: Session state persistence (crash / relaunch safety)

    func saveState() {
        guard let start = sessionStart else { return }
        let dict: [String: Any] = ["start": start.timeIntervalSince1970,
                                   "deducted": deducted,
                                   "nudged": nudged]
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            try? data.write(to: URL(fileURLWithPath: statePath))
        }
    }

    func clearSession() {
        sessionStart = nil
        deducted = 0
        nudged = false
        idleBegan = nil
        try? FileManager.default.removeItem(atPath: statePath)
    }

    func restoreState() {
        guard let data = FileManager.default.contents(atPath: statePath),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any],
              let ts = dict["start"] as? Double else { return }
        sessionStart = Date(timeIntervalSince1970: ts)
        deducted = dict["deducted"] as? Double ?? 0
        nudged = dict["nudged"] as? Bool ?? false
    }

    // MARK: Sleep & idle safeguards

    @objc func willSleep() { sleepBegan = Date() }

    @objc func didWake() {
        let began = sleepBegan
        sleepBegan = nil
        idleBegan = nil
        guard sessionStart != nil, let b = began else { return }
        let gap = Date().timeIntervalSince(b)
        if gap >= sleepThreshold {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.promptDeduct(gap: gap,
                                   reason: "Your Mac slept for \(hm(gap)) while the timer was running.")
            }
        }
    }

    func systemIdleSeconds() -> TimeInterval {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
                    .min() ?? 0
    }

    func checkIdle() {
        guard sessionStart != nil else { idleBegan = nil; return }
        let idle = systemIdleSeconds()
        if idle >= idleThreshold {
            if idleBegan == nil { idleBegan = Date().addingTimeInterval(-idle) }
        } else if let began = idleBegan {
            idleBegan = nil
            let gap = Date().timeIntervalSince(began)
            if gap >= idleThreshold {
                promptDeduct(gap: gap,
                             reason: "You were away for \(hm(gap)) while the timer was running.")
            }
        }
    }

    func promptDeduct(gap: TimeInterval, reason: String) {
        guard let start = sessionStart else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Deduct away time?"
        alert.informativeText = reason + " Deduct it from this session?"
        alert.addButton(withTitle: "Deduct \(hm(gap))")
        alert.addButton(withTitle: "Keep It")
        if alert.runModal() == .alertFirstButtonReturn {
            deducted = min(deducted + gap, Date().timeIntervalSince(start))
            saveState()
            updateTitle()
        }
    }

    // MARK: Manual entry

    func labeledField(y: CGFloat, placeholder: String, value: String = "") -> NSTextField {
        let f = NSTextField(frame: NSRect(x: 0, y: y, width: 280, height: 24))
        f.placeholderString = placeholder
        f.stringValue = value
        return f
    }

    @objc func addPastSession() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Add Past Session"
        alert.informativeText = "Date DD/MM/YYYY (or just DD/MM for this year). Times: 9, 0930, 14:30, 9.30 all fine."
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 116))
        let dateField = labeledField(y: 92, placeholder: "Date (DD/MM/YYYY)", value: auDateFmt.string(from: Date()))
        let startField = labeledField(y: 62, placeholder: "Start (e.g. 9 or 0930)")
        let stopField = labeledField(y: 32, placeholder: "Stop (e.g. 12:30 or 1230)")
        let noteField = labeledField(y: 2, placeholder: "Note (optional)")
        for f in [dateField, startField, stopField, noteField] { container.addSubview(f) }
        alert.accessoryView = container
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = dateField

        while true {
            if alert.runModal() != .alertFirstButtonReturn { return }
            guard let isoDate = parseFlexibleDate(dateField.stringValue),
                  let start = parseFlexibleTime(startField.stringValue),
                  let stop = parseFlexibleTime(stopField.stringValue) else {
                alert.informativeText = "⚠️ Couldn't read that. Date like 5/7/2026 or 05/07; "
                    + "times like 9, 0930 or 14:30 (not 3 digits — 140 is ambiguous)."
                continue
            }
            let st = timeFmt.date(from: start)!, en = timeFmt.date(from: stop)!
            var mins = Int(en.timeIntervalSince(st) / 60)
            if mins <= 0 { mins += 24 * 60 }   // session crossed midnight
            appendSession(Session(date: isoDate,
                                  start: start,
                                  stop: stop,
                                  minutes: mins,
                                  note: noteField.stringValue))
            return
        }
    }

    @objc func openDataFile() {
        ensureCSV()
        NSWorkspace.shared.open(URL(fileURLWithPath: csvPath))
    }

    @objc func chooseDataFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose where WFH Timer keeps its records (wfh_hours.csv and reports)."
        panel.directoryURL = URL(fileURLWithPath: dataDir)
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: "dataFolder")
            ensureDirs()
            ensureCSV()
            if sessionStart != nil { saveState() }   // keep a running session with the new folder
        }
    }

    // MARK: Reports

    func runReport(_ p: Period) {
        let html = generateReport(p)
        let safe = p.label.replacingOccurrences(of: " ", with: "_")
                          .replacingOccurrences(of: "/", with: "-")
        let path = reportsDir + "/WFH_Report_\(safe).html"
        do {
            try html.write(toFile: path, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } catch {
            showError("Could not write report: \(error.localizedDescription)")
        }
    }

    @objc func reportThisQuarter() { runReport(quarterPeriod(offset: 0)) }
    @objc func reportLastQuarter() { runReport(quarterPeriod(offset: -1)) }
    @objc func reportThisFY() { runReport(fyPeriod(offset: 0)) }
    @objc func reportLastFY() { runReport(fyPeriod(offset: -1)) }
    @objc func reportAllTime() {
        runReport(Period(label: "All Time", from: "1970-01-01", to: "9999-12-31"))
    }

    @objc func reportCustomRange() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Custom Range Report"
        alert.informativeText = "Dates DD/MM/YYYY, inclusive."
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 56))
        let fromField = labeledField(y: 32, placeholder: "From (DD/MM/YYYY)")
        let toField = labeledField(y: 2, placeholder: "To (DD/MM/YYYY)", value: auDateFmt.string(from: Date()))
        container.addSubview(fromField)
        container.addSubview(toField)
        alert.accessoryView = container
        alert.addButton(withTitle: "Generate")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = fromField

        while true {
            if alert.runModal() != .alertFirstButtonReturn { return }
            guard let fromISO = parseFlexibleDate(fromField.stringValue),
                  let toISO = parseFlexibleDate(toField.stringValue),
                  fromISO <= toISO else {
                alert.informativeText = "⚠️ Use DD/MM/YYYY, with From on or before To."
                continue
            }
            runReport(Period(label: "\(auDate(fromISO)) to \(auDate(toISO))",
                             from: fromISO, to: toISO))
            return
        }
    }

    // MARK: Login item & quit

    @objc func toggleLoginItem() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            showError("Could not change the login item: \(error.localizedDescription)\n"
                      + "You can add the app manually in System Settings ▸ General ▸ Login Items.")
        }
    }

    @objc func quitApp() {
        // A running session stays in the state file and resumes on next launch.
        NSApp.terminate(nil)
    }

    func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "WFH Timer"
        alert.informativeText = message
        alert.runModal()
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
