---
name: Hoarder
description: A menu bar ledger of what agent coding left on your disks, each line with a verdict and the command that reclaims it.
colors:
  go-green: "#5EE08A"
  caution-amber: "#F2B84A"
  idle-grey: "#737885"
  stop-red: "#FF6B66"
  ink-black: "#000000"
  paper-white: "#FFFFFF"
  annotation-grey: "#8C919C"
  kept-title: "#B8B8B8"
  command-grey: "#CCCCCC"
  rule-line: "#262626"
  hover-wash: "#121212"
  open-panel: "#1F1F1F"
  amber-on-light: "#804D00"
  red-on-light: "#9E140F"
typography:
  headline:
    fontFamily: "SF Pro Text, -apple-system, system-ui, sans-serif"
    fontSize: "16px"
    fontWeight: 600
  title:
    fontFamily: "SF Pro Text, -apple-system, system-ui, sans-serif"
    fontSize: "13px"
    fontWeight: 600
  body:
    fontFamily: "SF Pro Text, -apple-system, system-ui, sans-serif"
    fontSize: "13px"
    fontWeight: 400
    fontFeature: "tnum"
  label:
    fontFamily: "SF Pro Text, -apple-system, system-ui, sans-serif"
    fontSize: "12px"
    fontWeight: 400
    fontFeature: "tnum"
  label-strong:
    fontFamily: "SF Pro Text, -apple-system, system-ui, sans-serif"
    fontSize: "12px"
    fontWeight: 600
  overline:
    fontFamily: "SF Pro Text, -apple-system, system-ui, sans-serif"
    fontSize: "11px"
    fontWeight: 400
    letterSpacing: "0.5px"
  mono:
    fontFamily: "SF Mono, ui-monospace, Menlo, monospace"
    fontSize: "11px"
    fontWeight: 400
  mono-field:
    fontFamily: "SF Mono, ui-monospace, Menlo, monospace"
    fontSize: "12px"
    fontWeight: 400
rounded:
  none: "0px"
  sm: "5px"
spacing:
  hairline: "1px"
  xs: "4px"
  sm: "6px"
  md: "8px"
  lg: "12px"
  xl: "14px"
  2xl: "20px"
components:
  text-button:
    textColor: "{colors.paper-white}"
    typography: "{typography.label}"
    padding: "5px 6px"
  text-button-action:
    textColor: "{colors.go-green}"
    typography: "{typography.label}"
    padding: "5px 6px"
  text-button-quiet:
    textColor: "{colors.annotation-grey}"
    typography: "{typography.label}"
    padding: "5px 6px"
  text-button-destructive:
    textColor: "{colors.stop-red}"
    typography: "{typography.label}"
    padding: "5px 6px"
  finding-row:
    backgroundColor: "{colors.ink-black}"
    textColor: "{colors.paper-white}"
    typography: "{typography.body}"
    padding: "4px 12px"
  finding-row-hover:
    backgroundColor: "{colors.hover-wash}"
  finding-row-open:
    backgroundColor: "{colors.open-panel}"
  verdict-dot:
    size: "7px"
  device-tab:
    textColor: "{colors.paper-white}"
    typography: "{typography.label}"
    padding: "7px 10px"
  device-tab-selected:
    backgroundColor: "{colors.open-panel}"
  sidebar-item-selected:
    backgroundColor: "{colors.open-panel}"
    rounded: "{rounded.sm}"
    padding: "5px 10px"
  command-block:
    textColor: "{colors.command-grey}"
    typography: "{typography.mono}"
---

# Design System: Hoarder

## Overview

**Creative North Star: "The Ledger"**

Hoarder is a ledger. Every line is an entry with a mark (the verdict dot), a name, a plain note and an amount, and every section ends in a total. The header is the balance: free space now, what is safe to clean and what needs review, then the sum, where Clean safe leaves you against your limit. Nothing is on the page that a bookkeeper would not write down. The interface earns trust the way a ledger does, by showing its working: open any line and the exact command is printed underneath before anything runs.

The surface is native macOS, dark, and dense. A 400pt popover on true black, system type at 12 to 13pt, rows separated by rhythm rather than boxes, 1px rules between regions. Color is scarce and always means something: four signal colors, each tied to a verdict or a status, on an otherwise black, white and grey page. Controls are words. There are no filled buttons, cards, pills or badges in the popover; an action is colored text with a generous hit area. There is no motion: state changes swap in place, and rows are laid out so hover and cleaning never reflow them.

The app icon is the same ledger in three dimensions: a stack of green, amber and grey slabs (`Support/AppIcon.svg`) using the exact verdict hex values. It is the only place a gradient or depth appears.

**Key Characteristics:**
- One ledger: rows grouped by category, totals right-aligned, numbers in tabular figures.
- Four signal colors, each meaning one thing; everything else is black, white or grey.
- Words for controls, colored by consequence (green runs, red destroys, grey is quiet).
- The command is always visible before Run.
- Flat and still: no shadows, no animation, no reflow.

## Colors

A black page with white ink, grey annotations, and four signal lights that only switch on to report a verdict or a problem.

### Primary
- **Go Green** (`go-green`): the reclaimable verdict. Filled verdict dots, the "safe to clean" total, Clean safe, Run on a reclaimable row, Add folder, "Notifications On", and the last-cleaned confirmation. Green means "this action loses nothing".

### Secondary
- **Caution Amber** (`caution-amber`): the review verdict and the low-space state. Ring verdict dots, the "to review" total, the popover heading and device status when under the limit, and the menu bar label when this Mac or any device is low.

### Tertiary
- **Stop Red** (`stop-red`): danger and failure. The critical heading (under a quarter of the limit), unreachable devices, failed cleanups, config parse errors, Remove device, and the warning line plus Run on a cleanup that loses data (dirty or locked worktree, a volume's contents, agent transcripts).

### Neutral
- **Idle Grey** (`idle-grey`): the keep verdict. Small solid dots on in-use rows.
- **Ink Black** (`ink-black`): every background, popover and Settings window alike.
- **Paper White** (`paper-white`): primary text, row titles, sizes of cleanable rows, neutral text buttons.
- **Annotation Grey** (`annotation-grey`): secondary text. Row reasons, section totals, setting labels, timestamps, "1 more", unit suffixes, quiet buttons.
- **Kept Title** (`kept-title`): titles of in-use rows, a step down from white so kept entries read as listed but not suggested.
- **Command Grey** (`command-grey`): the monospaced cleanup command in an open row.
- **Rule Line** (`rule-line`): 1px dividers between header, device strip, list and footer, between device tabs, and the Settings sidebar edge.
- **Hover Wash** (`hover-wash`): the barely-there row background under the pointer.
- **Open Panel** (`open-panel`): the background of an open row, the selected device tab, and the selected Settings sidebar item.
- **Amber on Light / Red on Light** (`amber-on-light`, `red-on-light`): darker tints used only for the menu bar label when the menu bar is light. The menu bar follows the system appearance independently of the popover.

### Named Rules
**The Signal Rule.** Green, amber, red and idle grey are reserved for verdict and status. A color that appears on screen answers "what verdict?" or "is something wrong?"; there is no brand accent and no decorative color.

**The Consequence Color Rule.** An action's color is the color of what it does. Run and hover "Clean" take the row's verdict color (green on reclaimable, amber on review, Kept Title grey on an in-use row that loses nothing) and turn red when the row carries a warning: the command loses uncommitted changes, a lock, a volume's data or transcripts. Navigation and dismissal stay white or grey.

## Typography

**Body Font:** SF Pro, the macOS system font (`.system`), with the platform fallback.
**Label/Mono Font:** SF Mono (`.system(design: .monospaced)`) for commands, hosts and paths.

**Character:** One system family at small sizes, weight doing the hierarchy. It reads as part of macOS, not as an app with a typeface of its own.

### Hierarchy
- **Headline** (600, 16pt): the popover heading ("22 GB free", or "6.0 GB free, critically low") and a Settings page title (the machine name). One per view.
- **Title** (600, 13pt): section headers in the list (Caches, Worktrees, node_modules, Docker).
- **Body** (400, 13pt, tabular figures): row titles and sizes, the base size of both windows.
- **Label** (400, 12pt, tabular figures): row reasons, header totals line, footer, text buttons, device status, setting help lines.
- **Label Strong** (600, 12pt): device names in the device strip.
- **Overline** (400, 11pt, 0.5pt tracking, uppercase): the MACHINES heading in the Settings sidebar. The only uppercase text.
- **Mono** (400, 11pt): the cleanup command in an open row, selectable.
- **Mono Field** (400, 12pt): host names and project folder paths in Settings.
- The menu bar label uses `NSFont.menuBarFont` so it matches the other menu bar items.

### Named Rules
**The Tabular Rule.** Every byte count, GB figure and timestamp uses tabular figures (`.monospacedDigit()`) so sizes align down the right edge like a column of amounts.

**The Middle Truncation Rule.** Titles truncate in the middle, so a branch name keeps its distinctive end (`storefront · feat/che…redesign`). Reasons never truncate; they move under the title when they do not fit beside it.

## Layout

The popover is a fixed 400pt column. From top: the device strip (only with devices), a 1px rule, the header (12pt padding), a 1px rule, the scrolling list (capped at 470pt), a 1px rule, the footer. The Settings window is a fixed 700 by 460pt split: a 200pt sidebar, a 1px rule, and a scrolling detail with 20pt horizontal and 16pt vertical padding.

Rows use 12pt horizontal and 4pt vertical padding. Text starts at a 27pt inset (12pt padding, 7pt dot, 8pt gap), and every line under a title (reason, open panel, warning, command) aligns to that inset, so the dots form a clean left column. Section headers get 14pt above and 3pt below, which is the only vertical separation between groups; there are no section boxes. Sizes sit in a right-aligned trailing column.

Sections are ordered by what is safe to clean, most first, with Docker last. Once a clean starts, that order holds until the popover closes or a scan lands, so the section being worked in never moves under the pointer.

A row's reason sits beside its title when both fit on one line and drops beneath it when they do not (`ViewThatFits`). The trailing size and its hover "Clean" share one slot, so hovering never shifts the row.

Settings rows put a grey label in a 150pt right-aligned column and the control on the shared first baseline, so values line up across every page. Groups of settings are separated by 1px rule lines.

### Named Rules
**The Inset Rule.** Anything that belongs to a row starts at the 27pt text inset. A line that starts elsewhere is not part of that row.

## Elevation & Depth

Flat. Nothing in the popover or Settings casts a shadow, and there are no gradients or blur. Depth is tonal: black at rest, `hover-wash` under the pointer, `open-panel` for the row that is open or the tab that is selected. Regions are separated by 1px `rule-line` dividers. The window chrome itself (the popover shape, the Settings window) is the system's.

### Named Rules
**The Three Tones Rule.** A surface is one of three tones: black (rest), hover wash (pointer), open panel (selected or open). There is no fourth level.

## Shapes

Square by default. Rows, the header, the device strip and the open panel are full-bleed rectangles with no corner radius. The one rounded shape is the selected item in the Settings sidebar (5pt radius). Native controls (text fields, steppers, switches, menus) keep their system shapes.

Verdict dots are 7pt circles, and their shape carries the verdict alongside color: a filled circle for reclaimable, a 1.6pt ring for review, and a smaller filled circle (inset 1pt) for keep. In the menu bar, critical swaps the drive symbol for a filled warning triangle.

### Named Rules
**The Shape Plus Color Rule.** Verdicts and warnings always differ by shape as well as color: filled, ring, small dot; drive versus triangle. Color is never the only signal.

## Components

### Buttons
Words, not buttons.
- **Shape:** none drawn. A text label with 6pt horizontal and 5pt vertical padding, giving at least a 24pt tall hit area (`TextButtonStyle`).
- **Action:** Go Green text for anything that loses nothing (Clean safe, Run on a safe row, Add folder).
- **Neutral:** Paper White text for navigation and dismissal (Cancel, Close, Snooze 1 day, Rescan, Show in Finder).
- **Quiet:** Annotation Grey for secondary or repeated actions (Remove on a folder line, the gear).
- **Destructive:** Stop Red for Remove device and for Run on a forced cleanup.
- **Row-bound:** Run and hover "Clean" on a row take its verdict color (amber on a review row, Kept Title on a plain in-use row), per the Consequence Color Rule.
- **Pressed:** 60% opacity. No hover fill.
- **Run** always carries the return glyph (`Run ⏎`) and is the default action; Cancel is bound to Escape.

### Finding Row (signature component)
The ledger line.
- **Closed:** verdict dot, title (white, or Kept Title for in-use rows), reason in Annotation Grey at 12pt, size right-aligned. Hovering a cleanable row washes it with `hover-wash` and swaps the size for "Clean" in the row's consequence color.
- **Open:** background turns `open-panel`; under the title come the full reason, the row's warning in red when its command loses data ("Deletes the uncommitted changes; not undoable", "Removes container api-db-1 and deletes the volume's data; not undoable"), the dim "Frees space in Docker's disk" note on a Mac, the command in Command Grey mono, then `Run ⏎`, Cancel and Show in Finder.
- **Cleaning:** the reason is replaced by "Cleaning" in the verdict color and the size dims; the row keeps its height.
- **Failed:** "Not cleaned:" and the reason in plain words under the row in red at 12pt ("it has uncommitted changes now"); the command's own output is the tooltip and, for keyboard and VoiceOver, a "Show output" text button in the open panel (dim mono under the command). When Docker is not running on this Mac and Docker Desktop is installed, the panel adds Open Docker; the scan's "Start Docker to see what it can clean" note gets the same button. A refused worktree is judged again at once and changes verdict where it stands (grey dot, "uncommitted changes", force command ready behind the red panel). Refused rows keep their place in the list until the popover closes, even once kept. On a device the reason column reads "checking again" until its rescan. The header adds "1 cleanup not done, see Worktrees" in red.
- **Collapsed groups:** "1 more" or "3 in use" in grey with the hidden total, expanding in place to "Hide 3 in use".
- **Keyboard:** ↑ and ↓ move a highlight through the rows on screen: the hover tone plus a 1px inset ring in Annotation Grey (6.65:1 on black; the hover tone alone is 1.1:1, too faint to find), scrolling it into view and closing any open panel. The pointer takes over from the keys and drops the ring. Return opens the highlighted row; once a panel is open its Run answers Return, and Esc closes it. The popover takes keyboard focus whenever it opens.

### Command Block
- **Style:** SF Mono 11pt in Command Grey, no background of its own (it sits on the open panel), selectable, wrapping, capped at 120pt with its own scroll.
- **Rule:** it is the literal string that will run, never a paraphrase.

### Header
The balance, written as a ledger sum.
- **Headline** in white, amber (low) or red (critical), with Clean safe at the trailing edge of the same line. Critical adds a warning triangle and reads "6.0 GB free, critically low". The headline names the limit ("under your 40 GB limit") only when no After Clean safe line states it.
- **Sum rows:** the Finding Row anatomy at header scale (label 12pt, size 13pt, right-aligned). A filled green dot and "Safe to clean" for this machine; on a Mac, a dim "plus inside Docker's disk" line with no dot, since Docker's prunes free space inside its VM disk and not on the Mac; a ring amber dot and "To review". When only Docker has safe rows, that line becomes "Safe to clean inside Docker's disk" with the green dot.
- **After Clean safe:** under a 1px rule, semibold 13pt, the free space once safe rows are cleaned (Docker's share left out). While the machine is under its limit, a dim note says "above your 40 GB limit" or "still under your 40 GB limit", and the line takes the color that figure would have: white above the limit, amber under it, red under a quarter of it.
- **Checklist:** pressing Clean safe (or ⇧⌘C) adds, under a 1px rule, one line per row it will run in run order (title, its kind in dim: "cache", "worktree", "node_modules", "Docker", size at the trailing edge), indented to the sum's labels and scrolling past 240pt. A dim "Show the 11 commands" opens each command in Command Grey mono under its line. Then "Runs these 11, one at a time" with `Run ⏎` and Cancel.
- **Running:** the same lines take a status in place of the size: green "cleaning", green "done" (the line dims), red "not done". Under them "3 of 11" and "Stop after this one", which has no Esc binding so a stray key cannot interrupt a run. The header's cleaning and outcome lines wait until the run ends, then read "Cleaned 10 of 11, 42.6 GB" or "Stopped after 3 of 11, 35.5 GB cleaned".
- Status lines (first scan, cleaning, cleaned, failed, notifications off, snoozed) stack below in their signal color.
- **First scan:** "The first scan takes about a minute", then, as scanners finish, "Checked worktrees and caches, still checking node_modules and Docker". The scanners run side by side, so it names what is done rather than a percentage, and nothing moves on screen. A device's first scan is one call and keeps the first line.
- **Nothing to offer:** with no rows the headline is followed by "Nothing to clean" and the list is left out, so the header meets the footer. With only in-use rows it reads "Nothing safe to clean or to review; the rows below are in use".

### Navigation: Device Strip
- **Up to four machines:** equal-width tabs across the top, separated by 1px rules. Device name in Label Strong over its free space as a bare figure ("123 GB", grey; amber when low, red when critical or "unreachable"). Names truncate in the middle; the figure never truncates. A tooltip names the shortcut ("homeserver, ⌘2").
- **Selected tab:** `open-panel` background, no underline or border.
- **Past four machines (picker):** one line, 12pt horizontal and 8pt vertical padding: the machine shown in 13pt semibold with a small dim chevron, then at the trailing edge a summary in words, "2 low · 2 unreachable · 6 machines" (amber, red, dim). Clicking opens a native menu: each machine with its status in words right-aligned ("8.0 GB, low" in amber, "unreachable" in red, plain figures in secondary label color), the shown machine checked and placed under the pointer, ⌘1 to ⌘9 as key equivalents.
- **Names:** a `.ts.net` or `.local` suffix is dropped for display; the full host stays in Settings' Host row.
- **Keyboard:** ⌘1 to ⌘9 in both forms, menu closed or open.

### Navigation: Settings Sidebar
- General, In use, then an uppercase MACHINES overline, then one item per machine with free space trailing in its status color. Selected item gets `open-panel` with a 5pt radius. Add from tailnet (borderless menu) and Add by name sit below.

### Inputs / Fields
- **Style:** native `roundedBorder` text fields and steppers, small switches. Numbers right-aligned in tabular figures, with the unit in grey after the stepper. Paths and hosts in Mono Field.
- **Behavior:** saves on Return, focus loss or a step; no Save button. Escape cancels an inline add field.

### Menu Bar Label
- A drive symbol and free space ("22G") in the menu bar font, template-rendered so it follows the menu bar. Amber when this Mac or any device is low, naming one low device ("22G · homeserver low", the name cut in the middle past 14 characters) or counting several ("22G · 2 low"); red with a warning triangle when this Mac is critical. Light menu bars get the darker on-light tints.

### Footer
- "Scanned just now" in grey at the leading edge; Snooze 1 day (⌘S), Rescan (⌘R) and a gear menu trailing, all as text buttons at 12pt. The gear menu lists the popover's actions with their shortcuts (Clean safe… ⇧⌘C, Rescan ⌘R, Snooze 1 day ⌘S, each disabled when it does not apply), then Settings ⌘, and Quit, so the shortcuts are findable where macOS shows them.

## Do's and Don'ts

### Do:
- **Do** give every new list item the Finding Row anatomy: dot, title, reason, right-aligned size, all text at the 27pt inset.
- **Do** show the exact command, in Command Grey mono, before any Run.
- **Do** color a row's action by its verdict (green, amber, Kept Title grey) and switch it to Stop Red when it forces; keep navigation white or grey.
- **Do** use tabular figures for every number and right-align sizes.
- **Do** keep layouts stable across states: hover, cleaning and confirmation swap content in place without reflowing the row.
- **Do** pair every color signal with a shape or word (dot style, triangle, "unreachable", "Cleaning").
- **Do** check new states with `swift run HoarderApp --snapshot` and add a state file under `scripts/screenshots/states/` when the state is worth a README shot.

### Don't:
- **Don't** use green, amber, red or idle grey for anything other than a verdict or status. No brand accent, no decorative color.
- **Don't** add filled or bordered buttons, cards, pills, chips or badges to the popover. Actions are colored text with a padded hit area.
- **Don't** let color be the only difference between two states; verdicts and warnings also differ by shape or wording.
- **Don't** add a fourth surface tone or a shadow to separate content; use a 1px rule line or the open panel tone.
- **Don't** truncate a reason or a command; truncate titles in the middle instead.
