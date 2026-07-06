# WFH Timer

**A tiny, free Mac app that records your work-from-home hours — so tax time is a
two-minute job instead of a guessing game.**

Made by a doctor for colleagues who work from home and need a defensible record of
their hours for the ATO (or just for themselves). No accounts, no subscriptions, and
your data never leaves your Mac.

## What it does

- Lives quietly as a little **house icon** at the top-right of your screen (the menu bar).
- **Click the icon** → a small watch-style timer window appears. Press **Start** when you
  begin working, **Stop** when you finish. That's it.
- Every session is saved with the **date, start and finish time, duration**, and an
  optional one-line note of what you worked on.
- **One-click reports** for each **BAS quarter** and the **financial year** (1 July –
  30 June), with monthly totals — formatted so you can print it (or save as PDF) and
  hand it straight to your accountant.
- It's honest: if your Mac went to sleep or you wandered off for half an hour, it
  notices and offers to knock that time off. If you forget to stop it, it warns you
  after 6 hours. If you forgot to start it, you can add a session afterwards.

## Getting it (about 2 minutes)

1. Go to the **[Releases page](../../releases/latest)** and download **WFH-Timer.zip**.
2. Double-click the zip to unpack it, then drag **WFH Timer** into your
   **Applications** folder.
3. **First time only:** macOS is suspicious of apps that don't come from the App Store.
   If it refuses to open, go to **System Settings → Privacy & Security**, scroll down,
   and click **"Open Anyway"** next to the WFH Timer message. You only do this once.
4. Look for the small **house** at the top-right of your screen. You're running.

Works on any Mac from 2020-ish onwards (both Apple Silicon and Intel), macOS 14 or later.

## Using it day to day

- **Left-click the house** → timer window. Green **Start** to begin, red **Stop** to
  finish. When you stop, you can type a short note (e.g. "telehealth clinic",
  "reports") — good evidence if anyone ever asks.
- **Right-click the house** → the full menu:
  - **Reports** → *This BAS Quarter*, *This Financial Year*, etc. The report opens in
    your browser — use **File → Print → Save as PDF** for your accountant.
  - **Add Past Session…** → forgot to start the timer? Add it here. Dates are normal
    Australian **DD/MM/YYYY**, and times are forgiving — `9`, `0930`, `14:30`, and
    `9.30` all work.
  - **Keep Window on Top** → keeps the timer visible over your other windows.
  - **Start at Login** → so it's always there.
- Stepped away or your Mac slept while the timer ran? When you come back it asks
  whether to deduct that time — one click either way.
- Closing the window, quitting the app, or even restarting your Mac **never loses a
  running session** — it picks up where it left off.

## Where your records live

Everything goes into one simple spreadsheet file: **Documents → WFH Timer →
wfh_hours.csv**. It opens in Excel or Numbers, you can back it up like any file, and
if you ever delete the app your records remain. (Want it somewhere else, like a synced
folder? Right-click the house → **Choose Data Folder…**)

## Common questions

**Is my data uploaded anywhere?** No. There's no internet involved at all — one file
on your Mac, nothing else.

**Is it really free?** Yes — free and open source (MIT licence). The entire program is
one readable file in this repository.

**Will the ATO accept this?** It produces a dated, timestamped record of your hours
with printable summaries, which is exactly the kind of contemporaneous record they
like. But talk to your accountant about what you can claim — this app records time,
it doesn't give tax advice.

**Something's not working / I have an idea.** Open an issue on this page (the "Issues"
tab) or tell Bernard at work.

---

*For the technically inclined: build instructions and design notes are in
[DEVELOPER.md](DEVELOPER.md).*
