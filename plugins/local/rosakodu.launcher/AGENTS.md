# rosakodu.launcher agent notes

Reviewed checkpoint 1.21.2: all workspace loads gate submission and retire warm
broker sessions; timeout responses are invalidated, cleared drafts survive,
and epoch timestamps use `real`. Hydration trims legacy accumulated transcripts
to the latest 20 turns before authoritative resaving. The store enforces private
owned/no-follow roots and database files independently; media capacity is reserved
before every resolution attempt. Formula mirrors reject non-finite intermediate
arithmetic and preserve scientific exponents during formatting. The composer
uses a native scrolling TextArea with its caret-follow viewport and pinned
Send/Stop controls; do not reintroduce a capped, clipped standalone TextArea.
Depth geometry, hero-image alternative state, keyboard scroll visibility,
detached affordances and lazy loading-hint geometry have regression coverage.
This does not establish a new live Wayland/mixed-DPR qualification or deliver
CSV preview/paging/type correction.

Checkpoint verification (2026-10-06, 1.21.2): exact index exported to scratch,
172 Python (2 skipped), 114 main QtTests, 15 blocks, 23 visual, 12 answer,
isolated service/store checks, audit and scratch restore pass. Root restoration
has 28 passing regressions. Existing QML/Python resource warnings remain.

Scene-graph lifetime trap: on a Wayland scale change Qt walks the item tree
(`QQuickWindow::physicalDpiChanged` → devicePixelRatio item-change) and calls a
virtual on every item. A panel item already torn down (hot reload + retained
service) crashes the shell with `__cxa_pure_virtual`. Keep the AI answer image
raster unlayered in `AiImage.qml` (no `layer.effect`/`MultiEffect` masks on a
live `Image`); if rounded corners are wanted later, follow the stock
image-picker pattern: layer an `Item` wrapper containing the `Image`, never the
`Image` itself, and test live.

Verification honesty: offscreen `qmltestrunner` suites use the software
renderer and cannot validate the live scene graph, Wayland DPR handling, or
retained-panel close/reopen. Before declaring the panel stable, exercise the
live lifecycle: ask a question with an image, close, reopen, photo-details
popup, Esc. SQLite restores saved launcher workspaces after a shell restart,
lazily: boot and discovery are metadata-only, the latest workspace hydrates
once on real AI entry (pane shows "Loading your last conversation…", submit is
gated until the load settles, 5 s watchdog), in-flight text/attachments survive
the completed snapshot via carry capture with a live-draft comparison, and
closing commits a pending debounced draft/attachment save. Interrupted
responses restore as retryable errors. `omarchy restart shell`
applies QML changes only when the session is unlocked. Compact/expanded gallery,
keyboard-opened viewer, zoom/pan, popup focus and close/reopen checks passed on
2026-10-04 without active-shell-log errors; mixed-DPR remains untested. Plain
image Show another has unit coverage only, not recorded live verification;
gallery-item replacement (manifest 1.18.0) is live-verified — items 0 and 2
replaced independently while item 1 stayed untouched, with the state persisted
and restored intact after a full shell restart.

Verification tooling gap: `qmllint` validates each file in isolation and does
not resolve the component instantiation chains that `qmltestrunner` builds, so a
missing `.js` import can pass lint and fail only at instantiation. Live example
(manifest 1.19.2): the token refactor moved `AiButton.qml` onto
`Satin.type.meta` without adding the `SatinGlass.js` import; `qmllint` stayed
clean, and the only signal was a suite build failure — `Type AiComposer
unavailable` wrapping an inner `Incomplete binding` (`AiComposer` instantiates
`AiButton`). After any refactor that adds a `.js` alias or a new type reference
inside a component, run the instantiation suites; lint alone is not a compile
gate.

Checkpoint test portability: the ready-gallery keyboard check uses the tracked
74-byte `tests/fixtures/media/gallery.png`, with the mock state root temporarily
pointed at its fixture directory and reset afterward. Do not depend on a PNG
left by an earlier live run. Cache-confinement tests use disjoint sibling roots,
not a broad scratch ancestor that can contain the default XDG cache directory.

Viewer geometry trap: an `Image` inside a `Flickable` is parented to its
`contentItem`, not the viewport. Bind fitted image geometry explicitly to
`viewerPan`, reserve header/credit height, and center both fitted and zoomed
content. Keep arrow-key panning bounded, close resetting zoom/focus to
`aiImageFrame`, and the hidden viewer source empty. Clearing the source avoids
an eager second raster, but is not proof of Qt cache/GPU reclamation. Galleries
use equal aspect-fit comparison frames and full wrapping captions, never crops.

Frame focusability is not raster readiness: a restore-time live Tab walk
skipped gallery cells because `aiImageFrame`'s `activeFocusOnTab` was gated on
`imageReady`, so a frame whose cached raster had not decoded yet stayed out of
the tab ring. `AiImage.qml` now keeps the frame focusable whenever it is
visible and guards only the viewer keys on `imageReady` (`Space`/`Return`
opening and the `onClosed` focus return), so loading and errored images are
keyboard-reachable too, with `statusText` as the frame's accessible name and a
focus ring in every state; after the fix the restore walk entered all cells
immediately. The new offscreen `test_galleryCellsEnterTheKeyboardChain`
(`tests/tst_AiPane.qml`) readies its fixture with
`tryCompare(image, "imageReady", true)` before the Tab walk, so it pins the
ready-image ring rather than loading/errored focusability — the gating trap
was exposed by the live restore walk. Live Tab chain (manifest 1.19.3):
composer → answer summary → diagram parts (each selectable) → stepper controls
and advance → **Simpler** / **More depth** / **Another example** → **Copy** →
toolbar → back to composer; every gallery cell walks frame (viewer) →
**Photo details** → replacement, and the reverse walk visits the same ring.

Gallery item replacement is scoped per item, never per gallery: every item
resolves two candidates (`MAX_MEDIA_ASSETS = 12` bounds all media blocks per
answer, alternatives included), `AiGallery.qml` reads each cell's
`alternativeIndex` from its own `gallery:<block>:<item>` uiState key, and the
in-cell **Show another** (`AiImage`) emits `uiStateEdited` on that same key, so
replacing one example leaves its neighbours untouched. The test-only
`swap '<blockIndex>' '<itemIndex>'` IPC (`LauncherPanel.qml`) cycles the same
state path for harness runs. Regression tests:
`test_gallery_items_offer_replacement_candidates` (each item resolves one
alternative) and `test_galleryItemReplacementStateIsScoped` (`AiVisualCheck`:
exactly one state edit, key `gallery:0:0`, value 1; neighbours not reset).

Offscreen checks must never touch real user state: create the retained service
with `{storeEnabled: false}` or isolate the store (a scratch `XDG_STATE_HOME`,
or stub `storeScript`/`stateRoot` overrides as in `AiServiceCheck.qml`). Boot no
longer restores anything, but a store-enabled check that calls `requestLatest()`
or `resumeWorkspace()` still loads — and then re-saves — the user's live
workspace once the load settles. `AiServiceCheck.qml` (stub store, marker-free
async) and `AiWorkspaceStoreCheck.qml` (scratch `XDG_STATE_HOME`) both isolate
now. The service check's in-tree `tests/ai_service_stub.py` handles both store
and broker protocols without file access or provider execution. `stateRoot`,
`storeScript` and `brokerScript` are writable internal injection points; verify
their effective values BEFORE enabling the test store. A readonly property can
silently ignore a `createObject` override and route a check to live helpers.

Store worker: one lazily demand-started Python worker
(`ai_workspace_store.py --serve`) serves the whole session, never one
interpreter per operation. The burst queue writes through one always-open
stdin pipe: never flip `stdinEnabled` on the store `Process` after first start —
re-setting it re-opens/re-closes the pipe and sends EOF into a worker that is
expected to persist. The worker answers one JSON line per request
(`{op, payload}`) strictly in order, with static in-band error results, and its
structured read loop keeps lines that shared a transport chunk. Idle release is
twofold — the Python-side self-exit after roughly 30 s without requests
(`LAUNCHER_STORE_IDLE` is the test-only override) and the service's store idle
timer 30 s after the last operation; only a queue with real work resurrects the
worker, so an idle-exited one is not restarted for nothing. Killing it
mid-burst restarts it for queued work (`storeRestartTimer`). Live: one worker
PID reused across entry/typing/close/reopen with no per-op respawn.

Coalesced dirty-field saves: `AiService.savePayload()` is the single save entry
for autosave and close-commit. It always sends the small workspace row fields
(id/title/summary/agent/sessionRef/draft/attachment) and appends the full
artifacts/interaction serialization only when a content change raised
`dirtyContent` — set by the `onTurnsChanged`/`onChecklistStatesChanged`/
`onUiStatesChanged` handlers and consumed by the next full save — so
draft/attachment-only edits write a thin payload with empty content lists.
`newConversation`'s final save of the finished conversation stays a full
`workspaceSnapshot()`. `newConversation` also sets `restoreSettled = true`: the
autosave gate (`queueSave()` returns while `loadingLatest || !restoreSettled`)
exists only to cover an in-flight restore, and a fresh conversation has nothing
pending that could overwrite it, so it must be immediately persistable — leaving
the gate closed until the next launcher close was a lazy-restore regression
introduced in 1.13.0 and exposed only by a full journey run; `AiServiceCheck`
pins "a fresh conversation must be immediately persistable". The store is
upsert-only for thin artifacts/interaction payloads, so
content omitted from a thin save is preserved. As of 1.21.2, a full snapshot
explicitly sets `authoritativeContent: true`; it deletes obsolete artifact and
interaction keys so the 20-turn window cannot grow back after restoration
(`test_partial_save_preserves_stored_content` pins the contract; `AiServiceCheck`
pins the payload shapes). Do not change `cmd_save` to COALESCE-style field
preservation: an attempt broke NOT NULL columns and was reverted, and the
workspace row is deliberately full-row because the launcher always sends the
complete, cheap field set — the coalescing win is skipping the heavy content
serialization, nothing more. QML boundary: `savePayload()` is a service-scope
function; panels reach it through the declared service surface
(`root.service.storeRun("save", root.service.savePayload())` as in
`LauncherPanel.qml`), never as a property — file-scope ids such as
`saveDebounce` live inside `AiService.qml` and must not be called as
`service.<id>` from panels or checks.

AiBlocks component trap: inside a `Component { AiChart { ... } }` the value
assignment `block: host.block` overrides the type's declared `block` property,
but writing `property var block: host.block` REDECLARES it — the instance gets
a shadowing property while the type's own internal bindings keep the stale
default, so every `block.*` read inside the file stays empty. Use the binding
override for file-based types that declare `block` (AiChart/AiImage/AiDiagram);
declare `property var block:` only for plain Items (Column/Text/Rectangle) that
are adding it. Symptom: the component renders with stale/empty data while
`findChild(...).block` looks correct from outside.

Comparison tables are local tools and keep their state on the same path as the
other learning blocks: header and filter edits emit
`uiStateEdited(host.blockIndex, "table:<blockIndex>", {sort, dir, filter})`,
so one table's arrangement never touches another block and the state restores
with the workspace. Keep the sort numeric-aware: a pair of non-empty cells
that both parse as finite numbers compares numerically, otherwise the pair
falls back to `localeCompare`; `sort: -1` means the authored order, not a
third persisted direction. Keep the row filter a literal case-insensitive
substring match (`indexOf` over the lowered joined row), never a RegExp or
pattern compile in QML — "train|bus" must match nothing; that is a robustness
boundary, not a UI detail. Pinned by `test_tableSortsAndFiltersLocally`
(`tests/AiBlocksCheck.qml`).

Table focus/state traps (manifest 1.21.0): `TextField` has `activeFocus`, not
`visualFocus`; bind the filter ring to `tableFilter.activeFocus`. The table's
saved-state property is `tableState`, never `state` (which shadows
`QQuickItem.state`). `test_tableSortsAndFiltersLocally` now types a real keyboard
edit, asserts its scoped emission and the 2-pixel focused border; assigning
`uiState` alone does not test `onTextEdited` or keyboard focus.

CSV attachments are bounded provider snapshots, not native dataset imports:
`attachment_snapshot` accepts explicit home-contained/no-follow regular files;
case-insensitive `.csv` reads the first 8 MiB, strict comma `csv.reader` parses
UTF-8 with optional BOM, and whitespace is preserved. Non-CSV files keep the
64 KiB guard, including grow-after-stat rejection. `_csv_snapshot` keeps a
contiguous prefix of at most 200 data rows, 20 columns, 80 characters per
header/cell and 24,000 complete serialized UTF-8 JSON bytes (metadata,
quotes/escapes included). `columnsTruncated`/`cellsTruncated` disclose loss
separately and set overall `truncated`; `totalRows` is exact only for a fully
read source, otherwise null. Withhold a boundary UTF-8 codepoint and discard
the incomplete logical CSV record, including multiline quotes. Ragged,
malformed and oversized fields must return readable turn errors, leaving the
worker usable. `ai_catalog` forbids whole-file aggregates from prefix samples
and exact calculations/identifiers from clipped values. Regression coverage in
`tests/test_ai_broker.py` pins these boundaries and snapshot accounting once.
Do not describe this as a local preview, type-correction UI, full resource copy
or paged data explorer.

Test-only `submitfile 'prompt' 'path'` (`LauncherPanel.qml`) guards
busy/stopping, loading and invalid requests BEFORE draft/attachment mutation,
then uses the same `submitAi()` synchronously. It does not grant the model a
file tool; the normal attachment flow stays `f:` Ask AI / Ctrl+Enter, with
review before sending.

Conversation rows are Loader-gated: `AiPane.qml` instantiates one row per turn
through a `Loader` that is `active` only for the newest turn or while earlier
answers are expanded, so collapsed history is uninstantiated entirely — its
native answer trees, sibling images and delegates are released, not merely
hidden (`visible: false` alone keeps them live). Expanding materialises the
rows and collapsing releases them again; `WorkspaceWindow.qml` embeds the same
pane and inherits the behavior. The row component lives at file-root scope and
receives its per-row data (`index`, `payload`, `isLatest`) through the visual
parent — the `host: parent` component-boundary rule that also governs AiBlocks —
while the root-level `pane` id stays reachable for shared surface state.
Regression test: `test_collapsedHistoryDoesNotInstantiateHeavyAnswers` in
`tests/tst_AiPane.qml`.

Broker guardian is event-driven, not a poller: `ai_broker.py --supervise`
blocks the main thread on a `threading.Event` that a reaper thread sets on
`proc.wait()` and the SIGTERM/SIGINT handlers set on arrival, so a child exit
and a supervisor signal both wake it exactly once (no 20 ms `proc.poll`/sleep
loop, and no `time` import). Cancellation and descendant cleanup are unchanged:
TERM then SIGKILL of the whole group, followed by adopted-children reaping.
Regression test: `test_supervise_waits_event_driven_and_tears_down_group`.

Broker idle lifecycle: the broker stays warm only while an AI surface is
visible. `LauncherPanel.syncPanelActive()` raises `panelActive`, and
`WorkspaceWindow.onVisibleChanged` raises `windowActive`; `lastBrokerActivity`
is stamped on every `send()`/`receive()`, and `brokerIdleCheck()` returns true
only when the broker is started, not busy/stopping, every AI surface is
hidden, and the last activity is 30 s or more old. A 1-second repeating timer
then retires the broker via `broker.running = false` (the Quickshell `Process`
terminates the child); the next submit cold-starts it again, and a fresh
broker adopts the persisted provider session from the request's
`resumeSession` hint — validated against the same `[a-zA-Z0-9_-]{1,128}`
pattern as provider sessions — while a warm broker ignores the hint because
its own session is newer. QML `Timer.repeat` defaults to false: the repeating
lifecycle timers (broker idle, store idle, store stall) must set
`repeat: true` or they fire once. Regression tests:
`test_resume_session_survives_broker_restart` (a fresh Broker resumes
`resume abc -` in the provider argv after `stop()`) and
`test_resume_session_rejects_foreign_patterns` (invalid hints never reach the
provider argv). The test-only `submit` IPC
(`omarchy-shell rosakodu.launcher submit 'text'`) drives the exact submit path
without keyboard input; ordinary users still use Enter.

Adaptive depth is a prose sidecar, not a second conversation: the broker's
`explain` op reuses `run()` with `EXPLAIN_GUIDANCE` appended to the prompt
("another example" is one fresh, specific situation — a place, object or
everyday case — showing the same idea, not a restatement of the mechanism),
emits no deltas and no presentation/media enrichment, keeps only the final
prose (structured blocks in the model output are dropped), and turns an empty
explanation into an error ("No explanation was returned."). The stale-resume
fallback covers explain runs too: when a run that adopted a persisted session
hint (an ordinary submit or a depth explain) raises `ValueError`, the broker
clears the session and retries once with `allow_resume=False`, so a stale
`sessionRef` — live-discovered: a restored conversation hard-failed every
follow-up after a shell restart — costs provider-side continuity, never
availability. Provider processes load `ai_broker.py` at spawn, so guidance
edits apply to the next broker start (idle retirement or shell restart).
Regression tests: `test_explain_emits_prose_sidecar_only`,
`test_explain_rejects_missing_text`,
`test_stale_resume_falls_back_to_fresh_session`.

`AiService.explainLatest(mode)` is the only depth entry: it maps `example` to
the treatment text `another example`, builds a bounded context from the latest
learning block only (diagram selection label, slider value+unit, steps index),
is gated on busy/loading/stopping, and sends
`{op:"explain", turnId, agent, prompt, resumeSession?}`. Its `explain` receive
path (`AiState.updateTurn`) updates the latest turn's prose `explanation` and
clears busy — never appending a turn, never rewriting `answer`/blocks.
`explanation` rides the interaction turn rows (restored with the workspace) and
appears in the text fallback (`AiState.textAnswer`). `AiPane.qml` shows `aiDepthActions`
(`aiDepthSimpler`/`aiDepthDeeper`/`aiDepthExample`) only on the latest answer
with a learning block and hides them while busy; the sidecar is the bordered
`aiDepthText` box with an `aiDepthTextLabel`. The test-only
`depth '<simpler|deeper|example>'` IPC drives the action. Regression coverage:
the depth block in `AiServiceCheck.qml` and `test_adaptiveDepthActionsAndSidecar`
in `tests/tst_AiPane.qml` (clicks all three actions).

Exploration trail is derived state, not a recorded log:
`AiState.trailSummary(turn, uiState)` scans only one turn's persisted
`uiStates` map and returns at most one " · "-joined line, empty when nothing
matches. One label per activity: checks, predictions, steps and scrubs
collapse; a table can contribute "Sorted" and "Filtered" together; gallery
replacements count individually. "Checked" for any `check:*`
entry with `checked` or a non-empty `selected` attempt (clearing it back to
empty removes the entry), "Predicted" for a `predict:*` committed numeric
choice index, "Stepped through" for `step:*` > 0 (the first stage is not a
step), "Scrubbed" for any `slider:*` or `diagram:*` entry, "Sorted" for a
`table:*` entry with numeric `sort >= 0` (cycling back to the authored order
removes it) and "Filtered" for a non-empty `filter` on a table entry,
"1 example replaced" / "N examples replaced" for positive `gallery:*` values,
and "Depth added" when `turn.explanation` is set. Unknown state keys must never invent an
entry. `AiPane.qml` renders it under each turn through `aiTrail`, visible only
when the text is non-empty, read from `pane.service.uiStates[turn.id]`, so
the line restores with the workspace. Regression tests:
`test_trailSummaryRecordsExploration` (key by key, `tests/tst_AiState.qml`) and
`test_explorationTrailRendersPersistedInteractions` (renders persisted state,
hides when untouched, `tests/tst_AiPane.qml`). The resumable learning position
is satisfied by these same persisted keys — step/slider/diagram/check/predict
restore with the workspace (live: `{"11":{"slider:1":12}}` after a full shell
restart from the coupled slider+diagram check). The rendered **Sorted ·
Filtered** trail is also live-verified and restored with the CSV table below;
that does not establish live coverage for every trail label.

Live focus diagnostics pay for themselves: the launcher status IPC reports the
focused element (`focus`) and detached-window visibility (`windowOpen`) via
`Window.activeFocusItem` read from inside the PanelWindow (the proxy does not
expose `activeFocusItem`). Two real bugs were invisible to the offscreen
suites and only surfaced through scripted `wtype` Tab walks: a `Keys.onPressed`
handler referencing a stale id threw ReferenceError silently on every Tab with
an empty draft (fixed to `backButton`, plus a focus-target regression test),
and Quickshell `FloatingWindow` defaults to `visible: true` (the detached
window sat tiled open since every shell start until set explicitly false).
After QML key-handler edits, check the shell log for ReferenceError.

Medium-selection benchmark: `ai_bench.py` is an integration harness, not a unit
suite. It drives the RUNNING shell through `newchat`/`submit`/`status`, waits
for each answer, waits out the save-settle race with a bounded retry that
treats a stored pre-enrichment "Loading visual…" snapshot as unsettled, reads
the newest artifact read-only from the workspace DB, evaluates the versioned
30-prompt `bench-prompts.json` (`blocksAny`/`blocksNone`/`needsImages`
expectations plus `maxSeconds` notes), prints per-prompt lines plus a JSON
report with a by-kind summary, and exits non-zero when any prompt fails. Usage:
`python3 ai_bench.py --prompts bench-prompts.json --limit 6 --out results.json`.
It requires a running shell and a signed-in provider and makes REAL provider
calls — never fold it into the offline suite; `tests/test_ai_bench.py` covers
the pure logic (prompt validation, expectations, image checks, newest-revision
read, loading-placeholder detection, summary), and `qmllint` does not analyze
Python. First live findings
(manifest 1.19.0): a four-prompt smoke passed 3/4 — the one failure was a
harness read racing the settled save (fixed by the retry) — and a six-prompt
baseline passed 4/6: one Wikimedia gallery rate-limit (now surfaced in the
verdict note) and one model-variance prose answer for the predict prompt. The
architecture recognition prompt produced tables across repeated runs until the
gallery rule was strengthened in `ai_catalog` ("when the user wants to
RECOGNISE or IDENTIFY something visual, prefer the gallery so they can actually
see the differences"); the next run selected the gallery again. Loading-
placeholder trap (manifest 1.19.1): the answer can go done while the newest
stored artifact is still the autosave's pre-enrichment "Loading visual…"
snapshot — media resolution lands behind the autosave debounce and the store
worker, so a read keyed on `!aiBusy` alone can score the placeholder as the
answer. Treat a block `loading` flag, or an `error` beginning "Loading visual",
as unsettled and retry to a bounded deadline; a genuine provider error IS a
settled state, not a placeholder (both pinned by
`test_loading_placeholder_detection`). Expectation-calibration lesson: the
first full 30-prompt pass scored 23/30 raw; the exploration re-runs (styles,
birds, posters) came back clean and three mini-app results re-scored offline
after budget/decision/recipe expectations were widened to the plan's own
vocabulary — `checklist`/`steps`/`metric` were presentations the plan allows,
not selection failures; expectations must reflect the plan's vocabulary, not
the author's preference. Rate-limited providers deserve their own triage
bucket too: explore-clouds failed on Wikimedia rate-limiting under benchmark
load — an environment block, not a medium-selection failure. Consolidated
baseline: 29/30 (learning 8/8, exploration 7/8, mini-app 8/8, simple 3/3,
mixed 2/2, failure 1/1), above the plan's 80% target — but the figure combines
the original run, two targeted re-runs and offline re-scoring, and medium
selection remains non-deterministic, so never present it as one clean run.
Verification (manifest 1.19.3): 107 main QtTests, 23 visual, 14 blocks,
11 answer, 156 Python (2 skipped — 6 bench tests), `AiServiceCheck` green,
`qmllint` clean on the AI QML files. Theme resilience was verified live by
switching the theme to Kanagawa and back: the AI surface repainted from the
injected tokens with state intact, no shell-log errors, and Crimson Gold
restored. Scaling exercised only the real fractional condition (DP-1, scale
1.25); a second scale was not.

Resource-budget verdicts (manifest 1.19.3, the plan's section 4.8) are
shared-tree observations with honest limits, not an isolated A/B: the static
native answer sat within sample noise of rest (500.6 vs 506.9 MiB shared-tree
median) far below the 96 MiB incremental ceiling; the active workspace was
+28 MiB aggregate over rest including the broker (35 MiB) and store worker
(8.7 MiB), below the 192 MiB native/helper ceiling, with the provider CLI's
435 MiB PSS recorded separately and in the total; close left zero AI helper
processes and no measurable retained increment; settled idle CPU is argued
from that process absence only, because the shared-tree percentages are
ambient (agent updater, hyprctl, ddcutil, pacman, external-provider trees) and
uninstrumented — never present them as feature CPU; the media cache held
32.1 MiB across 35 files at the 32 MiB startup-pruned cap (the 64 MiB gallery
headroom unused); the store held 64 workspaces (0.2 MiB DB, 2.8 MiB WAL),
61 artifacts, 77 revisions and 145 interaction rows, with the 256-revision
per-artifact cap enforced and tested. Explicitly unmeasured: the full
100,000-row dataset paging/UI gate, programmable-artifact runtime budgets,
decoded-pixel profiling at DPR, instrumented CPU/wakeup attribution, and a second display
scale. Keep the shared-tree caveat and the limits list whenever quoting these
numbers; the full verdict paragraph is in `AI_WORKSPACE_PLAN.md`.

Latest verification (2026-10-05, manifest 1.21.0): 107 main QtTests, 15 blocks,
23 visual, 11 answer and 161 Python tests (2 skipped, normal offline-audit flags
unset); isolated `AiServiceCheck` and `AiWorkspaceStoreCheck` passed with scratch
state. No test failures. Lint has no errors, but existing standalone
`qs.Commons` resolution/Quickshell/old state-override/unqualified-access/
`MoveAnchor` warnings remain: do not call it clean or warning-free. Existing
Python database/test-pipe `ResourceWarning`s remain too.

Live CSV check: corrected synthetic `~/rents-sample.csv`, all eight
native table rows compared unchanged to the fixture; concurrent `submitfile`
returned `busy` without altering the empty draft/attachment. Rent header
Tab + Return sorted ascending; real `wtype` filter `o` yielded Porto 600,
Lisbon 900, Oslo 1200, **3 of 8 rows** and **Sorted · Filtered**. A full restart
restored the visually same rows/count/arrow/filter/trail in
`ws-52ce449a43c89ab5`, turn 92, with
`{"92":{"table:0":{"dir":1,"filter":"o","sort":1}}}`. Screenshots
`/tmp/opencode/csv-live-table.png`, `/tmp/opencode/csv-live-filtered.png`,
`/tmp/opencode/csv-live-restored.png` were read and visually inspected, unlike
earlier captures.

Sampling-only stress (`/tmp/opencode/csv-sampling-stress.json`): isolated
100,000 numeric rows × 20 columns, 14,989,091 source bytes; snapshot 0.202 s,
140 prefix rows, 22,157 serialized JSON bytes, `totalRows: null`, peak process
RSS 82,020 KiB. RSS includes the full Python process and fixture generation,
NOT incremental memory/PSS/native UI responsiveness. This is not the full
100k dataset stress exit; paging, source persistence, type corrections and
typed units/cycles runtime remain pending. Preserve all Phase 2 measurement
limits when quoting this narrower foundation check.
