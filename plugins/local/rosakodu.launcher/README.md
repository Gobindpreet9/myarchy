# Launcher

A native Quickshell/QML application launcher for **Omarchy**. App and file
search and AI chat share the `rosakodu.dock` matte design language, with an
editorial answer layout in AI mode. It is a **separately enableable plugin**: it can be
tried and removed without touching the dock, the stock Omarchy menu, or any
global keybinding.

---

## Native OpenUI integration — current status

The `feat/launcher-openui-native` branch integrates OpenUI into the
existing native AI pane, composer, turns and SQLite workspaces. The plugin
subtree **is installed on this live desktop**; the manifest/release remains
**1.22.0**. The shell was restarted and Omarchy's default agent was switched to
**OpenCode** for qualification. Live checks used clearly named test workspaces;
existing user workspaces were not deleted. The separate
`~/Work/launcher-openui/launcher/` browser prototype is historical development
evidence, not a product or a step users need to launch.

New **Codex and OpenCode** conversations automatically use
`responseMode: "openui"`, allowing one model-authored OpenUI tool alongside the
existing answer blocks. Restored legacy workspaces and Hermes keep native-block
generation. One retained `AiService` runtime evaluates the restricted DSL
outside Qt; native QML adapters render its inert layout/control/SVG tree. There
is **no WebEngine/browser runtime and no DSL evaluation in Qt**. Only one tool is
selected at a time; expand **Earlier answers** and choose **Use this tool** to
activate a historical tool. Acknowledged inputs persist under
`uiStates[turnId]["openui:<blockIndex>"]` and duplicate as opaque state, using
the existing save path. OpenUI follow-ups carry bounded code/state context
(48 KiB total, including at most 12 KiB of state), not a reconstructed
transcript or an in-place artifact patch. Before a generated tool is shown, the
broker checks it with the same bounded native runtime; a rejected program gets
one automatic correction request, and a still-invalid tool is omitted with a
visible note rather than a broken surface.

The credential-free Python guardian runs permission-limited **Node >=24**
(26 on this machine), with a 96 MiB old-space cap and an external 3-second
per-request watchdog. Bounded JSONL IPC, restricted AST/actions and semantic
SHA-256 event handles (authored action AST plus input binding/options/range)
reject stale queued action/input retargets. Native typed
`calc` validation remains separate; generic OpenUI math does not inherit its
units/provenance guarantees.

Build source, lockfile and MIT notices are under `openui/`. From this plugin
directory, `python3 -B tests/build_openui.py --check` rebuilds/tests in scratch
using `npm ci --ignore-scripts` and checks byte-identical assets; only explicit
`--write` replaces generated assets. `python3 -B tests/run_offline.py` runs
Python, QML and isolated Quickshell checks with fresh private HOME/XDG trees
under `/tmp/opencode`; no provider or live workspace is needed. See Tests and
`AI_WORKSPACE_PLAN.md` §3.4 for evidence and pending live/resource qualification.

## ✨ Features

- **Theme-aware surface in all modes** — floating card with matte gradient, hairline
  keyline, restrained specular edge and soft shadow, built from Omarchy
  `Color`/`Style` tokens. No compositor blur. Alpha translucency follows the
  independent `launcherTranslucency` setting in Dock Settings
  (`~/.config/omarchy/dock-settings.json`, `0`–`100`%). The dock owns the
  saved value and the launcher only reads it. App, file and AI modes all use
  the active theme and the same launcher translucency.
- **Immediate search focus** — opening the launcher puts the caret in the
  search field at once.
- **Purposeful motion** — opening from the dock's Apps glyph grows the card
  out of that button and blooms the dimmer around it; bare `Super` uses a
  keyboard-native spotlight descent with a lid-like dimmer lift and a focus
  line that draws into the search field. Closing reverses whichever gesture
  opened it, on a shorter curve. Entry/exit use opacity and transforms; AI
  mode separately resizes the bounded card. If
  Hyprland animations are disabled, the launcher opens and closes instantly.
- **Desktop-entry search** — matches name, generic name, keywords, and desktop
  ID. Exact and prefix matches rank above fuzzy matches. Entries marked
  `NoDisplay`, hidden by `launcher.hides`, or filtered by `OnlyShowIn` /
  `NotShowIn` are excluded.
- **File/folder search** — prefix with `f:` (for example, `f: config hypr`)
  to search filenames and full paths across your home directory. Requires at
  least two query characters; multiple terms are literal, case-insensitive
  matches, not regexes. Hidden configuration is included, but cache,
  dependency and credential directories and common secret filenames are
  excluded. `fd` respects ignore files. No file contents are searched, and
  exclusions are not a security boundary. Searches debounce for 180 ms,
  return at most 100 results, and stop scanning after 5 seconds with partial
  results. Ordinary app search is unchanged.
- **Explicit AI chat** — type `ai:` to enter AI mode, then write a question in
  the native composer and press `Enter` or **↑ Send**. The mode command is not
  displayed in the prompt. Typing alone never calls an agent. The idle pane
  shows only the composer: no provider label, Apps header, onboarding copy or
  suggestion chips.
- **Lazy workspace restore** — boot and saved-workspace discovery are
  metadata-only; the most recent conversation hydrates once on a real `ai:`
  entry, showing **Loading your last conversation…** with submit gated while it
  settles, so ordinary search stays light until AI is actually used.
- **Thin saves for draft-only edits** — autosave and close-commit always write
  the small workspace row fields (id, title, summary, agent, session reference,
  draft, attachment), but the full conversation serialization goes out only
  when turns, checklists or learning state actually changed. A
  draft/attachment-only edit writes a thin payload with empty content lists,
  and the store only upserts what it receives, so stored artifacts and
  interaction rows are preserved, never cleared.
- **Exploration trail** — each answer carries a short, honest line describing
  what you actually did with it: **Checked**, **Predicted**, **Stepped
  through**, **Scrubbed**, **Sorted**, **Filtered**, **N examples replaced**
  or **Depth added**. It is derived only from saved interaction state, so it
  restores with the workspace; untouched answers show nothing.
- **Reusable workspaces** — **More → Rename…** gives a saved tool a searchable
  name; **More → Duplicate…** copies its answers and local inputs into an
  independent workspace with a fresh AI conversation, not a conversation branch.
- **Names-only result rows** — each row shows the clean application name. No
  desktop IDs or technical subtext are displayed. Short searches collapse the
  card to their results; longer lists scroll within the full-size card.
- **Safe extra actions** — with a non-empty query the launcher can offer:
  calculator results for arithmetic input, direct URL opening for link-like
  input, and a Google web search row. Query text is never executed as a shell
  command: links and search URLs are passed as a single argument to the fixed
  path `uwsm-app -- xdg-open <url>`, and calculator input is evaluated by a
  pure arithmetic parser (no `eval`).
- **Real desktop-entry icons** with a neutral fallback for missing themes.
- **Recents** — the six most recently used apps appear as quick tiles. Dock
  favorites stay in the dock instead of consuming launcher space. Launches
  from either surface update the shared recent-app history.
- **Safe launching** — search text is never executed as a command. An exact
  match to an already-running app focuses its window; other entries use the
  scoped app-library API when available, or the desktop entry's supported
  launch path (`uwsm-app -- gtk-launch <id>.desktop`) with a validated
  desktop-entry ID as an argument list.
- **Independently removable** — no changes to `/usr/share/omarchy`, Hyprland
  bindings, or the stock menu/launcher routes.

---

## 🎮 Controls

| Action | Control |
| :--- | :--- |
| **Toggle** | `Super` (tap); tap again to animate closed |
| **Search** | type immediately |
| **Move app/file selection** | `↑` `↓`, `Tab` / `Shift+Tab`, `PageUp` / `PageDown` |
| **Launch** | `Enter` or click a row / recent tile |
| **Open file/folder** | `Enter` or click a file-search row |
| **Open containing folder** | `Alt+Enter` on a file-search result |
| **Copy full path** | `Ctrl+C` on a file-search result when the search input has no selection; otherwise copies selected text normally |
| **Ask AI** | type `ai:`, write a question, then `Enter` or **↑ Send**; or choose the **Ask AI…** result row, which transfers the query into the composer without sending it |
| **Attach a file to AI** | **Ask AI** or `Ctrl+Enter` on a file-search result; review the prompt before sending |
| **Focus AI input** | `Ctrl+L` |
| **Move through AI controls** | `Tab` / `Shift+Tab` |
| **Return to apps** | **←** in the AI composer |
| **Stop AI response** | **Stop** in the busy composer |
| **Adjust explanation depth** | **Simpler** / **More depth** / **Another example** under the latest learning answer |
| **Sort a comparison table** | `Tab` to a column header and press `Return` / `Space`, or click it: ascending → descending → authored order |
| **Filter comparison-table rows** | `Tab` to the filter field (tables of four or more rows) and type; the row count updates live |
| **Ask about one part of an answer** | on the latest finished answer, hover a table row, gallery tile, step, selected diagram node or chart point and choose **Ask**; by keyboard, `Tab` to the table rows (one stop, `Up`/`Down` choose a row), a step, a gallery cell, a diagram node or the chart and press `?`. The composer shows **About: ...** and the next question carries that part; `Esc` (or **x**) removes it before anything is sent |
| **Use an earlier OpenUI tool** | expand **Earlier answers**, then choose **Use this tool**; one selected runtime is shared across the conversation (development tree only) |
| **New AI chat** | **New chat** in the answer toolbar |
| **Expand / collapse the AI workspace** | **Expand** / **Collapse** in the answer toolbar |
| **Reopen a saved workspace** | search for its title or summary; the **Workspace · date** row opens it |
| **Name a workspace** | **More → Rename…**; enter a name and choose **Save** |
| **Copy a workspace** | **More → Duplicate…**; review the name and choose **Duplicate** |
| **Open the workspace in a window** | **More → Open in window** in the answer toolbar |
| **Close** | `Esc`, or click outside the card |

Tapping `Super` by itself opens this launcher (bound in
`~/.config/hypr/bindings.lua`). `Super+Space` and `Super+Alt+Space` keep their
stock Omarchy behavior. No other global shortcut is installed
by this plugin. The snippet below is only an example for an extra binding of
your own — it is not installed automatically:

```lua
-- ~/.config/hypr/bindings.lua (optional example, not installed)
o.bind("SUPER + A", "Launcher", "omarchy-shell shell summon rosakodu.launcher")
```

---

## 💬 AI chat

`ai:` is the command to enter AI mode, not literal text in the visible input.
It is accepted case-insensitively, with or without a separator space
(`ai:question` works). The legacy `:ai` form is ordinary search text and no longer
enters AI mode.
The native prompt field shows **Ask anything** before the first turn and
**Ask a follow-up** afterward. The composer is multiline: it grows up to six
lines, preserves pasted newlines, and `Shift+Enter` inserts a newline while
`Enter` submits. Submit explicitly with `Enter` or **↑ Send**;
Send is hidden and disabled for a blank prompt, while work is busy or stopping,
or while a workspace restore is still loading.
Typing, pasting or prefilling a prompt never calls an agent. While busy, **Stop**
appears in the composer, and you can still edit the next draft. Use the direct
**←** button to return to app search without clearing the conversation.

The launcher watches Omarchy's default agent
(`~/.config/omarchy/defaults/agent`). Current adapters target **Codex**,
**OpenCode** and **Hermes**. An existing chat stays pinned to its agent. New
Codex and OpenCode conversations author the native OpenUI tool profile; Hermes
and restored legacy conversations use native answers. OpenCode answers run
headlessly with the pinned `opencode-go/deepseek-v4.1-flash#high` model and an
answer-only policy: no shell, file, browser or MCP tools, and no changes to your
OpenCode configuration. The installed OpenCode build must be the audited
**2.2.3** release; OpenUI generation gets a 240-second per-attempt deadline,
while ordinary native answers keep the 120-second deadline. Before a generated
tool is shown, the same bounded
native runtime checks it; a rejected program gets one automatic correction
request, and a still-invalid tool is omitted with a visible note instead of a
broken surface. The direct **New chat**
action in the answer toolbar clears the visible conversation, draft, attachment
and checklist state; the finished conversation stays saved and searchable, and
the next submission uses the current default. **Earlier answers**
reveals prior turns, and **Hide earlier answers** collapses them again.
While collapsed, earlier turns are not instantiated at all: their native
answer trees, images and delegates are released, expanding history
materialises them again, and collapsing releases them once more.
**More** contains the text/interface view toggle, **Open in window**, and
**Continue in terminal**, plus **Rename…** and **Duplicate…**.

**Names and copies.** The themed, keyboard-accessible dialogs accept a non-empty,
trimmed, plain single-line name of at most 96 UTF-16 code units (an emoji can
use two). The saved name survives draft-only saves, full saves and restoration,
and is used in launcher search and the detached window; answer headings are
unchanged. **Duplicate** opens an independent copy with the turns, checklists,
local UI state (including adjusted calculation inputs), draft and attachment.
Artifacts receive new identities and each starts with a new revision checkpoint;
the original revision history is not copied. Cached image references stay
unchanged. A kept CSV copy belongs only to the original: neither its registry
link nor its full-data resource is shared or cloned.

The original stays saved with its provider session and terminal handoff home.
The duplicate starts with both blank: its first future provider prompt does
**not** reconstruct the copied conversation history. This is local tool reuse,
not full AI conversation branching or state-aware AI revisions. Actions wait for
a confirmed save before the backend mutation; duplication also confirms edits
made to the original during the action before switching to the copy. They are
gated while busy, stopping, loading, keeping data or another workspace action
is pending, and do not prune workspaces. Editing pauses briefly only while the
copy opens; if opening fails, the original stays open. An open naming dialog
closes if you switch workspaces, so it cannot rename a different tool.

**Codex homes.** Each Codex broker process builds a private home under
`launcher-ai/codex-*` (a copy of `~/.codex/auth.json`, the model catalog and
Codex's own session rollouts). A saved workspace records its home as
`handoffHome` so **Continue in terminal** can `codex resume` it, so a home can
be needed long after its broker exits. The broker therefore removes only its
own home, and only if it never sent a `done` event (the sole carrier of
`handoffHome`), including a half-built home after a failed sign-in. Older
homes are cleaned by an explicit tool that nothing runs automatically:

```bash
python3 ai_broker.py --reap-homes                              # dry run: lists every home and why
python3 ai_broker.py --reap-homes --apply --expect-count N     # removes exactly the N you approved
```

It keeps any home a workspace names (anywhere in its saved interaction data),
any home owned by a live broker or used as `CODEX_HOME` by a running process,
and anything touched within `--min-age-hours` (default 24). It reads a private
snapshot of `workspace.db`, never writes to it, never touches `media/`, and
refuses to run if the database is missing, unreadable, or lists Codex
conversations that record no home. `--limit` bounds one run (default 200).

Conversations are saved locally as workspaces (SQLite under
`~/.local/state/omarchy/launcher-ai/`, or `$XDG_STATE_HOME`) and survive shell
restarts. A session's saves and loads run through one lazily started
line-oriented store worker (`python3 ai_workspace_store.py --serve`), not one
Python interpreter per operation: the burst queue writes through a single open
pipe, the worker answers requests strictly in order, and it exits when idle —
about 30 seconds after the last operation — with a fresh worker starting on
demand. Boot and saved-workspace discovery are metadata-only; the most recent
workspace hydrates once, on a real `ai:` entry, restoring turns, checklist
selections, draft, attachment and the session reference. While that load is in
flight the pane shows **Loading your last conversation…** and submit stays gated
until the load settles; a 5-second watchdog guarantees a failed restore never
leaves the composer unsubmittable. Text or attachments typed or set while the
load was in flight survive the completed snapshot: the service captures the
entry state and compares it with the live draft, so newer keystrokes always win
over a stale capture, while a programmatic empty draft never blocks restoring
the stored one. Closing the launcher commits a pending debounced
draft/attachment save, so a quick close and reopen loses nothing, and opening AI
mode again resumes the existing conversation instead of forcing a bare prompt.
Autosaves coalesce dirty fields: the small workspace row travels on every save,
while the full artifacts and interaction serialization is sent only when
conversation content actually changed (turns, checklist selections or learning
state); a draft/attachment-only edit writes a thin payload with empty content
lists, and the store preserves any content a save did not receive. Starting a
**New chat** keeps the finished conversation with a full final save.
Answer presentations are stored as workspace-scoped artifacts and
a revision is recorded whenever those blocks actually change; transcripts saved
before the artifact split still restore their inline blocks. A response
interrupted by a restart returns as a retryable error
instead of a spinner. Automatic housekeeping preserves saved conversations;
it no longer applies the legacy 20-unpinned/30-day deletion policy. That policy
remains available only through an explicitly invoked store `prune` operation
without `preserveWorkspaces: true`. Saved workspaces are
searchable from the launcher: matching titles and summaries appear as distinct
**Workspace** rows (above the web-search actions) and reopen the full
conversation; the workspace currently on screen is excluded. The answer
toolbar's **Expand** / **Collapse** switches between the compact Peek card and
the wider Explore card without changing any state. **More → Open in window**
(or the `window` IPC) detaches the active workspace into a normal desktop
window that shares the same conversation: one view per workspace, reopening
focuses the existing window, closing it keeps the workspace, and `Esc` there
does not close it.

The AI broker process is demand-started and retired when idle: while the
launcher (in AI mode) or the detached workspace window is visible, or a job is
running or stopping, it stays warm; once every AI surface is hidden and no
work has run for 30 seconds, a repeating one-second timer retires the broker
process. Native-block submits carry the persisted provider session, so the next
question cold-starts a fresh broker that resumes the same conversation. OpenUI
keeps warm provider sessions, but a cold broker does not adopt an untagged saved
session: its bounded tool code/state snapshot supplies follow-up context instead,
not the complete conversation. If the provider has discarded a native session,
the broker clears it and retries once from a fresh session instead of
hard-failing the follow-up: provider-side continuity is best-effort,
availability is not, and any run that adopted a persisted session hint is
covered — depth explanations included. Provider processes load `ai_broker.py`
at spawn, so guidance edits apply to the next broker start (idle retirement or
shell restart). `status` exposes the gate as `brokerIdle` and `brokerRunning`.

New launcher Codex chats use **`gpt-6.1-sol`**, independently of the model in
`~/.codex/config.toml`; the global Codex configuration is not changed. Existing
chats retain their prepared model and session. If `gpt-6.1-sol` is missing from
Codex's cached catalog, the launcher reports an error rather than substituting
another model; open Codex once to refresh the catalog.

Codex is configured for **live hosted web lookup**, with only the built-in
Responses `web_search` tool advertised and text-only results. Codex 0.160.0
hardcodes parallel hosted calls on for regular Responses despite the catalog's
disabled-parallel setting; the safety boundary is the hosted-only tool list,
not request concurrency. Search lifecycle events show **Searching the web…**;
raw search queries and results are not mixed into the displayed assistant answer. Shell commands,
file editing, local filesystem tools, standalone `web.run`, browser automation,
MCP and other local tools remain disabled. Hermes continues to advertise no tools.
The private Codex catalog selects regular Responses instead of Responses Lite
to allow hosted lookup. Media resolution is handled by the app, not additional
model tools.

The native-block profile (Hermes and restored legacy conversations) uses
validated, flat blocks; these also remain available in the Codex OpenUI profile:
text, limited rich text, code, tables, interactive checklists, metrics, progress, contextual
images, market history, generic charts, compact clickable sources, and learning
blocks — **steps** (a stepper with previous/next, a current-stage overview and
a saved position), **check** (one or more correct options with per-option
feedback, an explanation and a meaningful retry), **predict**
(prediction/reveal that locks once committed), **diagram** (a declarative
schematic on a percentage grid with circle/rect/line/arrow/text parts,
selectable parts that share their detail below the canvas, and keyboard
selection), and **slider** (a parameter control with optional named steps and
up to four readouts computed locally from a bounded arithmetic formula — no
model round trip while scrubbing, and no dynamic evaluation of arbitrary text;
expressions allow only x, arithmetic, and a fixed function set). A slider can
also **drive diagram parts**: declared links set a part's x/y/w/h/rotation from
the same formula grammar, so scrubbing visibly animates the schematic (the
slider and the readouts stay in sync instantly). **Comparison tables** are
local tools: clicking a column header cycles ascending → descending → the
authored order, sorting numbers numerically and text lexically; a table of four
or more rows exposes a filter field that narrows rows by a literal,
case-insensitive substring, never a regular expression, and shows a live "n of
m rows" count while filtering. Headers and the filter are tab-reachable,
`Return` or `Space` activates a header, and the sort and filter state
(`table:<blockIndex>`) persists with the workspace. **Gallery** presents 2–6
captioned photographs for comparisons (styles, variants, examples), each
resolved through the same trusted Wikimedia pipeline with its own credits and
enlarged viewer. Every gallery item carries two candidates, so its in-cell
**Show another** can replace that one example through its own
`gallery:<block>:<item>` state key without resetting the comparison. Single
image blocks additionally offer **Show another** to swap between up to three
candidates without a new prompt. The model chooses
these vehicles from the subject automatically — it is not necessary to name a
card type when asking. When the latest answer carries a learning block it also
offers **Simpler**, **More depth** and **Another example**: each action asks for
a short prose explanation of the current object, shown in a sidecar below the
answer while the blocks, controls and their saved state stay untouched.
**Another example** means one fresh, specific situation (a place, object or
everyday case) showing the same idea, not a restatement of the mechanism. The
sidecar persists with the conversation and appears in **Show as text**. The
model's contextual follow-up suggestions appear as small chips under the latest
answer and fill the composer without sending. Learning
positions, slider values, check
selections and predictions persist with the workspace across restarts, and
the same state draws the exploration trail under each answer: **Checked** /
**Predicted** / **Stepped through** / **Scrubbed** / **Sorted** / **Filtered** /
**N examples replaced** / **Depth added**, joined as one line and hidden when
there is nothing to report. The trail reads persisted interaction state only
and never invents an entry: an attempted check selection counts and clearing
it removes the entry, a prediction counts once committed, the first stepper
stage is not "stepped through", a sorted table counts while a column is
actively sorted (cycling back to the authored order removes the entry), a
non-empty filter counts, and unknown state keys are ignored.
There is no full HTML renderer, embedded browser or generated JavaScript
execution. OpenUI's restricted declarative DSL runs only in its isolated worker,
not the shell; the block controls described above keep their existing engines.
Checklist selections are retained by the service within the same session.
**Copy** copies plain text, including chart point data, image credits and source
URLs; **More → Show as text** switches to that text representation. A
structured block that fails validation is dropped on its own (the answer text
and other valid blocks stay, with a short warning). Unparseable output, an
invalid envelope or an answer that cannot meet the 64 KiB cap still falls back
as a whole. Visual failures show an error rather than invented images or prices
and leave the answer usable.

Practical answers are **task-first workspaces**, not prose with a tool underneath:
the tool's title and short orientation lead into the main comparison, calculator,
plan, form or learning object. Long prose has an explicit **Read full explanation**
disclosure; Copy and Show as text still include the complete answer. Supporting
material follows, with sources last. Wide learning layouts put the diagram and
its linked control alongside each other; wide forms can have a context rail.
Narrow layouts reflow without resetting the tool. Plain/image briefs keep the
editorial layout: at widths of at least 620px the first image sits beside the
text, otherwise below it. The card sizes to measured content, capped at 720px
with scrolling.

Enter `ai:`, then try:
- `Tell me about Stanley Park.`
- `How did AAPL do over the past month?`
- `Chart my weekly run distances: Week 1 12 km, Week 2 18 km, Week 3 15 km, Week 4 22 km.`
- `What events are happening in Vancouver this weekend?`

### Images, charts and sources

- **Contextual images** are resolved by the app from a subject query through
  Wikipedia and Wikimedia Commons, not model-supplied image URLs. The app fetches
  the official thumbnail URL on `upload.wikimedia.org` or `thumb.wikimedia.org`
  without rewriting its host/path. QML reads only the trusted local raster cache,
  never arbitrary remote images. The retained service supplies the cache directory
  through `AiPane` to the answer renderer, including when `XDG_STATE_HOME` is set;
  it is a filesystem path, not a Qt file URL or a model-supplied value. Figures
  adapt to their available width and aspect-fit the whole image without cropping.
  Single figures avoid a full-width empty frame and use a default cap of
  620 × 340 pixels; the leading contextual figure uses a compact cap of
  300 × 320 pixels. Images use a plain, unlayered native `Image`, without
  effects or masks; corners may be square.
  Click a ready image, or focus its frame and press `Enter` / `Space`, to open
  the enlarged viewer. The frame stays keyboard-reachable while an image is
  loading or has failed — only the viewer keys wait for a ready raster — and it
  announces the loading or error status. The viewer sizes and centers the whole
  image within the viewport, leaving room for the controls and compact credit
  footer. **200%** zooms to
  twice the fitted size; **Fit** restores the whole-image view. Drag to pan,
  or `Tab` to the zoomed image and use the arrow keys. `Esc` closes the viewer,
  resets zoom and returns focus to the opening image frame. The hidden viewer
  clears its image source rather than eagerly loading a second raster; this
  alone does not establish Qt cache or GPU-memory reclamation.
  **Photo details** opens a native popup with full author, attribution, licence
  and source information, without opening the browser. Only **View source**
  navigates to the image source. `Esc` closes the popup before the launcher,
  and closing it returns focus to **Photo details**. An illustration is not
  proof of an event or claim. Footer actions wrap at narrow figure widths.
- **Comparison galleries** use equal-sized frames at the current layout width
  for portrait, landscape, loading and failed images. Every photograph remains
  aspect-fit and uncropped; unused space is intentional for comparison alignment.
  Full captions wrap below each image without truncation. Each item has its own
  photo details, the same enlarged viewer and an in-cell **Show another**
  replacement backed by a second candidate.
- **Market charts** fetch actual daily price points from Yahoo Finance outside
  the model. Charts show historical/delayed data and its source/as-of time,
  not a real-time quote feed, and cannot place trades. Ask for one
  month, three months or one year (`1mo`, `3mo`, `1y`) in your prompt or follow-up;
  there are no chart range buttons.
- **Generic charts** use matching labels and numeric values from data you provide
  or verified cited values, never fabricated series. Your supplied data uses an
  empty source and the as-of label **Provided data**. Hover to inspect a point;
  focus the chart by clicking it or using `Tab`, then use `Left` / `Right`,
  `Home` / `End` to inspect observations. Market charts use the same controls.
- **Sources** are compact labeled footer buttons. Clicking an answer source or
  chart source explicitly opens the browser; image credits first open **Photo
  details**, with browser navigation only through **View source**. Answers never
  open the browser automatically.
  Markdown citations in answer prose are moved into native source links;
  tracking parameters are removed and matching citations are deduplicated.
  This is not an embedded browser or an HTML/resource loader, and it does not
  grant the agent shell, filesystem or arbitrary-command tools.

At most two image/market requests are resolved per answer, within a per-answer
budget of 12 downloaded assets including gallery alternatives. Image downloads
and cached PNGs are limited to 3 MiB each, decoded images to 4 million pixels,
and output to a 960-pixel maximum dimension. The private media cache is under
`~/.local/state/omarchy/launcher-ai/media` (or `$XDG_STATE_HOME/omarchy/launcher-ai/media`), bounded to 32 MiB
with seven-day pruning on writes. Images require optional **Pillow** (installed
on this machine) to validate/decode and re-encode a PNG; without it they fail
safely with **Safe image decoder is unavailable**, rather than displaying
unvalidated bytes. Only decoded RGB pixels are retained; provider ICC/EXIF
metadata is stripped. Media loading runs in a credential-free supervised
process with a 25-second hard deadline, terminated on Stop or shell exit.
Provider/rate-limit errors are shown honestly.

From `f:` search, **Ask AI** or `Ctrl+Enter` explicitly attaches one text file
and fills an editable prompt without sending it. Its filename remains visible
with a **Remove** action. Only home-contained regular files are accepted, with
no-follow opens for every path component; directories and symlinks cannot be
attached. Non-CSV UTF-8 attachments retain the 64 KiB guard, including a second
check if the file grows after stat. Credential/secret-path and binary checks
are not a complete security guarantee.

**CSV attachment sampling** (manifest **1.21.0**) recognises `.csv`
case-insensitively and reads the first 8 MiB. It parses strict comma-separated
CSV with Python `csv.reader`, UTF-8 and optional BOM handling, preserving cell
whitespace. Ragged rows, malformed quoting and oversized fields produce
understandable turn errors without killing the broker worker. At the read
boundary an incomplete UTF-8 codepoint is withheld and an incomplete logical
CSV record is discarded, including quoted multiline records.

The provider receives a prefix snapshot: at most 200 data rows, 20 columns and
80 characters per header/cell, within 24,000 bytes of complete serialized UTF-8
JSON (including metadata, quotes and escapes). Column and header/cell loss are
disclosed separately as `columnsTruncated` and `cellsTruncated`, and contribute
to overall `truncated`. `totalRows` is exact only when the source was fully
read; otherwise it is `null`. Model guidance forbids whole-file aggregates from
a prefix sample and exact calculations or identifiers from clipped values.
This is a provider import/sampling foundation. The provider snapshot is **not**
the complete source, a type-correction UI, a full resource copy or a paged data
explorer; the launcher's separate local CSV preview (below) is a bounded review
surface that also never claims to hold the full dataset. A provider-authored
native table remains a bounded answer, not the source dataset.

**Forms.** When an answer needs several typed details from you (dates, a budget, a count), the
model can show a small form: numbers, choices, text and toggles with validation. Your answers
are sent as one follow-up that lists exactly what you entered, and your draft is kept across
restarts. **While it works**, the panel shows the real phase (thinking, searching the web) and
an elapsed counter after 3 seconds; answers from Codex arrive whole, not progressively.

**Choices, comparisons and plans.** An answer can offer bounded action buttons
that send a chosen follow-up, a comparison with locally pinned/hidden options,
or an authored-order timeline with completion checks and a duration total when
at least two durations are supplied. Comparisons lead with the AI's authored
recommendation and trade-offs. When columns would be too narrow, a shortlist
shows every candidate and one inspected detail view. Selecting a name only
inspects; **Continue with…** explicitly sends an AI follow-up. Plans put progress
and the first unfinished item first, with a jump to its actual row. Completion
never invents or reschedules clock times. **Ask about this** targets a part of the
latest answer in the composer; the next explicit question carries that context,
not an instruction to rewrite the original answer. These controls have offline
coverage; their live interaction qualification is still pending (see Tests).

**Calculations.** For numbers you can vary (weights, rates, a budget), the model can
author one `calc` block: numeric inputs with sliders and typed values (each marked
assumption, provided or sourced), computed tables, and derived cells with units. Every
number can show its formula, inputs and units under "How is this calculated?"; errors show
as an em dash with the reason, never a silent zero. Money is an ISO currency code and
cross-currency math needs an explicit rate input. Values you change persist with the
conversation. The math runs locally in a small hand-written engine with strict limits.
You can edit table cells (decimal point only, invalid values are refused with a message),
add or remove rows, save up to three named input scenarios and compare them side by side,
undo and redo while the view is open, copy the values as CSV, and duplicate a calculation
as a new editable copy.
Scenario exports are not yet equivalent to the on-screen comparison: CSV omits
per-table formula results, and copied Markdown also omits differing scenario
inputs. Opening comparison does not yet scroll it into view, pane PageDown is
missing, and the whole-workspace saved-edit limit has no visible refusal notice.

**Keep full data.** After the local preview is ready, **Keep full data** explicitly
copies the `.csv` (up to 64 MiB / 500,000 rows) into private launcher storage
(`<state>/sources/src-<id>/`) and indexes it once. Expand the panel to open
**Explore all rows**: 25 rows per page, whole-file sort (by character code) and
literal substring filter, exact row counts, First/Prev/Next/Last and Go to row.
The model then also receives exact whole-file count, empty count, min, max, sum
and mean for the first 20 columns; medians, quantiles, correlations and group-bys
are declined, not guessed. The copy belongs to its conversation and is removed
when that conversation is deleted; nothing automatic ever deletes conversations.

Attaching a file whose name ends in `.csv` also starts a separate **local
preview** for review before sending: the pane shows *Reading CSV…*, then a
bounded grid of at most 10 rows × 20 columns (80 Unicode codepoints per cell)
with literal cell text, the counts ("N of M rows · …"), the sampler note and
the truncation disclosures — or a readable error with **Retry** and **Remove**.
While the current CSV is reading or failed the attachment is gated, so Enter,
**Send** and the test-only `submitfile` cannot dispatch; a newly attached CSV
returns `previewing` and never sends by itself. The grid scrolls with the
arrow/Page keys inside a focus ring, scrollbar tracks appear only when the
content actually overflows, and the footer states that the source is read again
when you send. Nothing is imported, typed or executed: no credentials reach the
fixed-argv worker, the model gets no file tool, and the status IPC reports
preview metadata only (`previewStatus`, `previewRows`, `columnCount`,
`totalRows`, `truncated`, `columnsTruncated`, `cellsTruncated`,
`previewError`) — never the CSV contents or the attachment path.

Closing the card does not stop work. The retained service preserves the chat
and checklist state across ordinary close/reopen and panel hot reload, and the
workspace store restores it after a shell restart (see the paragraph above).
Completed answer text and native blocks appear while the app
loads visuals in the background. Use **Stop** to explicitly cancel a response;
stopping during visual loading retains that answer and marks unfinished visuals
as stopped.

**More → Continue in terminal** resumes the same agent session when the adapter
provides a valid handoff, not a desktop-app deep link. Codex continuation uses
the launcher's private Codex home when its adapter supports it. OpenCode has no
launcher handoff button yet, but its sessions are stored in your OpenCode
database and can be resumed with `opencode --session <id>`. Use the standard
terminal agent workflow for full agent permissions outside the launcher;
continuation itself does not promise a permission upgrade.

---

## 📦 Enable / remove

The launcher is already present under `~/.config/omarchy/plugins/rosakodu.launcher`.
File search requires `python3` and `fd`, both already available on this machine.
Enable/disable it in `~/.config/omarchy/shell.json` (plugin list), or:

```bash
omarchy-shell shell setPluginEnabled rosakodu.launcher true   # enable
omarchy-shell shell setPluginEnabled rosakodu.launcher false  # disable
```

The manifest has separate menu and service entry points with `keepLoaded`:
closing hides the panel rather than unloading the retained AI service.
Disabling/removing the plugin is independent of the dock; close alone is not
removal. Stop any active response first.

Remove it completely (independent of the dock):

```bash
omarchy-shell shell setPluginEnabled rosakodu.launcher false
rm -rf ~/.config/omarchy/plugins/rosakodu.launcher
omarchy-shell shell rescanPlugins
```

Recents are stored in `~/.config/omarchy/launcher-recents.json` (optional user
data; safe to delete).

The dock's apps button opens this launcher when it is enabled and falls back
to the stock apps menu (`omarchy-menu toggle apps`) otherwise. The card
emerges from the Apps glyph itself and collapses back into it when dismissed;
a second click on the glyph closes the launcher.

---

## 🔌 IPC (test-only entry points)

```bash
omarchy-shell rosakodu.launcher open      # open the launcher
omarchy-shell rosakodu.launcher close     # close + hide (service retained)
omarchy-shell rosakodu.launcher toggle    # toggle
omarchy-shell rosakodu.launcher status    # JSON diagnostics (rows, recents, state)
omarchy-shell rosakodu.launcher ping      # liveness check
omarchy-shell rosakodu.launcher searchFiles 'config hypr' # file-search query diagnostics
omarchy-shell rosakodu.launcher ai         # open AI mode without submitting
omarchy-shell rosakodu.launcher query 'notes' # open with an ordinary search query
omarchy-shell rosakodu.launcher expand     # toggle the Explore card (returns the new state)
omarchy-shell rosakodu.launcher window     # open (or focus) the detached workspace window
omarchy-shell rosakodu.launcher newchat    # start a fresh conversation (keeps the finished one)
omarchy-shell rosakodu.launcher submit 'text' # test-only: drive the exact submit path without keyboard input
omarchy-shell rosakodu.launcher submitfile 'prompt' "$HOME/sample.csv" # test-only: attach; a new CSV returns "previewing"
omarchy-shell rosakodu.launcher depth 'simpler|deeper|example' # test-only: adaptive-depth action on the latest learning answer
omarchy-shell rosakodu.launcher swap '0' '2' # test-only: cycle gallery item (block 0, item 2) through the in-cell Show another path
```

These are development/verification hooks; everyday use is through the `Super`
binding described above.
`submitfile` (shared with `AiState.submitFile`) rejects busy/stopping, loading
and invalid requests before changing the draft or attachment. Attaching a CSV
returns `previewing` (or `attachment-error`) without sending anything: the local
preview must reach `ready`, and a second explicit submit is required. A ready
CURRENT attachment, or a non-CSV file, still calls the same `submitAi()`
synchronously. It is not a model-granted file tool; users still attach via `f:`
**Ask AI** / `Ctrl+Enter` and review before sending.

---

## 🧪 Tests

Native OpenUI verification (2026-10-26, OpenCode/validation checkpoint):
**21 worker tests**, **666 Python tests (2 skipped)**, **1,802 main QtTests**,
29 blocks / 23 visual / 12 answer / 6 task-visual, and all ten isolated checks in
`tests/run_offline.py` (including `AiOpenUiRuntimeCheck` and
`AiOpenUiServiceCheck`) are green. `python3 -B tests/build_openui.py --check`
rebuilt the worker in scratch and found the generated assets byte-identical;
`scripts/audit.py` passed. Coverage includes bounded IPC, timeouts/cleanup,
queued semantic retarget rejection (including distinct authored conditional Copy
actions), saved-state restore/opaque duplication, historical-tool selection,
follow-up context, OpenCode JSON-stream/session handling, mise-shim discovery
rejection, and the validate/repair/fallback path. Live checks used the installed
plugin subtree; scratch/offscreen suites still do not qualify Wayland/mixed-DPR.

One real Codex garden tool was generated through the production broker in
27.58 seconds; its exact DSL replayed through native `AiService`/`AiAnswer` at
420/980px. Both showed 72 initial positions with SVG dots, then 48 after changing
length to 3.6 m and spacing to 30 cm. Inspected screenshots:
`/tmp/opencode/native-openui-visual-qsgbpwid/opaque-garden-420.png` and
`opaque-garden-edited-980.png` in the same directory. The QQuickItem alpha grabs
were composited over the actual `#202124` Window background. That earlier Codex
sample and offscreen replay are **not a reliability benchmark or a
Wayland/mixed-DPR pass**; the OpenCode live pass below is the current deployment
evidence.

Live OpenCode/OpenUI pass (2026-10-26, installed plugin subtree, default agent
`opencode`, DP-1 3440×1440 at scale 1.25): a new tip-splitter conversation
produced one valid native tool in about 14 s. A follow-up changed the defaults
to a 100 bill / 20% tip in about 13 s and kept the same OpenCode session. Live
keyboard interaction set the bill to 150; the tool showed tip 30, total 180 and
90 each. The authored reset returned 100 / 20 / 60. A full shell restart restored
the tool with the edited `$bill: 150` state and recomputed 180 / 90. Screenshots
`/tmp/opencode/live-opencode-openui-2.png` … `-10-reset.png` were read and
inspected. The first pre-fix live attempt exposed a mise-shim discovery bug
(fixed); a later pre-fix tool used a label as `SegmentedControl`'s boolean
`block` argument and was rejected by the runtime. The prompt was hardened and
the broker now validates and repairs/omits rejected tools. The post-fix live
generation was valid without needing the repair. The repair path is unit-tested
and was manually validated once against the real model (9.4 s), but was not
observed end-to-end in the QML panel. Native OpenCode was exercised through the
installed broker with the live environment and state root, not through the
panel. OpenCode launcher sessions are stored in the user's own OpenCode database
and appear in its session list. Mixed-DPR and a second display scale remain
unrecorded.

Historical custom UI visual checks (2026-10-23): `tests/AiTaskVisualCheck.qml`
renders actual native answer components with illustrative decision/plan/form fixtures at
420/760/980px, restored plan progress and light/Crimson Gold palette variants.
The screenshots `/tmp/opencode/ai-task-*.png` were read and inspected. Inspection
and restoration emit no provider action. These are offscreen checks, not a live
provider-quality, Wayland or mixed-DPR pass. The transition regression in
`tests/tst_AiComposition.qml` fails on QML warnings when replacing task shapes.
Final offline verification: **630 Python tests (2 skipped), 1,765 main QtTests,
28 blocks / 23 visual / 12 answer / 6 task-visual**, with all eight isolated
checks listed below passing. Image/task/text transitions have warning-failing
regressions; known Qt lint/Python resource warnings remain. Logs:
`/tmp/opencode/launcher-task-finish-i4v22dwg/`. No release or repository sync.

Resume verification (2026-10-22; installed tree, unreleased additions, manifest
still **1.22.0**): **624 Python tests (2 skipped), 1,710 main QtTests,
28 blocks / 23 visual / 12 answer**, all green. The main total includes eight
new strict-equality helper checks. All eight isolated checks passed:
`AiServiceCheck`, `AiWorkspaceStoreCheck`, `AiWorkspaceContextCheck`,
`AiSeamsServiceCheck`, `AiCsvSourceCheck`, `AiAttachmentPreviewCheck`,
`AiPreviewServiceCheck`, `AiDetachedWindowCheck`. Runs used fresh scratch
HOME/state/runtime/cache/config, offscreen/software rendering and unset
`LAUNCHER_*` flags; no real provider or live user state was used. Existing
Python `ResourceWarning`s remain. Test-only fixes use
`verify(TestJson.equal(...))` (`tests/TestJson.js`, with `tst_TestJson.qml`
regressions): strict recursive leaf types/values, exact numbers and array order,
ignoring only object key order. A 1e-6 numeric difference is explicitly rejected;
this avoids both QVariant key reordering and QtTest's numeric tolerance.
The fake Codex fixture was also repaired/isolated
after `new` clears its prepared state; no product feature was built.
Recorded evidence is in `/tmp/opencode/launcher-status-20261022-6ts2myhe/`:
`python-final.log`, `qml-final.log`, `blocks-final.log`, `visual.log`, `answer.log`
and each `<Checkname>.log` (earlier logs record pre-fix failures).

The October 8 checkpoint was not the latest implementation: October 9–10 added
calc edits/scenarios/undo/export/local duplication, forms, actions/comparison/
timeline, selected-part follow-ups, Codex prompt de-duplication/timing and soft
block failures. The recorded October 10 live calc pass covered keyboard grid
editing, undo/redo, scenario save/compare, CSV copy, local duplication and restart
restore; it did not close the comparison reveal/paging, export-parity or visible
`stateNotice` gaps. Dynamic-control/focus live clicks and the compare-body/stale-QML
issue remain unqualified. Mixed DPR and a Phase 3 exit are not claimed.
Canonical `~/Work/myarchy` remains clean at launcher commit `0a4ba8e`
(October 6); the initial audit found 94 installed files different/new before
the new test-helper files. No sync, release, commit or push was performed.
The dated checkpoints below are historical, not current
suite totals. See `AI_WORKSPACE_PLAN.md` for the reconciled remaining work.

Reusable-tools slice (2026-10-08, unreleased; manifest unchanged): offline
verification passed 418 Python tests (two skipped; existing `ResourceWarning`s
remain), 1,077 main QtTests, isolated service and real-store checks
in scratch HOMEs, and the detached-window check. Wide Rename and narrow Duplicate
form screenshots were read and manually inspected using mock/offscreen surfaces,
not the live shell. Independent review findings received regression fixes;
live Rename/Duplicate qualification remains pending. These results do not imply a release, repository sync or new
Wayland/mixed-DPR qualification.

The reviewed 1.21.2 checkpoint fixes workspace switching/loading races, 20-turn
content persistence, private storage and the shared media budget. Thin saves
preserve omitted content; full snapshots explicitly retire obsolete keys.
Regression coverage also pins readable depth geometry, hero-image replacement,
keyboard scrolling/hidden controls, and Python/JS real-domain formula parity.
These checks are not a new live Wayland or mixed-DPR qualification.

Long drafts grow to 170 px then scroll natively with the caret; Send/Stop remain
pinned. Legacy transcripts are bounded on restore before being resaved, and
formula readouts reject invalid intermediate arithmetic rather than masking it
with a later operation. Scientific-notation exponents remain intact.

The ready-gallery keyboard test uses a tiny, metadata-free RGB fixture at
`tests/fixtures/media/gallery.png`; no previously generated scratch image is
required. Test helpers and fixture assets are part of the local-plugin restore
allowlist. Use a scratch `HOME` and `XDG_STATE_HOME` for integration checks;
never point an automated store check at saved user workspaces.

Run from the plugin directory:

```bash
python3 -B tests/build_openui.py --check  # scratch rebuild; --write explicitly updates assets
python3 -B tests/run_offline.py          # preferred: every suite gets private scratch HOME/XDG
# Individual commands below also require private scratch HOME/XDG, never live state:
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software /usr/lib/qt6/bin/qmltestrunner -input tests
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software /usr/lib/qt6/bin/qmltestrunner -input tests/AiBlocksCheck.qml
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software /usr/lib/qt6/bin/qmltestrunner -input tests/AiVisualCheck.qml
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software /usr/lib/qt6/bin/qmltestrunner -input tests/AiAnswerCheck.qml
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software /usr/lib/qt6/bin/qmltestrunner -input tests/AiTaskVisualCheck.qml
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_*.py'
QT_QPA_PLATFORM=offscreen quickshell -p FileSearchProcessCheck.qml
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software quickshell -p AiServiceCheck.qml
XDG_STATE_HOME=/tmp/opencode/store-check QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software quickshell -p AiWorkspaceStoreCheck.qml
# AiAttachmentPreviewCheck / AiPreviewServiceCheck need a dedicated
# /tmp/opencode/ai-preview-check-* HOME with a nested XDG_STATE_HOME
# (they refuse a real home directory); AiDetachedWindowCheck accepts any
# /tmp/opencode/ scratch HOME:
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software quickshell -p AiAttachmentPreviewCheck.qml
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software quickshell -p AiPreviewServiceCheck.qml
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software quickshell -p AiDetachedWindowCheck.qml
```

The main QtTest suite includes `AiComposer`, `AiPane`, `AiState` and integrated
`AiWorkspace` coverage, including keyboard focus, exact draft preservation,
content/toolbar sizing at wide and narrow widths, and the collapsed-history
regression test: an older answer tree must not exist while history is
collapsed, must materialise when expanded, and must be released again when
collapsed. The pane suite also covers adaptive depth: the latest learning
answer shows the **Simpler**/**More depth**/**Another example** actions and each
button reaches `explainLatest` with its mode, plain answers hide them, and the
sidecar renders the stored prose. The trail is covered too: `AiPane` renders
persisted interactions as one line under the right turn and hides it for
untouched answers (`test_explorationTrailRendersPersistedInteractions`), while
`AiState.trailSummary` is pinned key by key in the state suite
(`test_trailSummaryRecordsExploration`, now also covering the **Sorted** and
**Filtered** table entries). `AiWorkspaceStoreCheck.qml`
drives the real service against the real store worker in a scratch
`XDG_STATE_HOME` and verifies the save/load round trip, interrupted-turn
recovery and checklist restoration. As of 1.21.1, `AiServiceCheck.qml` uses
the bundled `tests/ai_service_stub.py` for both store and broker protocols:
no provider calls, filesystem reads/writes or external scratch-script dependency.
It verifies injected helper paths and the scratch root before enabling storage.
Earlier claims of isolation via readonly-property overrides are superseded;
those overrides could be silently ignored. `AiServiceCheck.qml` additionally covers
service state, pinning and stale-event rejection plus the lazy-restore phases —
metadata-only boot, exactly one latest load on real entry, gated submit,
watchdog settle and in-flight draft survival — and the broker-idle gate (a
fresh service never idles a non-started broker; a hidden, idle broker is
eligible for shutdown; the visible panel, the detached window or a running job
keeps it warm), plus the coalesced save-payload shapes (thin for a draft-only
edit, full for a content change, the dirty flag consumed by the full save) and
adaptive depth (a busy answer rejects depth requests; an `explain` event lands
on the latest turn, clears busy and persists in the snapshot), against a stub
store with a marker-free asynchronous settle.
The Python store tests cover the serve-mode worker directly: burst ordering
with in-band static error results, idle and EOF exits, the worker error
contract including an empty store's null load, and the partial-save contract —
a save carrying only the workspace row must leave stored artifacts and
interaction rows intact, with a later full save staying consistent. The broker guardian tests cover
the event-driven wait: a natural child exit passes through (exit 7) and a
SIGTERM wake returns 128+15 with the group leader torn down. Broker tests also
cover session resume across a broker restart: a fresh Broker resumes
`resume abc -` in the provider argv after `stop()`, and session hints outside
`[a-zA-Z0-9_-]{1,128}` never reach the provider argv. Adaptive-depth broker
tests pin the explain contract — prose only with structured blocks dropped and
no done/presentation/delta events, an empty explanation as an error — and the
stale-resume fallback, which now covers explain runs, is pinned by
`test_stale_resume_falls_back_to_fresh_session`.
Run `tests/AiBlocksCheck.qml`, `tests/AiVisualCheck.qml` and
`tests/AiAnswerCheck.qml` explicitly as above; their names are not picked up
by normal `tst_*.qml` discovery. These checks cover native blocks, table
sorting and filtering, image/chart controls, photo-credit disclosure and
focus, responsive answer layout, measured sizing, gallery-item replacement and
trusted-cache forwarding. Installed-CLI localhost audits
are opt-in: set `LAUNCHER_CODEX_OFFLINE_AUDIT=1` and
`LAUNCHER_HERMES_OFFLINE_AUDIT=1` when running the Python suite. These audits
verify that Codex advertises exactly hosted web search and Hermes no tools,
including resumed requests.

Medium selection has its own benchmark, deliberately not part of the offline
suite: `ai_bench.py` drives the **running** shell through the
`newchat`/`submit`/`status` IPC, waits for each answer, then reads the newest
artifact read-only from the workspace database under a bounded settled-read
retry — a stored pre-enrichment **Loading visual…** snapshot from the autosave
is treated as unsettled, while a genuine provider error is settled — and
evaluates structure against the versioned 30-prompt
`bench-prompts.json` (8 learning / 8 exploration / 8 mini-app / 6
simple+mixed+failure, with `blocksAny` / `blocksNone` / `needsImages`
expectations and `maxSeconds` notes). It prints one line per prompt and writes
a JSON report with a by-kind summary, exiting non-zero when any prompt fails.
It needs a running shell and a signed-in provider, and it makes **real**
provider calls. Six offline tests in `tests/test_ai_bench.py` pin prompt
validation, expectation evaluation (slow is a review note, not an automatic
failure), image checks, the newest-revision read, loading-placeholder detection
(a genuine provider error is settled) and the summary.

```bash
python3 ai_bench.py --prompts bench-prompts.json --limit 6 --out results.json
```

Latest verification for CSV sampling and table focus (2026-10-05, manifest
**1.21.0**): 107 main QtTests, 15 blocks, 23 visual and 11 answer checks passed;
161 Python tests (2 skipped with the normal offline-audit flags unset), plus
isolated `AiServiceCheck` and `AiWorkspaceStoreCheck` with scratch state. No
test failures. `qmllint` reported no errors, but existing standalone
`qs.Commons` resolution, Quickshell, old state-override, unqualified-access and
`MoveAnchor` warnings remain; this is not a warning-free result. Existing
Python `ResourceWarning`s from database/test pipes also remain.

Broker regression coverage pins serialized UTF-8/escape byte bounds, contiguous
prefix rows, clipping disclosure, whitespace preservation, strict malformed and
ragged-row errors, BOM/multiline parsing, incomplete read-window records and
UTF-8 codepoints, and worker reuse after malformed/oversized-field errors with
the snapshot charged once. `AiBlocksCheck.test_tableSortsAndFiltersLocally`
now exercises an actual keyboard filter edit and its scoped state emission,
and asserts the visible focus ring. The filter uses `activeFocus` (`visualFocus`
is not a `TextField` member); `tableState` avoids shadowing `QQuickItem.state`.

Live verification used the corrected eight-row synthetic fixture
`~/rents-sample.csv`: all eight native table rows matched the fixture
unchanged. A concurrent `submitfile` returned `busy` and left the empty draft
and attachment untouched. Tab + Return sorted the rent header ascending; typing
`o` with real `wtype` narrowed it to Porto 600, Lisbon 900 and Oslo 1200, with
**3 of 8 rows** and the **Sorted · Filtered** trail. A full shell restart
visually restored the same rows, count, arrow, filter and trail. Saved workspace
`ws-52ce449a43c89ab5`, turn 92:
`{"92":{"table:0":{"dir":1,"filter":"o","sort":1}}}`.
`/tmp/opencode/csv-live-table.png`, `/tmp/opencode/csv-live-filtered.png` and
`/tmp/opencode/csv-live-restored.png` were read and visually inspected; earlier
captures alone did not establish that verification.

An isolated **sampling-only** stress fixture had 100,000 numeric rows × 20
columns (14,989,091 bytes). Snapshot time was 0.202 s, returning 140 prefix rows
in 22,157 JSON bytes with `totalRows: null`; process peak RSS was 82,020 KiB,
including the full Python process and fixture generation, not incremental
memory or PSS. Record: `/tmp/opencode/csv-sampling-stress.json`. This does not
qualify native UI responsiveness or the full 100k-row dataset exit gate. Later
checks recorded in `AGENTS.md` cover kept-source paging, restart persistence,
preview type correction and the typed calculation runtime, including a live
slider change and its restart restoration. Full resource qualification,
live corrected-type delivery to the model, calc provenance/typed-field interaction
and mixed-DPR remain outstanding.

Verification for the Phase 3 opener (2026-10-04, manifest **1.20.0**):
107 main QtTests, 15 blocks, 23 visual and 11 answer checks passed; 156 Python
tests (2 skipped). Lint had no errors, not a warning-free result. The comparison
table is now a
local tool, covered by `AiBlocksCheck.test_tableSortsAndFiltersLocally`: each
header activation emits exactly one scoped state edit (key `table:0`), the
numeric-aware ascending order puts Bike (0) before Car (75), the header cycles
ascending → descending → authored order, filtering reports "1 of 4 rows", and
the literal-substring proof — `train|bus` matches nothing — pins that filter
text is never evaluated as a pattern. The trail unit tests cover the new
**Sorted** and **Filtered** entries (`test_trailSummaryRecordsExploration` in
`tests/tst_AiState.qml`). Live run:
`Tab` reached `aiTableHeader_0`, `Return` cycled the column to descending, the
state persisted as `{"88":{"table:0":{"dir":-1,"filter":"","sort":0}}}` and
survived a full shell restart restore.

Verification for the keyboard/accessibility refinement (2026-10-04, manifest
**1.19.3**): 107 main QtTests,
23 visual, 14 blocks and 11 answer checks passed; 156 Python tests (2 skipped —
six benchmark tests), `AiServiceCheck` green, and `qmllint` was clean on the AI
QML files. The keyboard/accessibility refinement walked the live Tab chain
end-to-end on real answers — composer → answer summary → diagram parts (each
selectable) → stepper controls and advance → **Simpler** / **More depth** /
**Another example** → **Copy** → toolbar → back to composer; each gallery cell
walks frame (viewer) → **Photo details** → replacement, and the reverse walk
visits the same ring. A restore-time walk initially skipped gallery cells
because the frame's focusability was gated on `imageReady`; `AiImage`'s frame
is now always focusable when visible — viewer keys stay guarded on
`imageReady` — so loading and errored images are keyboard-reachable too, with
the status text as the accessible name and a focus ring in every state; after
the fix the restore walk enters all cells immediately. New offscreen coverage:
`test_galleryCellsEnterTheKeyboardChain`. Theme resilience was verified live by
switching the theme to Kanagawa and back: the surface repainted from the
injected tokens with state intact and no shell-log errors (**Crimson Gold**
restored). Scaling was only the real fractional condition (DP-1, scale 1.25);
a second scale was not exercised.

Verification for the typographic refinement (2026-10-04, manifest
**1.19.2**): 106 main QtTests,
23 visual, 14 blocks and 11 answer checks passed; 156 Python tests (2 skipped —
six benchmark tests), `AiServiceCheck` green, and `qmllint` was clean on the AI
QML files. The typographic refinement (Design language, below) changed no
rendered size by construction, and a live hot-reload cycle stayed open with no
shell-log errors. The refactor also exposed a missing `SatinGlass.js` import in
`AiButton.qml` that `qmllint` did not catch: it failed only when the suites
instantiated the components. The reusable lint-versus-instantiation rule is in
`AGENTS.md`.

Verification for the loading-placeholder fix (2026-10-04, manifest
**1.19.1**): 106 main QtTests,
23 visual, 14 blocks and 11 answer checks passed; 156 Python tests (2 skipped —
six benchmark tests now), `AiServiceCheck` green, and `qmllint` was clean — it
does not cover `ai_bench.py`, which is Python. The first full 30-prompt
medium-selection pass ran end-to-end on real output: the raw single-shot score
was **23/30**. Triage found two causes that were not selection failures. The
harness could read the autosave's pre-enrichment **Loading visual…** snapshot
while slow media resolution was still running; the bounded settled-read retry
now treats the loading placeholder as unsettled and a genuine provider error
as settled (`test_loading_placeholder_detection` pins both). Three mini-app
expectations were narrower than the plan's vocabulary, so `budget`/`decision`/
`recipe` now also accept `checklist`/`steps`/`metric` where appropriate. After
the harness fix and that calibration — styles, birds and posters all re-ran
clean, and the three mini-app results were re-scored offline — the consolidated
baseline is **29/30**, with one environment failure: `explore-clouds` was
blocked by Wikimedia rate-limiting under benchmark load. By kind: learning 8/8,
exploration 7/8, mini-app 8/8, simple 3/3, mixed 2/2, failure 1/1 — above the
plan's 80% target for this baseline. The caveats stay explicit: the raw number
was 23/30, one prompt is environment-blocked, medium selection remains
non-deterministic, and the 29/30 figure combines the original run, two targeted
re-runs and offline re-scoring of calibrated expectations — it is not one clean
30-prompt run.

Verification for the medium-selection harness (2026-10-04, manifest
**1.19.0**): 106 main QtTests,
23 visual, 14 blocks and 11 answer checks passed; 155 Python tests (2 skipped —
five new benchmark tests), `AiServiceCheck` green, and `qmllint` was clean — it
does not cover `ai_bench.py`, which is Python. The medium-selection benchmark
landed (above) with the first honest live findings: a four-prompt smoke passed
3/4 (the one failure was the harness reading before the settled save landed,
fixed with the bounded retry), and a six-prompt baseline passed 4/6 — one
failure was Wikimedia rate-limiting a gallery request (now surfaced in the
verdict note) and the other was model variance (the predict prompt answered in
prose). The first genuine medium-selection finding came from repeated
architecture runs: the model drifted to tables for recognition tasks until the
gallery rule in `ai_catalog` was strengthened ("when the user wants to
RECOGNISE or IDENTIFY something visual, prefer the gallery so they can actually
see the differences"), after which it selected the gallery again. The first
full 30-prompt pass and its consolidated 29/30 baseline followed in 1.19.1
(above).

Verification for the exploration trail (2026-10-04, manifest
**1.18.1**): 106 main QtTests,
23 visual, 14 blocks and 11 answer checks passed; 150 Python tests (2 skipped),
`AiServiceCheck` green, and `qmllint` was clean. The exploration trail landed:
`AiState.trailSummary(turn, uiState)` derives one short line from persisted
interaction state only — "Checked" / "Predicted" / "Stepped through" /
"Scrubbed" / "N examples replaced" / "Depth added", " · "-joined and empty
when there is nothing to report — and `AiPane` renders it under each turn
(`aiTrail`), so it restores with the workspace. New coverage:
`test_trailSummaryRecordsExploration` (`tst_AiState`, key by key: an attempted
check selection counts and clearing it removes the entry, a prediction counts
once committed with the stored choice index, step index 0 is not "stepped
through", unknown state keys never invent an entry) and
`test_explorationTrailRendersPersistedInteractions` (`tst_AiPane`: persisted
state renders, untouched answers stay hidden). The same persisted state keys
satisfy the resumable-learning-position requirement — step, slider, diagram,
check and predict state restore with the workspace; live evidence from the
coupled slider+diagram check: `{"11":{"slider:1":12}}` after a full shell
restart. Honest note: the trail line itself is offscreen-covered; the live
evidence above is persisted-state restore, not a live sighting of the
rendered line.

Verification for the gallery-replacement slice (2026-10-04, manifest
**1.18.0**): 104 main QtTests,
23 visual (one new), 14 blocks and 11 answer checks passed; 150 Python tests
(2 skipped, including the new media test), `AiServiceCheck` green, and
`qmllint` was clean. Architectural-styles flagship acceptance run through the
real entry flow: "Help me recognise Gothic, Romanesque and Renaissance
architecture" produced a resolved three-item gallery; gallery items now
resolve two candidates each (media budget widened from 9 to 12 assets/answer
to accommodate a 6-item gallery with alternatives), so an example can be
replaced without resetting the comparison through its in-cell **Show another**
and its own `gallery:<block>:<item>` uiState key. Live-verified: items 0 and 2
were replaced independently while item 1 stayed untouched, persisted as
`{"10":{"gallery:0:0":1,"gallery:0:2":1}}`, and restored intact after a full
shell restart. The test-only `swap '<blockIndex>' '<itemIndex>'` IPC cycles a
gallery item's alternative through the same state path the in-cell button
uses. New coverage: `test_gallery_items_offer_replacement_candidates` (media
resolution) and `test_galleryItemReplacementStateIsScoped` (`AiVisualCheck`:
exactly one state edit, key `gallery:0:0`, value 1 — also pinning that the
swap does not reset the neighbours). Honest note: one combined full-suite run
under load saw a transient error in the opt-in installed-CLI localhost
audits; three isolated reruns were green.

Verification for the seasons flagship (2026-10-04, manifest **1.17.3**):
104 main QtTests, 14 blocks, 11 answer and 22 visual checks passed; 149 Python
tests (2 skipped), the
isolated service and store checks (`AiServiceCheck`, `AiWorkspaceStoreCheck`)
passed green, and `qmllint` was clean. Seasons flagship acceptance run through
the real entry flow: the question "Teach me why the seasons happen, with a
diagram and a month slider I can scrub" produced a 7-part orbit diagram plus a
month slider (1–12, value 6, labels Jan–Dec, two links driving the orbit part's
x/y, honest note "approximate; reversed in the Southern Hemisphere");
**Simpler** persisted a prose sidecar on the same turn; the transfer follow-up
"If it is summer in Australia right now, roughly what month is it, and why?"
was answered correctly from the tilt concept (October is not Australian summer;
it runs roughly December–February when the Southern Hemisphere tilts toward the
Sun); and a full shell restart restored the conversation (2 turns, workspace
id, blocks and explanation). Acceptance screenshot:
`/tmp/opencode/journey-acceptance-crop.png`. The run also exposed and fixed a
real 1.17.3 bug: after **New chat**, `restoreSettled` was set false and never
became true again, so the autosave gate suppressed every save until a launcher
close — a crash or kill in that window lost the fresh conversation.
`newConversation` now sets `restoreSettled = true` (nothing is pending that
could overwrite a fresh conversation; the gate only needs to cover in-flight
restores), and `AiServiceCheck` asserts that a fresh conversation must be
immediately persistable. Honest framing: the suppression was introduced with
the lazy-restore gate in 1.13.0 and only a full journey run exposed it.

Verification for the guidance fix (2026-10-04, manifest **1.17.2**): 104 main
QtTests, 22 visual, 14 blocks and 11 answer checks passed; 149 Python tests (2
skipped) including 14 resource-probe fixtures and both installed-CLI audits;
`qmllint` was clean. The 1.17.2 fix appends `EXPLAIN_GUIDANCE` exactly once in
the broker's command handler (before size/context accounting), so a stale-resume
retry cannot duplicate the mode text — pinned by
`test_explain_retry_includes_guidance_once`.
The adaptive-depth
delta added **Another example** (`aiDepthExample` → `explainLatest("example")`,
treatment text "another example"), tightened `EXPLAIN_GUIDANCE` so "another
example" means one fresh, specific situation (a place, object or everyday case)
showing the same idea, not a restatement of the mechanism, and extended the
stale-resume fallback to explain runs: any run that adopted a persisted session
hint now retries once from a fresh session when the provider rejects the
resume. `tst_AiPane` clicks all three depth actions. Provider processes load
`ai_broker.py` at spawn, so guidance edits apply to the next broker start (idle
retirement or shell restart). Live checks on the shared shell: after a restart,
a sky-blue submit and **Another example** produced a sunset-red example
persisted with the blocks untouched.

Verification for the adaptive-depth slice (2026-10-04, manifest **1.17.0**):
104 main QtTests, 22 visual, 14 blocks and 11 answer checks passed; 148 Python
tests (2 skipped) — the previous counts plus the adaptive-depth coverage —
including 14 resource-probe fixtures and both installed-CLI audits. The new
broker tests pin the explain contract (`test_explain_emits_prose_sidecar_only`: prose only, any
structured blocks dropped, no done/presentation/delta events;
`test_explain_rejects_missing_text`: an empty explanation is an error;
`test_stale_resume_falls_back_to_fresh_session`: a rejected session hint
retries once from a fresh session), `AiServiceCheck` asserts the depth receive
path (a busy answer rejects depth requests; an `explain` event lands on the
latest turn, clears busy and persists in the snapshot), and the pane suite
gained `test_adaptiveDepthActionsAndSidecar` (depth actions on learning
answers, hidden on plain ones, sidecar text). `qmllint` was clean.
Live checks on the shared shell (manifest 1.17.0): a restart, AI entry and
`submit seasons` produced a diagram+slider answer; `depth simpler` then
produced a prose explanation persisted on the turn with the blocks untouched.
The same live run surfaced the stale-session failure the fallback fixes: a
restored conversation's persisted session reference could be stale after a
shell restart and hard-fail every follow-up.
Verification for the previous slice (2026-10-04, manifest **1.16.0**):
103 main QtTests, 22 visual,
14 blocks and 11 answer checks passed; 145 Python tests (2 skipped) — the
previous slice plus the new partial-save store test — including 14
resource-probe fixtures and both installed-CLI audits. The store suite gained
`test_partial_save_preserves_stored_content`: a draft-only save (thin payload
with empty artifact/interaction lists) leaves the stored artifacts and
interaction rows intact, and a later full save remains consistent. The main
suite still pins the uninstantiation contract via
`test_collapsedHistoryDoesNotInstantiateHeavyAnswers`: while
history is collapsed the older answer tree does not exist, expanding
materialises it, and collapsing releases it again. The
isolated service and store checks (`AiServiceCheck` with a stub store and
marker-free async settle, `AiWorkspaceStoreCheck` with scratch state) passed
green, with `AiServiceCheck` now asserting the coalesced save-payload shapes as
well — thin for draft-only edits, full for content changes, dirty flag
consumed — alongside the broker-idle gate: a
fresh service never idles a non-started broker, a hidden idle broker is
eligible for shutdown, and the visible panel, the detached window or a running
job keeps it warm. `qmllint` was clean.
Live checks on the shared shell (manifest 1.16.0): after a draft-only edit,
closing committed a thin save (workspace row plus empty content lists), and
reopening restored both the draft and the full prior conversation with its
turns intact.
Live checks on the shared shell (manifest 1.15.0): a restart began with no
broker, the test-only `submit` IPC drove the exact submit path, the answer
completed, and after the surfaces were closed the broker was retired ~30 s
after its last activity (observed in the shell log), with the gate state
exposed through `status` as `brokerIdle`/`brokerRunning`.
Live checks on the shared shell (manifest 1.13.1): one store-worker PID was
reused across entry, typing, close and reopen with no per-operation respawn,
the worker stayed present during bursts, and its idle self-exit path was
observed (exit 0 with an empty queue, not resurrected). Live patterns showed
both a session-persistent worker and the Python-side idle self-exit; either way
store operations stay correct, and the per-session process count is one instead
of one per operation.
Earlier checks (manifest 1.13.0) on the same shell confirmed cold entry
hydrates the latest workspace exactly once, the round-trip draft persists
through close/reopen with focus, and no ReferenceError/TypeError appeared in
the active shell log.
Earlier image-refinement checks (manifest 1.12.1) examined compact/expanded
native galleries and keyboard-opened, full uncropped images, exercised viewer
zoom/pan and `Esc` focus return to `aiImageFrame`, opened credits with focus on
`aiImageCreditClose`, and closed/reopened the panel; `AiImage.qml` and
`AiGallery.qml` were warning-free under `qmllint`, and `AiBlocks.qml` retains
existing warnings. Plain-image **Show another** has unit coverage only; no live
verification is recorded for it.

Offscreen/software passes are not proof against live retained-panel scene-graph
or Wayland device-pixel-ratio (DPR) changes. Mixed-DPR testing remains pending;
the live checks above are not a general stability or resource-budget claim.
Removing image effects/layers is a mitigation for a suspected DPR-related
pure-virtual crash, not a confirmed root cause or resolution; core symbolization
is pending. Resource qualification has started (see `AI_WORKSPACE_PLAN.md`,
immediate milestone): the sampler is released after each measurement, initial
paired shared-shell observations are recorded there, and lazy restore
(manifest 1.13.0) plus the burst-oriented store worker (manifest 1.13.1) landed
as the first lifecycle-refactor slices, with collapsed-history unloading and
event-driven supervisor waits (manifest 1.14.0) as the next two, the
idle-broker lifecycle (manifest 1.15.0) as the fifth and coalesced dirty-field
saves (manifest 1.16.0) as the sixth. Adaptive explanation depth (manifest
1.17.0) is Phase 2 product work, not a lifecycle slice. Phase 2 budget
verdicts against the plan's section 4.8 were recorded under manifest 1.19.3
from the recorded measurements and direct storage inspection (the full
paragraph is in `AI_WORKSPACE_PLAN.md`); these are shared-tree observations,
not an isolated A/B. The static native answer measured within sample noise of
rest (500.6 vs 506.9 MiB shared-tree median), far below the 96 MiB incremental
ceiling for the native surface; the active native learning/tool workspace was
+28 MiB aggregate over rest including the broker (35 MiB) and store worker
(8.7 MiB), below the 192 MiB native/helper ceiling, with the provider CLI's
435 MiB PSS recorded separately and in the total as required; idle after close
left zero AI helper processes and no measurable retained increment beyond
ambient variance, inside the ≤20 MiB + zero-helper gate; settled idle CPU is
argued from that process absence, not tracing — the shared-tree percentages
are ambient and uninstrumented, so they are not attributed to the feature;
the media cache held 32.1 MiB across 35 files at the 32 MiB startup-pruned cap
(the plan's 64 MiB gallery headroom unused); and the store held 64 workspaces
in a 0.2 MiB database with a 2.8 MiB WAL, 61 artifacts, 77 revisions and
145 interaction rows, with the 256-revision per-artifact cap enforced and
tested. Unmeasured and explicitly not claimed: the full 100,000-row dataset
paging/UI gate (the 2026-10-05 isolated sampler check above is narrower),
programmable-artifact runtime budgets, decoded-pixel profiling at
DPR, instrumented CPU/wakeup attribution, and a second display scale.

For temporary, read-only resource profiling, choose the actual shared Quickshell
PID and keep fixture/theme/scaling conditions in the report:

```bash
python3 ai_resource_probe.py --pid PID --seconds 60 --scenario cached-gallery \
  --context "warm; fixture, theme, display scale and runtime versions" \
  --output /tmp/opencode/ai-resource.json > /tmp/opencode/ai-resource.stdout.json
```

The probe samples `/proc` PSS/RSS and CPU for the shell and observed descendants;
it does not launch or signal them. Launcher-broker descendants and external
provider launches are separate categories. Missing memory is explicit, CPU
identity uses PID plus start time, and peaks are sampled observations. Shared
shell/plugin activity is not attributed to AI without paired baselines. This
is a developer measurement tool, not a permanent polling service.

---

## 🎨 Design language

App, file and AI modes share `rosakodu.dock` tokens through `SatinGlass.js` (copied
so the launcher can be removed independently): radii, spacing, typography,
elevation, keylines, state sizing and motion. `LauncherPanel` uses `Color.bar.text`,
`Color.bar.bg` and `Color.accent` in every mode, with
`surfaceOpacity = 1 - launcherTranslucency / 100`. The shared gradient, inner
card keyline and specular top edge also apply in every mode; there is no
hardcoded production palette.

`AiLayout.js` replaces `AiTheme.js` and provides measured sizing and task-first
answer composition, including OpenUI tools. The AI composer uses
`Satin.radius.field` and `Satin.type.search`,
with field alpha `0.075` and an accent focus border matching the existing app
field. The editorial answer composition, integrated controls and explicit tool
safety boundaries remain unchanged.

`Satin.type` now covers the AI surfaces, not just the search chrome: the
typographic refinement added `small: 12`, `body: 14`, `subtitle: 17`,
`prompt: 20` and `display: 29` — the exact values of the raw literals they
replaced, so no rendered size changed — and the AI components' static
`font.pixelSize` values now read those tokens (the diagram's model-driven part
labels keep their computed size). An audit found no hardcoded colors in the AI
components — their colors flow from the injected theme tokens — and the
text-only additions (the exploration trail line and the depth sidecar) are
non-focusable, so keyboard order through the pane is unchanged.

`AiImage` no longer uses `QtQuick.Effects`, `MultiEffect`, a graphics layer or a
mask. Whole, uncropped figures remain native images; this conservative rendering
path trades rounded image corners for fewer scene-graph effects while crash
investigation and live verification continue.
