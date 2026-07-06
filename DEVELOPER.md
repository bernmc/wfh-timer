# WFH Timer — developer notes

A single-file native macOS menu bar app. No Xcode project, no dependencies.
User-facing instructions are in [README.md](README.md).

## Build / install

```sh
./build.sh            # compile to build/WFH Timer.app (universal arm64 + x86_64)
./build.sh --install  # compile, copy to ~/Applications, relaunch
```

Any change to `main.swift` needs a rebuild (`--install` handles quit-and-relaunch).

## Using it

- **⌂** in the menu bar. **Left-click** toggles the timer window; **right-click**
  (or ⌃-click) opens the menu.
- **Timer window:** live analogue clock, Garmin-style — dark dial, engraved 60-tick
  minute track with numerals every 5. While the timer runs, a red-orange **arc along the
  rim** follows the minute hand clockwise from your start time (5 min = 30° of rim).
  A completed hour leaves a dim full ring beneath the bright arc. Below it: a digital
  h:mm:ss readout of logged (net) time, the start time / away deductions, and a green
  **Start** / red **Stop** button (Return key works).
  The **⋯** button opens the same menu as right-clicking the icon. Closing the window
  never affects the timer. Reopening the app from Launchpad also shows the window.
  **Keep Window on Top** in the menu pins the window above other apps (remembered
  across launches).
- **Start Timer / Stop Timer…** (⌘S works while the menu is open). On stop you can add
  an optional note, or Discard the session.
- Menu bar shows **⌂ 1:23** while running; **⚠️** appears (and a Ping sound plays once)
  after 6 h continuous — the forgot-to-stop catcher.
- **Sleep/idle:** if the Mac slept >5 min or you were away >30 min while the timer ran,
  you'll be offered a one-click deduction when you return.
- **Add Past Session…** for forgotten sessions. Dates are Australian **DD/MM/YYYY**
  (flexible: `5/7/2026`, `5/7/26`, `5.7`, or `5/7` = this year). Times accept shorthand:
  `9` → 09:00, `1430` → 14:30, `9:30` / `9.30` as-is; 3-digit entries like `140` are
  rejected as ambiguous. **Open Data File** opens the CSV (hand-editable; keep the
  5-column format — its date column stays ISO `yyyy-mm-dd` so it sorts correctly, but
  all dialogs and reports show DD/MM/YYYY).
- **Reports ▸** This/Last BAS Quarter, This/Last Financial Year, Custom Range, All Time.
  Opens a printable HTML page in the browser — File ▸ Print ▸ Save as PDF for the
  accountant. Includes monthly (and quarterly) subtotals in h:mm and decimal hours.
- **Start at Login** toggle in the menu. If registration fails (ad-hoc signing), add
  `~/Applications/WFH Timer.app` in System Settings ▸ General ▸ Login Items instead.
- **Quit does not lose a running session** — it's saved to `data/.current_session.json`
  and resumes on next launch. Same after a crash or reboot.

## Files

| File | Purpose |
|---|---|
| `main.swift` | entire app |
| `Info.plist` | bundle metadata (`LSUIElement` hides the Dock icon) |
| `build.sh` | compile + ad-hoc sign (+ install) |

## Data location

Default: `~/Documents/WFH Timer/` containing `wfh_hours.csv` (the record:
`date,start,stop,duration_min,note`), `reports/` (generated HTML, safe to delete),
and `.current_session.json` (crash-safe running-session state). Overridable via the
"Choose Data Folder…" menu item, which stores the path in
`defaults write com.bernardmcclement.wfhtimer dataFolder <path>`.

## Tunables (top of main.swift)

- `idleThreshold` — 30 min without input before "away" handling
- `sleepThreshold` — 5 min of sleep before offering a deduction
- `nudgeAfter` — 6 h before the long-session warning
- `defaultDataDir` — fallback data location when no `dataFolder` default is set

## Build note

`build.sh` pins `-target <arch>-apple-macos14.0` (and lipos arm64 + x86_64 into a
universal binary) because a beta Swift toolchain otherwise targets a newer macOS than
the installed one and Launch Services refuses to open the app (error -10825).
