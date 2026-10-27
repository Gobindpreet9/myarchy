# rosakodu.launcher agent notes

OpenCode provider (2026-10-26, **live-installed plugin subtree; shell restarted**):
`ai_broker.py` discovers audited OpenCode **2.1.4** and runs
`opencode run --standalone --format json --agent launcher --model
opencode-go/deepseek-v4.1-flash#high`, with the prompt on stdin (never process
argv) and `--session` on follow-ups. `prepare_opencode` builds a private
HOME/XDG tree whose OpenCode config contains a deny-all answer-only agent; it
shares ONLY the user's real `~/.local/share/opencode/opencode.db` via
`OPENCODE_DB`, so OAuth refresh tokens are never duplicated. Launcher sessions
therefore appear in the user's OpenCode session list. The answer catalogue
travels in each request (Hermes-style compact signature); the config carries
only the short answer-only policy. The v2.1.4 JSON stream is pinned:
`step_start`/`text`/`reasoning`/`step_finish` are accepted, `text` parts are
complete blocks joined by a blank line, tool/unknown events fail closed, and
provider errors map to a static message. A text-only answer may end at EOF
without `step_finish`, so exit 0 plus decoded text is accepted. OpenCode homes
are disposable and use the same reaper pattern as Codex homes.
`AiState.supported`, `agentName`, failure advice and `AiService` include
`opencode`; new Codex and OpenCode chats default to `responseMode: "openui"`,
while Hermes and restored legacy conversations stay native. No OpenCode handoff
button yet; its sessions can be resumed with `opencode --session <id>`.
Discovery prefers `~/.local/bin/opencode` and the packaged CLI paths, and
REFUSES a mise shim: a shim resolves through the user's mise config, which the
provider's private HOME deliberately does not contain. That exact failure was
found live (the shim emitted `mise ... not trusted` and exited before producing
an event) and is now pinned by a discovery regression.
Before a model-authored tool is emitted, the broker runs the same bounded
`ai_openui_runtime.py` guardian against it. A definite rejection gets ONE
self-contained correction request in the same provider session (still bounded
by the 192 KiB conversation budget); a second rejection, a failed repair, or an
unavailable validator falls back honestly: invalid `openui` blocks are omitted
with a static warning and the rest of the answer is kept. The validator never
runs model text as code outside that guardian and never adds provider tools.
Offline verification: **665 Python tests (2 skipped)**, 1,799 main QtTests,
AiOpenUiServiceCheck's new OpenCode-mode phase and AiServiceCheck green, audit
passing. Direct integration probes (real OpenCode, scratch homes, real auth DB)
produced one validated native answer in 18.4 s. Three post-prompt-hardening
OpenUI samples: one valid tool, one schema-dropped answer, one runtime-rejected
tool; a manual repair request corrected that rejected tool in 9.4 s. These are
small samples, not provider-quality or reliability benchmarks.

Live qualification (2026-10-26, plugin subtree installed from the working tree,
187/187 manifest entries hash/mode-identical, `omarchy restart shell`, default
agent set to `opencode`): a new tip-splitter conversation produced ONE valid
OpenUI tool in about 14 s; a follow-up changed the defaults to a 100 bill / 20%
tip in about 13 s and kept the same OpenCode session. Live keyboard interaction
then set the bill to 150 and showed correct local results (tip 30, total 180,
each person 90); the authored reset returned 100 / 20 / 60. A full shell restart
restored the tool with `uiStates{"3":{"openui:0":{"$bill":150,...}}}`, 150 in
the input and the recomputed 180/90 row after tabbing it into view. Screenshots
`/tmp/opencode/live-opencode-openui-2.png` … `-10-reset.png` were read and
inspected. The first pre-fix live attempt exposed the mise-shim discovery bug;
a later pre-fix tool (SegmentedControl label passed as its boolean `block`
argument) was runtime-invalid and showed the old error surface. After the
discovery fix and the prompt-hardening/validation slice, the live generation
above was valid without needing the automatic repair. The repair path is
unit-tested (success, second rejection, failed repair fallback) and was
manually validated once against the real model; it was not observed end-to-end
in the QML panel. Native OpenCode was exercised through the installed broker
with the live environment and state root, not through the panel. Only DP-1
3440×1440 at scale 1.25 is active, so mixed-DPR and a second display scale
remain unrecorded. OpenCode launcher sessions are written to the user's own
OpenCode database and appear in its session list.

Native OpenUI integration (2026-10-25; live-installed checkpoint `5788367`, now
extended by the installed OpenCode/validation slice):
new Codex conversations automatically select `responseMode: "openui"`; restored
legacy workspaces default to `native`, and Hermes stays native. The existing
composer, turns, artifacts and SQLite store retain ownership. Manifest/release
stays **1.22.0**. New Codex AND OpenCode conversations now select OpenUI;
checkpoint `5788367` was the first live-installed native integration, and the
current OpenCode/validation slice is installed too. Do not install into the live
plugin, restart the shell or touch user workspaces without separate approval.

`AiService.qml` owns ONE retained `AiOpenUiRuntime.qml`, not one per answer
Loader. Native `AiOpenUiSurface`/`View`/`Node`/`Svg` adapters present a bounded
inert tree from the actual OpenUI core worker; no WebEngine/browser, React
runtime or DSL evaluation in Qt. Latest eligible tools open automatically;
historical tools require explicit **Use this tool**, with one selected runtime.
Mount identities include workspace/turn/block/code; save echoes must not remount.
Drain event acknowledgements before transitions/snapshots. Persist canonical
state in `uiStates[turnId]["openui:<blockIndex>"]`; duplication must copy those
values opaquely, never artifact-remap strings inside user state.

`ai_openui_runtime.py` is a credential-free guardian for permission-limited
`/usr/bin/node` (>=24; actual 26). It allows reading the bundled worker only,
caps Node old space at 96 MiB and enforces an external 3-second request deadline.
Program/state/frame caps are 32/64/512 KiB; queues, AST/actions, node count and
depth are bounded. Worker-generated semantic SHA-256 handles bind queued events
to their action or input binding/options/range: never retarget by structural
node path alone. Action identity also fingerprints the authored action AST, so
a late-bound Copy payload keeps one handle across ordinary edits while a
replacement conditional Copy cannot inherit a stale handle. These are
stale-event guards, not authentication. No provider,
filesystem/network action bridge, arbitrary HTML/JS, Query/Mutation or telemetry.
Keep the native typed `calc` engine/validation; generic OpenUI math is not its
units/provenance equivalent.

`AiOpenUiState.js` supplies inert routing/copy/follow-up snapshots only. OpenUI
follow-ups carry at most 48 KiB code/state JSON, including 12 KiB of state;
refuse oversized/unsupported state rather than truncate/reset it misleadingly.
Cold OpenUI brokers do not resume untagged persisted sessions; this snapshot is
not transcript reconstruction or targeted in-place artifact revision.

Reproducibility: `python3 -B tests/build_openui.py --check` uses scratch
`npm ci --ignore-scripts`, build/tests and byte comparisons; only explicit
`--write` updates generated assets. Keep `openui/` source, lockfile, upstream
provenance and complete MIT notices together. `python3 -B tests/run_offline.py`
isolates every check, including native runtime/service/store checks. Final
scratch pass (2026-10-26, OpenCode/validation checkpoint): **21 worker tests**,
**665 Python tests (2 skipped)**, **1,799 main QtTests**, 29 blocks / 23 visual /
12 answer / 6 task-visual, all ten isolated checks, byte-identical generated
assets and a passing audit.
The action-handle regression pins distinct authored conditional Copy actions at
one structural path while preserving same-action Copy across ordinary edits.
One production-broker
Codex garden sample (27.58 s) replayed natively at 420/980px: 72 initial SVG
positions, then 48 at 3.6 m / 30 cm. The two opaque screenshots under
`/tmp/opencode/native-openui-visual-qsgbpwid/` were read and inspected, compositing
item alpha over the actual `#202124` Window colour. Raw model output is not in
the repository. This is not a reliability benchmark; resource remeasurement,
live Wayland/mixed-DPR and installed-desktop qualification remain pending.

## Earlier checkpoints (retain their dated scope)

Repository checkpoint (2026-10-25): active development is now in the private
owner repository on `feat/launcher-openui-native`. Preserve the installed
October native task/calculator/CSV/workspace work before replacing presentation.
The checkpoint adds a scratch-only runner: `python3 -B tests/run_offline.py`.
It clears provider/runtime environment overrides, isolates every HOME/XDG root,
and uses short runtime paths plus the preview checks' required HOME prefix.
Do not force a Qt Controls style: keyboard behaviour must be explicit in our
controls (Return/Enter as well as Space), independent of the system style.

Review fixes: composed calculation-unit exponents are bounded to 1024 (RANGE)
in BOTH engines, with timeout-backed JS and real-QML renderer regressions.
The shared golden table now has 328 cases; fuzz remains fresh. Form follow-ups
carry optional numeric `unit` (<=24 UTF-16 units); it is not accepted for other
kinds. The 20-turn window now prunes corresponding UI/checklist state during
the session, not only after restore. Failed action choices can be picked again;
roving cursors reveal their actual row; Ask controls reserve a trailing gutter;
calculation duplication follows the host's availability gate. Review covered
security, consistency and UX; the broad quality reviewer hit its usage limit.
No live deployment or Wayland/mixed-DPR qualification is implied by this work.

Owner clarification (2026-10-24; constraint retained, native implementation now
above): intelligent UI belongs INSIDE the native
launcher's existing AI experience, with its composer, turns and saved state.
The standalone OpenUI page is a development harness only, not a product
destination or a manual step the owner should need. Native embedding was then
pending; resource/lifecycle qualification remains open. Do not substitute an
external app or present the preview command as completion.

Historical browser-host investigation (superseded by the native QML path):
the renderer-only `launcher/embedded.*` entry had no second composer/store
and one mocked-host round-trip check (nine browser checks total). Do NOT import
Qt WebEngine into the live launcher yet: a scratch Quickshell instantiation
crashed with `Argument list is empty ... QCoreApplication`; current host startup
hard-codes Qt `argc = 0` and also lacks early WebEngine setup. No supported flag
workaround was found. Do not modify/replace the shell binary or startup without
separate approval. This browser experiment was not a delivered native host;
the framework-independent-core/QML alternative is now implemented above.

OpenUI prototype checkpoint (2026-10-24): owner approved autonomous investigation
and implementation after comparing Thesys and CopilotKit. Chosen foundation is
**thesysdev/openui core**, using the Thesys `open-intelligent-ui` demo's reusable
component/function source, not its Next.js application/backend. The owner's
third link to `thesysdev/openui` is that underlying framework, not another demo.
Prototype source/build is `~/Work/launcher-openui/launcher/`; its README
documents open/build/tests. Nothing in the installed native renderer was replaced.

Actual Renderer + shared reactive state + matching generated prompt are wired
to a loopback stdlib Python backend and the audited Codex helpers. Saves reuse
the existing SQLite implementation in a SEPARATE `<launcher-state>/rich/`
database; no native workspace access, pruning or retention. Credentials stay in
an isolated provider home; no model execution/search tools, arbitrary HTML,
external media, telemetry, Query/Mutation or broad host bridge. Generic OpenUI
math is not a substitute for our validated calculation engine.

Verification: 336 Vitest / 30 Python backend / 8 real-SQLite browser checks,
types/build; three synthetic real Codex generations (meal/garden/gears) valid
in ~15/28/30s. Exact-output UI replay verified local controls at 420/1280px with
no page errors/external browser requests. Saved-state reload, delayed/failed
saves, invalid model output and generation cancellation have regressions.
Scratch state only; native workspaces untouched. Real-provider results are one
small sample, not a reliability benchmark; complete-answer Codex latency remains.

Historical browser-candidate blocker: headless Chromium + backend used ~435–437 MiB
aggregate PSS (10 processes), above the 256 MiB optional-runtime gate. GPU-off
variants did not fix it. Cleanup left zero owned processes; startup/CPU figures
are short headless observations, not live Wayland qualification. Keep the preview
explicit (`npm --prefix ~/Work/launcher-openui run launcher:open`); no
desktop shortcut or shell preload was installed. This led to the lighter isolated
core/native-QML host above, not more fixed widget types. Qt WebEngine Quick
development libs existed; CMake was absent. Independent review agents hit quota;
no review pass claimed.
No release, version bump, commit, push, canonical sync or deletion of native work.

Current owner priority (2026-10-22, implemented 2026-10-23): **custom UI quality
and usefulness**, not another maintenance/status pass. Task-first composition is
now implemented in `AiLayout.answerComposition`, `AiAnswer.qml` and
`AiTaskSurface.qml`: task title, compact orientation with an explicit full-prose
disclosure, primary native object, supporting content and sources last. Wide
forms can have a context rail; diagram controls sit alongside their canvas when
space permits. Plain/image briefs retain their existing layout. These are
bounded native layouts for existing blocks, not arbitrary generated UIs/code.

Composition carries its original blocks and their indices in ONE descriptor.
Never split these into independently updating QML properties: replacing a
diagram with a form/comparison exposed stale indices and TypeErrors. The warning-
failing transition regression pins this. `AiBlocks.contextBlocks` preserves the
whole-answer slider/diagram binding context across visual groups. Resize and text
view keep the actual tool instance; original state/choice/focus indices, gates,
exports and stored blocks remain unchanged. No response/store schema change.

Comparisons now lead with the authored AI recommendation and evidence, then
explicit **Continue with…** (an AI follow-up). Matrix width depends on visible
option count. Narrower layouts show every candidate in a shortlist and ONE
inspected detail card; inspecting is local, never a send or persisted edit.
Pin/hide and raw option identities remain intact. Timelines now lead with
progress/first unfinished item and jump to its real row; reset reveals the first
row. No item reordering, inferred schedules or invented remaining time.
Prompt guidance now asks for the native task object as the answer, not a second
prose answer with widgets attached; all existing byte/security limits remain.

Visual fixtures are reproducible with `tests/AiTaskVisualCheck.qml`: decisions,
plans/progress and forms at 420/760/980px, plus light/Crimson Gold palette
variants. Screenshots `/tmp/opencode/ai-task-*.png` were read and inspected.
They are illustrative/offscreen, NOT real provider output or live Wayland/DPR
qualification. Keep custom UI experience/evaluation as the next priority; the
older persistence-notice/scenario-export backlog below is secondary. No release,
version bump, commit, push or canonical sync has been performed.

Final verification for this UI slice (2026-10-23): **630 Python tests (2 skipped),
1,765 main QtTests, 28 blocks / 23 visual / 12 answer / 6 task-visual**, plus
all eight isolated service/store/preview/source/detached checks. Scratch
HOME/state/runtime/cache/config only; no real provider calls or user workspace
mutations. Final main log has no TypeError/ReferenceError/binding-loop warnings;
known standalone Qt lint and Python ResourceWarnings remain. Task replacement
and image/text teardown each have warning-failing regressions. Logs are under
`/tmp/opencode/launcher-task-finish-i4v22dwg/`. These results do not establish
live provider-selection quality, Wayland lifecycle or mixed-DPR correctness.

Initial owner-supplied OpenUI candidate review (2026-10-23; superseded by the
prototype checkpoint above): source/license review of
`thesysdev/open-intelligent-ui` and `thesysdev/openui` found MIT-licensed reusable
layout/state/action/parser/renderer infrastructure, substantially broader than
the current fixed block vocabulary. React/web components are not a QML drop-in.
Evaluate a lazy rich-workspace renderer side by side before extending the block
catalogue further; preserve native launcher, provider credentials, durable store
and typed calc validation. No upstream dependency was installed or code adopted,
and no renderer migration is approved/completed by this source review alone.

Earlier audit status (2026-10-22; installed tree, manifest still **1.22.0**): the
437-Python / 1,113-QtTest October 8 checkpoint was not the latest work. October
9–10 additions include editable calc data, scenarios, local undo/redo, exports,
local calc duplication, forms, actions/compare/timeline, “Ask about this”, Codex
prompt de-duplication/timing and soft block failures. The scoped October 10 live
calc pass below remains valid historical evidence, not a new live qualification.
Canonical `~/Work/myarchy` is clean at launcher commit `0a4ba8e`
(October 6); the initial audit found 94 installed files different/new, before
the new test-helper files. Nothing was synced, released, committed or pushed
during this resume; no product feature was built. Earlier dated paragraphs
below retain their checkpoint scope.

Fresh offline verification: **624 Python tests (2 skipped), 1,710 main QtTests,
28 blocks / 23 visual / 12 answer**, plus all eight checks:
`AiServiceCheck`, `AiWorkspaceStoreCheck`, `AiWorkspaceContextCheck`,
`AiSeamsServiceCheck`, `AiCsvSourceCheck`, `AiAttachmentPreviewCheck`,
`AiPreviewServiceCheck`, `AiDetachedWindowCheck`. Fresh scratch HOME/state/runtime/
cache/config, offscreen/software rendering and unset `LAUNCHER_*` flags kept real
providers, credentials and user state out of the run. Existing `ResourceWarning`s
remain. The main total includes eight new strict-equality helper checks.
Test-only repairs use `verify(TestJson.equal(...))` for strict recursive leaf
type/value equality (including exact numbers and array order), ignoring only
object key order because QVariant reorders keys. `tests/TestJson.js` has its own
`tests/tst_TestJson.qml` regressions, including rejection of a 1e-6 numeric
difference; QtTest's numeric-tolerant object comparison is not a substitute.
Other fixture fixes restore the fake prepared Codex after
`new` intentionally clears it, sanitise its environment and guard real auth
preparation. Recorded logs: `/tmp/opencode/launcher-status-20261022-6ts2myhe/`
(`python-final.log`, `qml-final.log`, `blocks-final.log`, `visual.log`, `answer.log`
and `<Checkname>.log`); initial logs are not the final verdict.

Secondary backlog: make the 200 KiB `stateNotice` persistence-refusal guard visible;
then reveal/focus scenario comparison on opening, add pane PageDown, and align
scenario exports (CSV omits table-formula rows; Markdown also omits differing
inputs). These gaps still exist by read-only inspection. Dynamic-control/focus
live clicks and the October 10 compare-body/stale-QML issue remain unverified.
No Phase 3 exit, targeted artifact patching, full conversation branching or
general arbitrary-code artifact runtime is claimed. Native-profile prompt guards
are 13,000 / 15,000 / 26,000 bytes (Codex / Hermes / full), schema 13,500; the conversation budget is
192 KiB, not the historical 64 KiB (still the plain-text attachment cap).

Automatic maintenance MUST send `{preserveWorkspaces: true}`. The old explicit
store-prune policy deletes unpinned workspaces above 20 or older than 30 days;
do not invoke it silently while restoring. Enabling the previously skipped
cleanup path in 1.21.2 removed 47 live workspaces. They were recovered additively
from a pre-update SQLite backup (no existing records overwritten), and 1.21.3
preserves all 67 on subsequent AI entry. This is why load housekeeping and
user-requested destructive retention must stay separate.

Reusable-tools slice (2026-10-08, unreleased; no manifest/version bump, release
or canonical-repository sync): **More → Rename… / Duplicate…** use themed native
keyboard dialogs. `AiState.workspaceName` and the store validator accept trimmed,
non-empty, plain single-line names of at most 96 UTF-16 units; reject controls,
unsafe format characters and unpaired surrogates. `interaction.workspaceName` is the
saved override: `workspaceDisplayTitle` uses it for the workspace row/search and
detached window without changing answer headings. Preserve it through thin
draft saves, full authoritative snapshots and restoration.

`AiService.beginWorkspaceAction` uses a save-acknowledgement barrier before
the backend rename/duplicate; never clone stale disk state after an unconfirmed
save. After cloning, the `switch-save` barrier commits edits made to the ORIGINAL
during the action and waits for an acknowledgement of the unchanged live snapshot
before loading the copy (one save at a time, repeated if editing continues).
The final `switch-load` phase freezes the outgoing pane/composer and local-state
setters, keeps the original's session/handoff/source ownership for rollback, and
clears its typing intent only when the copy applies. Failed/null/interrupted loads
leave the original open with visible guidance. A lost rename acknowledgement
replays the requested title in the recovery save rather than undoing a committed
rename. The single-shot action guard also covers a worker that never starts.
Worker-loss recovery releases the startup latch and recomputes pending work
from the surviving queue; queued requests must never be reported as idle.
Hold autosave/close-commit mutations while the action is pending. Busy/stopping,
loading/unsettled restore, keep-data and pending-action gates prevent conflicting
actions, submits and switches. Failures leave local content intact with an
unconfirmed-action message; late replies must not navigate a newer workspace.
No retention/prune pass belongs to duplication.
Naming forms capture the opening workspace identity and close when it changes;
named empty copies keep management reachable without taking CSV ownership.

`cmd_duplicate` transactionally creates independent workspace/artifact identities,
remaps artifact references and gives each copied artifact one fresh parentless
revision checkpoint, NOT the source revision history. Keep turns, checklists,
UI state (including `calc:<blockIndex>` adjusted inputs), draft and attachment.
The original saved workspace, provider session and handoff home remain intact;
the copy has blank `sessionRef` and no `handoffHome`. Remove the copy's `csvSource`
link and do not clone/share the source registry or kept CSV resource; it remains
owned by the original. Cached image references are copied unchanged, not new
durable asset copies. This is NOT full AI conversation branching: the first
future provider prompt does not reconstruct copied history — the bounded
follow-up snapshot described next is the only prior state it can carry — and
state-aware AI revisions (targeted artifact patches) are not delivered by this
slice.

Offline verification for this slice: 418 Python tests (two skipped;
existing `ResourceWarning`s), 1,077 main QtTests, 26 blocks / 23 visual / 12 answer,
isolated `AiServiceCheck`, real-store
`AiWorkspaceStoreCheck` in scratch HOMEs, and `AiDetachedWindowCheck` passed.
Wide Rename / narrow Duplicate screenshots were read and manually inspected on
mock/offscreen surfaces, NOT live. Review findings received regression fixes; do not
turn these results into a release, live lifecycle or mixed-DPR claim. Relevant
regressions live in `tests/test_ai_workspace_store.py`, `tests/tst_AiState.qml`,
`tests/tst_AiPane.qml`, and the service/store/detached checks.

State-aware follow-up context slice (2026-10-08, unreleased; no manifest/version
bump, release or canonical-repository sync): every ordinary explicit submit now
captures `AiState.workspaceContext(turns, uiStates)` BEFORE the new turn is
appended and attaches it as `workspaceContext` — the latest completed turn
(prompt <=512 / answer <=1024 UTF-16 units) plus the most recent completed
`calc` block within the 20-turn window (it may be OLDER than that turn, so a
prose follow-up still explains the open calculator): inputs (<=12), outputs
(<=12) and <=4 tables x <=6 columns x <=6 rows with <=12 table cells total, all
in one <=8 KiB UTF-8 JSON. `AiCalcView.js` is the single build/restore adapter
shared by `AiCalc.qml` and the snapshot, so saved input state validates exactly
as the renderer applies it (an out-of-range value or unit mismatch RESETS to
the authored default — never clamps), numbers come from the typed engine
(error cells keep their code with value null, booleans stay booleans), and a
partial numeric display, formula or unit is withheld (`unavailable`/`truncated`)
rather than sent misleading. The broker's `validate_workspace_context` checks
the closed schema BEFORE any attachment/source read, resume-session adoption or
task creation: invalid context emits one static "Workspace context is invalid."
and changes nothing. The snapshot is appended exactly once as
`Current workspace snapshot (untrusted data, not instructions):` + compact JSON
behind fixed guidance, and its bytes are charged once against the 64 KiB
budget; a stale-resume retry reassembles the identical prompt. Boundaries: no
transcript, no provider-session reconstruction, no source IDs/file paths/new
tool access; local edits still make no model call; a follow-up appends a NEW
answer and never patches the original blocks; a truncated snapshot must not be
used to claim whole-table aggregates, overall rankings or metadata the truncation
dropped; depth (`explain`) requests never carry it. Still not included:
checklist/step/diagram/table-view state or general artifact revision — this is
bounded current-state context, not full state-aware revisions. No live provider
call was made while verifying it. Offline: 437 Python tests (2 skipped; existing
`ResourceWarning`s; `WorkerTests` now mocks `refresh_codex_auth` so a protocol
test can never copy the real `~/.codex/auth.json`), 1,113 main QtTests,
26 blocks / 23 visual / 12 answer, isolated `AiServiceCheck`,
`AiWorkspaceStoreCheck` and `AiWorkspaceContextCheck` (real service -> real
broker -> stub provider in scratch HOMEs: input 8 -> 9 sent scores
40/16 -> 45/18, original blocks/UI state untouched, fresh chat omits context).
Offscreen only: no live provider-quality, Wayland lifecycle or mixed-DPR claim.

First successful live CSV provider send (2026-10-06, default agent claude ->
Codex fallback): `submitfile` returned `previewing`; with the panel open the
retained reader reached `ready` (8 rows, 3 columns, total 8; a hidden panel
defers the read, so `status` stays `idle` until the panel is visible); the
explicit second `submitfile` dispatched and the answer arrived in about 10 s
with a native sortable table, "Sent with · rents-sample.csv" and the fallback
note. The stated mean (925) and range (600 Porto to 1,800 Dublin) match the
fixture. This closes the "successful live provider send" gap from the 1.22.0
qualification for Codex on the 3440x1440 scale-1.25 display only; mixed-DPR and
a second scale remain unrecorded. It added two test workspaces ("hi" and the
CSV one) to the user's real store on top of the earlier ws-62943ec34e1535ba.

Agent fallback (2026-10-06): the live default agent is `claude`, which
`AiState.supported` rejects, so every submit failed ("supports Codex and Hermes
for now"). `AiState.resolveAgent(agent, defaultAgent)` now keeps a supported
agent, else a supported default, else falls back to Codex when the default is a
non-empty unsupported one (an EMPTY default still returns "" and asks the person
to choose). The shared `~/.config/omarchy/defaults/agent` is never edited. The
fallback is disclosed on the latest turn (`aiAgentFallbackNote`, derived from
`service.agent`/`defaultAgent`, not persisted): "Answered by Codex: the
launcher doesn't support claude yet." Live: `submit 'hi'` with the real default
`claude` answered in about 5 s as codex. `AiServiceCheck` was updated to pin the
empty-default case instead of an explicit unsupported one.

Text-contrast pass (2026-10-06): informational text no longer sits below
0.76 opacity. Measured on the live Crimson Gold surface (theme foreground about
219,180,44 over a surface of about 54..85,0..13,0..3): contrast is roughly 3.0 at
0.50, 3.4-3.7 at 0.58, 4.6-5.2 at 0.72, 5.4-6.1 at 0.80. The composer
placeholder (0.58) really failed AA at 3.39:1 and is now 4.77:1 (pinned by
`test_placeholderMeetsReadableContrast`); the 21 raised labels were 0.34-0.65
(RECENTS, ALL APPLICATIONS, result count, keyboard hints, mode label, step
and row counts, chart axes, slider notes, filter placeholder, thinking/loading
text). Honest correction: idle `AiButton` text at the old 0.72 already passed
(about 4.9-5.2:1), so the 0.80 button change is polish, not a fix. Measurement
traps: the text caret is drawn at full colour and gave a false 7.7:1; small
glyphs anti-alias low in a screenshot, so for small text trust the computed
value (alpha-blend over the sampled surface) over the pixel reading.

Hidden-entries fix (2026-10-06, live-verified only): omarchy's
`/usr/share/omarchy/shell/services/hidden-entries.sh` prints the correct list
but EXITS 1 on success (its last line tests a missing ~/.nix-profile dir). The
panel only used the output when `exitCode === 0`, so the hidden set was always
empty and XFCE-only entries (About Xfce, Appearance, Window Manager...) showed
on Hyprland and even led the empty-query list, so Enter launched "About Xfce".
The scan now collects lines with a `SplitParser` (the shape omarchy's own
`AppLibrary` uses) and ignores the exit status. Live: all-apps 78 -> 59, an
`xfce` search 21 -> 3 results. The script is root-owned omarchy code, so the
upstream fix would be `exit 0`/`return 0` at its end; there is no offscreen
test because `Process` needs Quickshell. A `console.log` of
`desktopHiddenIds` size at `onExited` is the quick way to re-check it (it was
how the exit-1 cause was found; the earlier "StdioCollector race" theory was
wrong and did not change the result).

Failure-state UX slice (2026-10-06, unreleased, manifest still 1.22.0,
offscreen only): `AiState.failureAdvice(message, attachment)` rewrites only the
two known broker failures (provider sign-in, vanished attachment) into a
headline + next step and keeps every other message verbatim as its detail;
the vanished-file retry is "Try again without the file" and clears the
attachment. `AiState.previewAdvice(error)` adds an `aiCsvPreviewHint` under the
CSV preview error WITHOUT touching the allowlisted, test-pinned static error
text or the Retry button (a retry rereads a changed file, so it stays). A
failed turn renders its prompt via `AiAnswer.failed` at subtitle size instead
of the display headline, the turn label is "Sent with ·" (the composer's
pending file stays "Attached ·"), and idle `AiButton` text is 0.80, the
opacity this file already records as the 4.5:1 qualification. A Codex
sign-in failure also offers **Sign in to Codex** (`AiState.signInCommand`,
fixed argv `omarchy-launch-terminal codex login`, Codex only; Hermes has no
verified sign-in command so it gets guidance only; `AiService.signIn`). The
broker copies ~/.codex/auth.json into its isolated home once per process, so
`refresh_codex_auth()` now re-copies it before each Codex run ONLY when the
user's file is newer than the copy (Codex rotates tokens inside the copy; an
older source must never overwrite it), without creating another home. Live
(after `omarchy restart shell`, 2026-10-06): hint, "Sent with", quiet failed
headline, sign-in headline/buttons and footer contrast were seen on the real
panel; the Sign in button was deliberately not clicked (it starts a real
login). Offscreen: 167 main QtTests, 15 blocks / 23 visual / 12 answer, 196
Python (2 skipped), isolated preview/service/detached checks, qmllint clean.
A new `AiCsvPreview.qml` import of `AiState.js` was needed: lint would not have
caught a missing one. Never run unfamiliar provider CLIs for `--help` here: `hermes
--help` opened the Hermes desktop app.

Codex-home sprawl (2026-10-06, fixed): each broker process made a `codex-*`
home that nothing removed (146 dirs, ~260 MB). 66 were referenced by
`interaction_state.handoffHome` (Continue in terminal resumes them); 80 were not.
The broker now removes only its OWN home, only if it never emitted `done` (the
sole carrier of `handoffHome`; `Broker.handed_off`), on `new` and exit, and a
failed `prepare_codex` removes its half-built home. Old homes go through
`python3 ai_broker.py --reap-homes` (dry run by default; `--apply --expect-count
N`), never automatically. It reads a COPY of workspace.db (a read-only SQLite
connection still leaves -wal/-shm), keeps homes named anywhere in saved
interaction data, owned by a live broker (`.owner` pid+start), used as
`CODEX_HOME` by a running process, or newer than 24 h, and refuses if the DB is
missing/unreadable or Codex conversations exist with no recorded home. Never
touches workspace.db or media. Run live on 2026-10-06 with approval: 78 removed
(~90 MiB), 66 referenced homes intact. Not done on purpose: stripping auth.json
from referenced homes (handoff has no auth refresh) and reusing a home across
broker restarts (would change resume semantics; needs a live check). Tests:
`HomeReaperTests`/`HomeLifecycleTests` in `tests/test_ai_broker.py`.

Dynamic UI vocabulary (2026-10-10, offscreen; model: Codex pinned to `gpt-6.1-sol`): three new block types, one each per answer, soft-dropped when invalid. `actions` {title, options[{label<=40,hint<=60}] 2..6} (a tap sends the label as a follow-up via `AiService.submitChoice`: fixed prompt + `workspaceContext.choice`, state `act:<i>` {picked}, a FAILED answer reopens it), `compare` {title, options[{name,summary,facts<=4,pros<=4,cons<=4,recommended}] 2..4, verdict} (matrix >= 560 px else stacked cards; state `compare:<i>` {pin,hide[]} of RAW option indices, never all hidden; no scores), `timeline` {title, items[{label,when,minutes 0..1440,detail}] 2..16} (authored order; state `plan:<i>` {done[]}; Total only with >= 2 durations). Strings are cleaned to one line then capped; names/labels unique after NFKC casefold; `minutes` is a whole number (30.0 is rejected). Prompt guidance is `ai_catalog.BLOCK_GUIDE` (<= 140 B each); guards were raised on purpose (codex 13,000, hermes 15,000, full 26,000, `CODEX_OUTPUT_SCHEMA_BUDGET` 13,500 B; de-dup freed ~5.4k tokens/request): codex now 12,682 B. "Ask about this": `workspaceContext.focus` {turnId,blockIndex,kind,index -1..63,label<=80,detail<=240} (exclusive with `form`/`choice`, each <= 4 KiB, fixed envelope sentences, no system-prompt bytes); the service property is `focusTarget` (`Item.focus` is FINAL); `?` on a table row/step/gallery cell/diagram node/chart point/option/timeline row asks; the composer chip is layered on Esc (first Esc clears it). Traps: Qt refuses to clear `activeFocusOnTab` on the focused item (use `enabled`, or follow `onActiveFocusChanged`); a test id named `compare` shadows TestCase.compare(). Bench on Sol (live, 4 new prompts, run twice): actions 1/1, timeline 2/2 after the BLOCK_GUIDE/head rewording (before it Sol chose checklist/prose), compare 1/3 (table or prose-only otherwise: model variance, not a validator reject). Offline: 624 Python (2 skipped), 1702 main QtTests, 28/23/12 variants. NOT VERIFIED LIVE: the first real-panel check showed the compare block's heading and sources but NO block body in the peek card; the identical stored block renders at 466 px through AiAnswer and a full AiPane offscreen (plain and ListModel(dynamicRoles) turns), and a temporary yellow debug Text added to AiBlocks never appeared after hot reload, so the running shell appears to be serving stale QML: re-check after a real `omarchy restart shell` (a whole-shell restart was refused by the permission classifier in that session).

Live pass, editable calc + scenarios + undo + export + duplicate (2026-10-10, real shell, real Codex, a 3-laptop block): block rendered (3 weight sliders with basis badges, toolbar Reset/Undo/Redo/Discard my edits (N)/Copy as CSV/Duplicate, grid with Add/Remove row, Scenarios (n)); Tab order composer -> summary -> slider/field x3 -> Copy as CSV -> Duplicate -> 'How is this calculated?' -> grid (ONE stop, `aiCalcGridScroll`) -> Add -> Remove -> Scenarios toggle -> name field -> ... -> Compare; grid Right+Return+typing edited Laptop A price 1200 -> 1000 (bold + edited diamond; score 54.44 -> 57.78, hand-checked); Ctrl+Z restored 1200/54.44 and Ctrl+Y brought 1000/57.78 back; two scenarios saved by keyboard (Base, Price heavy), compare view showed the differing input in bold and per-laptop scores (table edit applied to all scenarios); Copy as CSV put a correct CSV on the clipboard (inputs, cells with verbatim formula, the table with the edit, scenarios); Duplicate appended 'Copy of ...' as a new turn with the edit baked in and scenarios carried; a full shell restart restored all of it. KNOWN GAPS found live: (1) opening the compare view does not scroll it into view, and Page Down does not scroll the pane (the Down arrow does); (2) the CSV 'Scenarios' block lists the differing inputs and cells but NOT the per-table score rows that the on-screen compare shows; (3) `stateNotice` still has no UI. Not covered: mixed DPR, screen reader, mouse paths.

Soft block failures (2026-10-10, offscreen): `normalize_response` now drops only blocks that fail `validate_block` or a cross-block rule (first diagram/slider/calc/form/gallery, 2 media and 6 blocks win; a slider without its diagram goes too) and keeps the answer, suggestions and every valid block with the generic warning 'Some parts of this answer could not be shown.' (never model text or the reason); whole-answer plain-text fallback remains ONLY for unparseable JSON, a bad envelope, or an unmeetable 64 KiB cap. `validate_response` stays strict and shares the cross-block rules (`_check_across_blocks`, `_complete`) so they cannot drift. This SUPERSEDES the earlier sentences that a calc/slider/form reject falls back the whole answer. Live 2026-10-09: the three-laptop calculator prompt once came back as prose with 'Response did not match the native answer schema'; 4 real re-runs (default x3, old catalogue x1) all produced a valid calc block, so the cause is unproven (a resumed session/snapshot context is untested); the one known unguided reject, `min()/max()` over a table column, is now stated in the prompt (codex 11,980 B, 20 B spare).

Intelligent UI slice (2026-10-09; offscreen + 8 real Codex requests, form/waiting UI NOT live-verified; see plan section 1.1): (1) MEASURED: Codex 0.160.0 `exec --json` returns the whole structured answer as ONE item.completed at the end (no partial agent_message; 4.5 s greeting, ~11 s calc/gallery, all model time), so progressive block rendering only exists for Hermes; `streamed` is always false for Codex. (2) Prompts are per agent: `ai_catalog.system_instructions(agent)`: codex = prose + caps table (no schema dump; structure via --output-schema), hermes = prose + `compact_signature()`, other = full; budgets 12,000 / 14,000 / 23,100 B in tests/test_ai_prompt_budget.py (codex has 0 B spare: a new block must state its increment, or put its guidance in a dynamic envelope). (3) Codex DEDUP is ON by default (`LAUNCHER_CODEX_DEDUP=0` opts out): the catalogue travels once as `base_instructions`; the request carries a 195 B preamble; `context_bytes` charges what is sent. Live A/B n=8: -5,413 input tokens/turn at the old 21.5 KB catalogue, all answers accepted, same block types, wall time within noise; WATCH: in 2/2 explainer pairs the old setup used web search (sources block) and the new one did not (confounded with the catalogue change). (4) `validate_block` is the single per-block validator (final pass and any stream run identical code; ParityTests). (5) `form` block (G2): `AiForm.qml`, state `form:<blockIndex>` = {v:{id:value}, sent}; submit = fixed prompt 'Answers to the form on the previous answer.' + `workspaceContext.form` (<= 6 answers, 4 KiB; broker validates shape only and adds one fixed envelope sentence; labels are untrusted data); strings are SANITISED not rejected (control/bidi -> space); failed responses keep the form resendable. (6) Every turn gets a content-free `timing` on `done` and a row in `<state>/launcher-ai/metrics.jsonl` (200 lines, 0600); the service keeps a 50-entry ring (`timingSummary()`, p95 indicative under n=20); the pane shows the real phase + elapsed counter from 3 s (one 1 Hz timer, only while busy and visible). (7) Partial-turn seam exists but nothing emits it yet: `updateTurn` accepts `presentation{partial,from,blocks}`; a partial turn is never snapshotted; final events prune dead uiStates block keys. Not built: the stream compiler (`ai_stream.py`, for Hermes), maps, visual-quality evaluation, wiring `timingSummary()` into the status IPC, a UI for `stateNotice`. Live checklist: submit a form-eliciting prompt (bench mini-form-*), Tab walk, invalid number, send, see the rendered answers list, restart, Retry; the waiting counter at 3 s+; metrics.jsonl exists and holds no text; compare web-search use on 3 explainer prompts with dedup on/off.

Editable calc data + scenarios (2026-10-09, OFFSCREEN ONLY, not live-verified: the display was asleep): edits are a different SPEC, not an engine change (golden 322 and fuzz fresh stay untouched). `AiCalcEdit.js` (pure: parseCell mirrors the engine's number rule exactly, setCell/addRow/removeRow/restoreRow/discardEdits, scenarios <= 3 input sets, `commit` refuses over 10 KiB, `bake` for Duplicate), `AiCalcView.js` (`build(block, dataKey)` so a slider move never recompiles; `scenarioResults`; stale/bad `_d`/`_s` are DROPPED and flagged, never clamped), `AiCalcExport.js` (Markdown keeps verbatim formulas; CSV guards formula injection with a leading apostrophe unless PLAIN_NUMBER; both <= 64 KiB), `AiCalcGrid.qml` (one roving Tab stop, <= 40x12 Text delegates + 1 TextField, invalid input never emitted), `AiCalcScenarios.qml` (compare <= 4 columns, 230 delegates worst case), `AiCalc.qml` (toolbar Undo/Redo/Reset/Discard/Copy as CSV/Duplicate; in-memory history 30 entries/100 KiB, 600 ms input coalescing, cleared when `saved` changes from outside; emits the FULL `calc:<i>` entry and ignores echoes of its own emits; Tab order is reading order), `AiService.copyText`/`duplicateCalc` (Duplicate = a NEW local turn, no provider call, scenarios kept and edits baked into the rows) and a guard that refuses a `setUiState` growing the whole uiStates map past 200 KiB (the store rejects 256 KiB for the WHOLE map and would silently lose every autosave) with `stateNotice` (no UI renders it yet). AiState copy/trail/depth consumers now go through `CalcView.run` ('Edited data', 'Scenarios' trail labels; stale input RESETS, no clamp). Traps: never rebuild a Repeater from inside the clicked button's own handler; the edit tool turns \u escapes into raw U+2028 (scan sources for raw U+2028/2029/0085/FEFF; ASCII + \u escapes only); QML wrappers fail Array.isArray (JSON-copy first). Live checklist: Tab walk (inputs, toolbar, grid one stop, add/remove, scenarios), type/commit/invalid cell, add/remove row, undo/redo, scenario save/compare/load/delete at the 660 px peek and detached, Copy as CSV + wl-paste, Duplicate, restart restores edits and scenarios, shell log. Not covered: mixed DPR, screen reader, a UI for `stateNotice`, source-bound `colstat` (design: gate on a present 'Full-source statistics' section), carry-over of edits into an AI revision.

Review fixes round 3 (2026-10-09, offscreen; live re-check pending): an adversarial review of the CSV-source and calc work found and these now have mutation-checked tests: (1) `sourceId` rides a request only when `AiService.sourceAppliesTo(attachment)` holds (no attachment, or attachment === `sourceOrigin`), so file B's sample can no longer sit next to file A's whole-file statistics; (2) every keep failure after the worker returned an id calls `discardCopy` once (`source_unlink {removeDir:true}`; it removes the named src-* dir even with NO registry row and has NO owner check, so ids must stay random and fresh); client `columnCount` bound = the worker's 2**31; (3) restore opens and verifies the NEWEST source row first and unlinks older rows only after that; (4) the conversation budget is `CONVERSATION_BUDGET` = 192 KiB (error 'Conversation exceeds 192 KiB.'); `MAX_CONTEXT` 64 KiB is only the plain-text attachment cap; a kept-source turn re-charges about 30-42 KB (21.5 KB prompt + stats + snapshot), so expect roughly 4-6 follow-ups; (5) `discover_codex` skips a hung/failed probe and still tries the audited 0.160.0 install; (6) CSV numeric sort and stats share `clean_cell`/`numeric_key`; blank lines count for progress/supersede cadence; filter control characters are stripped; explorer cells with newlines show on one line with a return glyph; (7) calc engines: whitespace-only expression is 'empty' and `colstat(1.0,x)` is 'colstat-args' in both (golden now 322 cases). The earlier sentences saying the budget is 64 KiB are superseded by (4).

Calc differential fuzz + decisions (2026-10-08): `tests/CalcFuzz.js` (1794 rows, seed in file) is GENERATED by `tests/gen_calc_fuzz.py` with Python's expected values; after ANY engine rule change run `python3 tests/gen_calc_fuzz.py` (`--check` says fresh/stale) or the fuzz tests fail as stale. The fuzz found 3 JS bugs and 4 Python crash classes; ten decisions D1-D10 are now pinned in the golden group "decisions" (golden is final at 315 cases): non-finite results from to/num/round/unit conversion are RANGE; aggregates over a TEXT column are TYPE even with zero rows; to()/num() need a [unit] group (else unit-position); a bare [unit] anywhere else is a parse fault that beats unknown-name; unit checks run before domain/range on quantities (sqrt(0-5[cm]) is UNIT); parse faults beat name/table/colstat-arg resolution; malformed spec shapes and missing ids are 'syntax' (a present invalid id is 'bad-id'); a non-number non-null input is TYPE; declared unit text is not trimmed; identical unit symbols cancel exactly first, then same-dimension symbols merge into the first-occurring one (3[km/h/s]*2[s] = 6.00 km/h); sumproduct reports the first error left to right. A fuzz row only goes on the generator's documented skip list for a genuine open question (5 multi-fault/shape rows today), never by loosening a comparison.

Typed calc runtime (2026-10-08): `ai_calc.py` and `AiCalc.js` are two independent hand-written engines (units, lazy if/iferror, aggregates, DAG with Kahn order, error values, provenance) both checked against ONE golden table `tests/CalcGolden.js` (257 cases, hand/Fraction-verified; its header pins the rules and OQ1-18). Do not edit one engine without the other and the table. CLEAN rounds a 16th-digit tie away from zero in both (JS toPrecision behaviour). Model path: `ai_catalog._check_calc` (one `calc` block per answer; must evaluate error-free at initial, all-min, all-max and midpoint; a reject falls back the WHOLE answer exactly like an invalid slider formula - owner may change that; `colstat` rejected until source stats are supplied); the system prompt grew 16.1 -> 21.5 KB per request (guarded at 22 KB). Renderer `AiCalc.qml`: turn blocks arrive as QML wrappers where Array.isArray is false, so every consumer JSON-copies the block before `compileSpec` (AiState does too); state `calc:<blockIndex>` = changed inputs only `{id:{v,u}}`, Reset sends `{}`; a bad block shows one line "This calculation can't be shown."; table shows 12 rows until expanded. `textAnswer(turn, uiState)`, trail "Adjusted" and the depth context (`Inputs:` line) know calc; `calc` is a depth-action learning block (AiPane and `explainLatest` lists must match). Live (real model, 2026-10-08): "weights for a laptop" produced a valid calc block (3 weight inputs, 2-row table with a unit-aware score column, total cell) that accepted Codex's output schema and evaluated correctly by hand (37.00 vs 35.50 at weights 5/3/2). Live UI check (2026-10-08, after unlock): the block rendered with 3 weight sliders + typed fields + basis badges, disabled Reset, Total weight, a computed 2-row table (37.00 / 35.50); End on slider 0 gave weights 10/3/2, total 15 and scores 31.33 / 37.00 (hand-checked); the change survived a full shell restart (Reset became active). Not covered live: the provenance disclosure, typing into the number field, mouse paths, narrow peek card, mixed DPR.

CSV preview polish (2026-10-08, live-verified): the 20 header type badges are ONE roving Tab stop (Left/Right/Home/End move, Space/Return/Down open the menu, Esc returns focus to the badge, Tab leaves). With a kept source on an expanded/detached surface the preview is a one-line summary ("CSV preview - 10 of unknown rows - 20 of 20 columns") with a Show/Hide toggle (detail lives in an inactive Loader); the peek card and the no-source case stay open. Live: composer -> explorer toggle 23 -> 4 Tab stops, card ~960 -> 300 px collapsed. The explorer's own 20 sort headers are still individual Tab stops; peek worst case and mixed DPR not re-measured.

Durable CSV source, round 2 + live check (2026-10-07): `AiCsvExplorer.qml` (collapsed "Explore all rows", 25-row page, <= 25x20 delegates, sort cycling, literal filter, paging) is wired through `AiService` (one `csvSource`; keep flow budget -> register -> save -> `source_link`, replaced copy unlinked with `removeDir`; `sourceId` rides every submit while linked and ready), `AiPane` (own host before the first turn, in the conversation scroll after) and `AiCsvPreview` (Keep button). Test IPC `source keep|refresh|page <n>|view <sort> <dir> <filter>` (all four args required, pass '' fillers) and status `source*` fields. Live on the real shell, real worker, synthetic 100k x 20 file: register < 2 s, sort/page/filter correct (literal: "plain|nothing" matches 0), full shell restart restored the source and its workspace, typing a filter in the explorer by keyboard gave 11,063 then 100,000 rows, a live prompt for a MEDIAN was declined and a prompt for sum/mean returned the true values (-62,733 / -0.62733), deleting the workspace removed the 19 MB copy (`sourcesRemoved: 1`). Detached floor pin is 750-765 (Keep row). Known gaps: reaching the explorer by keyboard means Tabbing past every type badge (about 23 stops); the preview card stays tall above the explorer; peek-card worst case not re-measured; mixed DPR; disk-full/crash-mid-rename; an orphan complete `src-*` copy is possible if New chat lands during register (only `--reap-sources` lists it). Also fixed: `discover_codex` now accepts the exact audited Codex 0.160.0 install when `mise which codex` points at a newer build (a Codex update had silently disabled launcher AI); and WorkerTests no longer use a 0.15 s broker timeout, which flaked under load (only the timeout test sets it).

Durable CSV source, backend round (2026-10-07, offscreen + scratch real-worker only; no UI yet): `ai_csv_source.py --serve` registers an explicit .csv by COPYING it to <state>/sources/src-<16hex>/ (data.csv, index.bin every 64th record, meta.json); complete (<= 64 MiB, 500k rows, 1 MiB lines) or absent; strict UTF-8, ragged fails registration; stats over all rows for the first 20 columns. Protocol: ordered JSON lines with ids; a view build is superseded by ANY queued request; `page` needs the latest view gen ("Stale view."); `columns` in meta.json equals the stats names (the broker's strict `load_source` requires it; pinned by BrokerContractTests). Registering is the only write; `--reap-sources` lists, and `--apply --expect-count N` removes only stale .tmp-*. Stress (LAUNCHER_STRESS=1, 100k x 20, 19.6 MB, tmpfs, shared box): register 0.62 s, worker RSS +25 MiB, view build ~0.25 s, supersede abort 5.5 ms, zero bytes during paging, idle exit 30.1 s; page p95 figures are client round trips. Store: `sources` registry table (no schema bump; one `workspace.db.pre-sources` copy when an older DB with workspaces gains it), ops source_link/unlink/list, delete and non-preserve prune remove the dirs after commit, preserve prune only stale .tmp-* and never a src-*. Broker: request `sourceId` -> "Full-source statistics" section (<= 12 KiB, sample shrinks to 50 rows), catalog allows only count/empty/min/max/sum/mean of listed columns as whole-file values (median etc. stay declined). Client: `AiCsvSource.qml` (SplitParser, lazy, stops 30 s after surfaces hide) + `CsvPage.js` validators; worker error text is never shown. Not covered: UI, live shell wiring, mixed DPR, disk-full/crash-mid-rename, a real model's reaction to the new catalog rule.

Fresh-shell A/B (2026-10-07, one run, zero plugin reloads, shared-shell 1 Hz PSS, not isolated AI cost): after `omarchy restart shell`, never-opened A 472.1 MiB aggregate / 453.7 shell-only; after first AI entry B 472.9; after 20 more cycles C 458.8; no-activity control D 459.4. B-A +0.7, C-A -13.4, drift +0.6 (A was still decaying ~2.8 MiB/min, so deltas read slightly low). Same 7 processes / 186-189 fds / 17 threads at every plateau; store worker gone within ~25 s of close; broker and previewer never started. The 20 MiB idle-retained and zero-helper gates PASS within these limits, for an EMPTY conversation only (no answer, media or provider exercised); CPU/GPU unmeasured. Raw files were in /tmp/opencode/resource-2026-10-07 (tmpfs).

Live check, CSV type correction + review fixes (2026-10-07, after `omarchy restart shell`): a 6-column mixed CSV showed abc / ? / date / abc / 123 / ? badges and the "inferred from the rows shown" note; Tab ran grid -> badges 0-5 -> answer; Space opened the Rent menu, Down+Return chose Number (badge accent, note "Corrected: 1", focus back on the badge, no turn sent); Remove returned the preview to idle; shell log clean. Not covered live: sending a corrected type to the model, the narrow peek card fit, mixed DPR.

Resource qualification attempt (2026-10-06, manifest 1.22.0, shared Quickshell, Crimson Gold, DP-1 3440x1440 scale 1.25, load average about 20): shared-shell 1 Hz observations via `ai_resource_probe.snapshot`, NOT incremental AI cost. TRAP: edits to plugin files hot-reload the plugin in the live shell ("Local plugin changed, reloading" in the shell's log.log); the first run was discarded (shell PSS 235 to 307 MiB, threads 17 to 25 across reloads), later runs waited for 75 s of log quiet and had zero reloads. Clean runs: settled idle 334.7 MiB aggregate / 313.8 shell-only (7 processes, 186 fds, 17 threads); 50 open/`ai`/close cycles on the saved conversation, no provider call, peaked at 8-11 processes / 198 fds / 21 threads and returned exactly to 7/186/17 after the 35 s settle, no broker ever started, store worker gone 31.8 s after the last close. The 5 MiB plateau gate is MIXED: one run ended +18.8 MiB over the early plateau (a one-time unexplained step), the repeat ended -0.5 MiB and a 100 s idle control moved +0.3 MiB. IPC-timed warm open p95 204 ms to reveal >= 0.99 (not frame time; cold opens 169-200 ms). The 20 MiB idle-retained gate cannot be judged without a fresh-shell A/B. No IPC hook switches workspaces, so 20 switches are unmeasured. Not measured: GPU, frame pacing, local-control p95, attributable CPU, interact cycles, mixed DPR. Raw files: /tmp/opencode/resource-2026-10-06/ (tmpfs, will not survive a reboot).

Independent-review fixes (2026-10-06, offscreen; live re-check pending): a
read-only reviewer found, and these now carry regression tests: (1) the broker
raises "Codex could not complete the answer. Check authentication..." for ANY
provider error event, so the UI no longer asserts a sign-in cause: headline
"Codex couldn't complete the answer", sign-in offered as a secondary action;
only the broker's definitive "Sign in to Codex before using launcher AI." makes
Sign in the primary action. (2) The fallback note shows only under a finished
(`done`) answer, and a pinned conversation whose agent differs from a later
default says "This conversation uses X; your default is Y. Start a new chat to
switch." (3) The default-agent file is read like omarchy-default-agent: first
line only, `[a-z0-9_-]{1,32}` (`AiState.parseDefaultAgent`), so a comment line or
an invisible character cannot reroute the provider. (4) Try again no longer
overwrites a newer attachment or a started draft. (5) New chat sets
`resumeOnOpen = true` (the identical "ai: " query never fires the change
handler). (6) `refresh_codex_auth` stages and renames, so a full disk cannot leave
a truncated auth.json that looks newer than its source. (7) The sign-in command
unsets CODEX_HOME and the button is disabled for 8 s after a click. (8) "Sent
with" elides; the remaining 0.66-0.72 informational text moved to the 0.76
floor. Accepted, NOT fixed: `refresh_codex_auth` and `prepare_codex` both follow
a symlinked ~/.codex/auth.json (same uid, no privilege boundary, and dotfile
setups need it); a restore completing after the person left AI mode can still
set `resumeOnOpen` true; AiPane tests still use fixed `wait(20)`; the
`AiService.submit()` fallback and `Broker.run()`'s refresh call have no
end-to-end test (the helpers they use are pinned).

Open-mode fix (2026-10-06, live-verified only): `LauncherPanel.open()` used
`service.resumeOnOpen || turns.length > 0`, so once ANY answer existed every
open landed in AI mode and the back arrow to app search never stuck.
`resumeOnOpen` already tracks where the person left off (restore/new answer set
it; `onQueryChanged` while open clears it when they leave AI mode), so `open()`
now honors it alone. Checked through IPC after `omarchy restart shell`: fresh
open stays in app search; `ai` then close/open resumes AI; an ordinary `query`
then close/open stays in app search with `aiTurns` still 1. LauncherPanel
needs Quickshell, so there is no offscreen regression: re-run that IPC
sequence after touching open/close/query handling.

Checkpoint 1.22.0 (2026-10-06, offscreen): local CSV preview + detached
measured minimum delivered and reviewed. Green: **195 Python (2 skipped)**,
**158 main QtTests**, 15 blocks / 23 visual / 12 answer, isolated
`AiServiceCheck` / `AiAttachmentPreviewCheck` / `AiPreviewServiceCheck` /
`AiDetachedWindowCheck` in scratch HOMEs, audit and scratch restore (manifest
hashes recomputed, 9 preview files added to the allowlist). The full-preview
detached floor is pinned in a 660–680 band (measured 669px at width 720).
Live Wayland/mixed-DPR qualification and the live attach → ready → gated-send
pass remain pending and must be recorded separately.

Live 1.22.0 qualification (2026-10-06, committed deployment with pre-replace
backups and a DB snapshot): `submitfile` returned `previewing` and the retained
reader reached `ready` at 8 rows / 3 columns / total 8 with no truncation for
`rents-sample.csv`; the panel and the detached window both render the literal
grid with every disclosure and the footer inside the window bounds on the live
3440x1440 scale-1.25 display. A ragged file reported `CSV line 2 has 3 columns;
the header has 2.`, and `submit` then answered `attachment-error` with busy
false, an unchanged turn count and an idle broker: no dispatch.
`omarchy restart shell` re-read the retained attachment to `ready` and kept the
conversation and all 67 user workspaces; the shell log has no launcher QML,
panel-load or broker errors. Three observations stay outside that pass: the
status IPC `shell`/`appLibrary` flags read false while the panel runs its own
desktop-entry fallback (host injection is omarchy-owned, the deployed lines are
unchanged, and hint, search and launch all work); `hyprctl` reported the
workspace window on a tiled right-column rect while it renders floating at
center, so window geometry reporting is unverified although content fit is;
and `AiState.supported` accepts only codex/hermes, so the live default agent
`claude` gates the whole attach path until `~/.config/omarchy/defaults/agent`
names a supported agent (set to `codex` for the test, restored to `claude`).
One test incident: a second `submitfile` against the same already-ready
attachment dispatched for real, which is the designed ready-plus-explicit-submit
path; it ran only in the test conversation `ws-62943ec34e1535ba` (68th
workspace, the user's 67 untouched) and ended with a codex authentication error
and no answer. Mixed-DPR, a second display scale and a successful live provider
send remain unrecorded.

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

Scoped live 1.21.2 check: committed-only deployment with backups/conflict review,
restart preserved the synthetic CSV workspace's 3/8 filtered/sorted rows.
Real Shift+Enter + X showed the tail of a ten-line draft; original draft restored.
Detached reverse-Tab visibly focused New chat (Back/Expand absent); close/reopen
retained the same workspace. Three cropped checkpoint screenshots were read.
No provider request or launcher log error; unrelated shell warnings remain.
This is not image-gallery/mixed-DPR or complete resource-budget requalification.

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
Do not describe this provider snapshot as the complete source, a type-correction
UI, a full resource copy or a paged data explorer — and do not use that wording
to deny the launcher's local CSV preview (`AiAttachmentPreview` /
`AiCsvPreview`), which is a separate bounded review surface with the same
no-full-import honesty.

Local CSV preview (1.22.0): a bounded, credential-free review surface, never
an import. `ai_attachment_preview.py` is the one-shot worker (8 KiB request /
32 KiB response, explicit `.csv` only, fixed shell-free argv, credential-free
environment limited to HOME/LC_CTYPE/PATH/PYTHONDONTWRITEBYTECODE/XDG_STATE_HOME)
and reuses `attachment_snapshot` for at most 10 display rows × 20 columns × 80
codepoints. `AiAttachmentPreview.qml` owns the retained lifecycle —
path/token/generation invalidation, terminal-response protection,
restore/workspace/new-chat switches invalidate readiness even for the same
path, hidden surfaces defer work — and validates count/truncation parity plus
strict-UTF-8 cells (lone surrogates are rejected). Its `note.length <= 300` is
a validator-side bound set above the producer's measured worst case (254
chars) and pinned against it by
`test_note_bound_holds_when_every_disclosure_combines`: the sampler itself has
NO runtime note bound, so that differential test — not a shared constant — is
what keeps the validator above every reachable note while still small enough
that a worst-case note cannot outgrow the peek-card budget, which has no
`clip`. `AiCsvPreview.qml` renders bounded
delegates, honest `sampleRows`/nullable `totalRows` disclosures, a
keyboard-scrolled grid with a focus ring, and scrollbar tracks that hide when
content fits; its loading/count/footer/disclosure text uses alpha `0.80`
(>= 4.5:1 on the opaque Crimson Gold surface — translucent surfaces are NOT
qualified). Submission stays gated at four independent points
(`AiService.submit`, the composer's `canSubmit`, the panel's `submit`/
`submitfile`, `AiState.submitFile`); readiness is captured before the
attachment assignment, so even a synchronously ready first attach needs a
second explicit send. The status IPC exposes preview metadata and the static
error only — never CSV contents or the attachment path. The preview strings
"Review the CSV preview before sending." / "CSV preview failed. …" are
IPC-feedback only: the composer's Enter/Send are pre-gated by `canSubmit`.
Offscreen checks: `AiAttachmentPreviewCheck.qml` (reader lifecycle, same-path
retry bursts, destruction), `AiPreviewServiceCheck.qml` (host gates through the
bundled stub broker) and `AiDetachedWindowCheck.qml` (the real
`WorkspaceWindow` grows its measured minimum so disclosures stay inside a
720px-wide window; both that check and the Quickshell-free replica in
`tst_AiWorkspace.qml` pin the full-preview floor in a 660–680 band around the
measured 669px — Quickshell only loads inside the quickshell binary, which is
why the main suite uses a replica). Known peek-card limits: the card has no
`clip`, so the row BELOW the disclosure (toolbar/actions) can hang over the
card's 720px-capped bottom at narrow widths or with busy/restoring chrome —
pre-existing shape, disclosure itself never clips — and the tightest measured
disclosure fit is 718/720 at 420px width with restore+busy+preview+10-line
draft, so any future chrome growth or note-bound increase clips there first.
Offscreen
suites cannot qualify the live Wayland scene graph — a live attach → ready →
gated send pass is still required.

Test-only `submitfile 'prompt' 'path'` (`LauncherPanel.qml`, delegated to the
shared `AiState.submitFile`) guards busy/stopping, loading and invalid requests
BEFORE draft/attachment mutation. A newly attached CSV returns `previewing`
(or `attachment-error`) and never dispatches: the current attachment must be
ready before a second explicit submit calls the same `submitAi()`; a ready
current attachment or a non-CSV file still submits synchronously. It does not
grant the model a file tool; the normal attachment flow stays `f:` Ask AI /
Ctrl+Enter, with review before sending.

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
33-prompt `bench-prompts.json` (`blocksAny`/`blocksNone`/`needsImages`
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
first full 33-prompt pass scored 23/30 raw; the exploration re-runs (styles,
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

CSV column type correction (2026-10-06, unreleased, manifest still 1.22.0,
offscreen only): `CsvTypes.js` (new, pure) infers number/date/text per displayed
column from the preview rows only (at most 10 x 20, never the whole file, never a
file read) and reports `unsure` or `empty` when it cannot say. Locale-honest on
purpose: only a plain decimal point is a number; thousands separators, spaces,
apostrophes, currency symbols/codes and accounting brackets make a column
`unsure`; leading-zero strings and integers over 15 digits are text (postcodes,
ids); 01/02/03 stays `unsure` unless a part above 12 proves the order; a column
needs all non-empty cells to agree, else `text` ("mixed"). Month-name dates,
booleans and `N/A`-style nulls are NOT recognised (text), the user corrects them.
`AiCsvPreview` shows one real `Button` per header (`aiCsvPreviewType<N>`: "123",
"date", "abc", "?", "-" plus a caret, accessible name and description say
inferred vs corrected, basis counts and reason) that opens a four-item menu
(Number/Date/Text/use inferred); Tab/Space/Return/arrows/Escape and the mouse all
work, focus returns to the header, a focused header scrolls into view. The
component only emits `columnTypeChosen`; `AiAttachmentPreview.typeOverrides` owns
the corrections and clears them in the same `invalidate()`/`fail()`/new-read path
as readiness (path, restore, workspace, new chat, retry), so they cannot outlive
the read they describe and are never persisted. `AiService.submit` captures them
BEFORE it consumes the attachment and sends `columnTypes` (<= 20 entries, enum
or null) only for a ready CSV; there is no auto-send. The broker validates the
field (exact `number|date|text`, <= 20, static error text, rejects it without a
CSV attachment, before any provider run) and appends a fixed-sentence section
whose JSON entries use the enum plus names from the broker's OWN fresh header
read, control/format characters turned into spaces and clamped to 40 characters,
never request strings. Limits: only corrections (not inferences) reach the model;
columns are positional, so a file edited between preview and send can shift them
(the names in the prompt show which header each applies to); a new type
disclosure line grew the full-preview detached floor 669 -> 692 (15px text + 8px
spacing), so both floor pins moved to 685-700 deliberately, and the peek card's
old 718/720 worst-case fit above is now exceeded by about that line and was NOT
re-measured; no live Wayland run, no mixed-DPR, no screen-reader pass. Tests:
`tests/tst_CsvTypes.qml`, the type blocks in `tests/tst_AiCsvPreview.qml` /
`tst_AiPane.qml`, the reset/transport blocks in `AiAttachmentPreviewCheck` /
`AiPreviewServiceCheck`, and `test_ai_broker.py` (validation, context, hostile
header). Not a full import, paging or whole-dataset inference.
