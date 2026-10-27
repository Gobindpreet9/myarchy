# AI Workspace: from launcher to learning, exploration, and mini-apps

Current implementation (2026-10-25, `feat/launcher-openui-native`): OpenUI is now
integrated into the native AI answer region with one retained service-owned
worker, native QML adapters and the existing composer/turns/SQLite store. New
Codex conversations automatically use the OpenUI profile; restored legacy
workspaces and Hermes retain native-block generation. Historical tools can be
selected with **Use this tool**, without multiplying runtimes. No browser or DSL
evaluation runs in Qt. See §3.4 for the runtime/state/build contract and evidence.

This is **working-tree implementation, not live desktop deployment**. Manifest/
release stays **1.22.0**; first private checkpoint `cf483da` was pushed, but the
current integration is not installed. No shell restart or user-workspace changes
were made for it. Full offline suites and resource measurements are being rerun;
no new final totals, reliability benchmark or resource-gate verdict is claimed.
Live Wayland/mixed-DPR qualification remains pending. Earlier checkpoints below
retain their dates and limits; missing-native-host statements describe the older
browser experiments, not the current implementation.

History-preserving maintenance correction (2026-10-06, **1.21.3**): the live
1.21.2 check exposed that repairing the skipped cleanup path activated the
legacy 20-unpinned/30-day deletion policy. The workspace count fell from 67 to
20. The pre-update SQLite backup recovered only the 47 missing workspaces,
48 artifacts, 111 interaction rows and 60 revisions; no existing rows were
overwritten. Automatic service cleanup now passes `preserveWorkspaces: true`
and removes only orphan artifacts, never saved conversations. A fresh AI entry
retained all 67 pre-update workspace IDs. Store and service regressions pin
this contract. Explicit manual store pruning retains its old behavior; no
automatic history-retention policy is implied by earlier housekeeping notes.

Checkpoint 1.22.0 (2026-10-06, offscreen): local CSV preview + detached
measured minimum delivered and reviewed (UX/MUST findings M1, S1-S5 and
closure findings S-1..S-8 folded in). Green: **195 Python tests (2 skipped)**
(including 22 `test_ai_attachment_preview`), **158 main QtTests** (including
the 18-case `AiCsvPreview` suite and the `AiWorkspace` probe replica), 15
blocks / 23 visual / 12 answer, isolated `AiServiceCheck`,
`AiAttachmentPreviewCheck`, `AiPreviewServiceCheck` and
`AiDetachedWindowCheck` in dedicated scratch HOMEs, `qmllint` without errors
on changed files, audit, and scratch restore with recomputed manifest hashes.
The full-preview detached floor is pinned in a 660–680 band (measured 669 at
width 720). This is NOT a live Wayland qualification: mixed-DPR, a second
display scale and the live attach → ready → gated-send pass are still pending
and must be recorded separately.

Native local CSV preview delivered (2026-10-06, **1.22.0**): attaching an
explicit `.csv` opens a bounded, credential-free review surface before any
provider work — a one-shot worker (`ai_attachment_preview.py`, 8/32 KiB
envelopes, fixed argv, cleared environment) feeds a retained reader
(`AiAttachmentPreview.qml`) and a native grid (`AiCsvPreview.qml`) showing at
most 10 rows × 20 columns × 80 codepoints with counts, sampler note and
truncation disclosures. Submission is gated at four points until the *current*
attachment is ready; a newly attached CSV returns `previewing` from
`submitfile` and never auto-sends, and restore/workspace/new-chat transitions
invalidate readiness even for an unchanged path. The status IPC exposes
metadata and the static error only. The validator's 300-char note bound sits
above the producer's measured worst case (254 chars) and is pinned against it
by differential tests, so disclosures cannot outgrow the unclipped peek
card, and disclosure text uses alpha 0.80 for >= 4.5:1 on the opaque surface.
The detached `WorkspaceWindow` no longer keeps a fixed 720×560 floor: its
measured minimum follows title + composer + pane chrome + a 160px conversation
reserve (669px with the full preview at 720 width, pinned in a 660–680 band by
both the replica and the real-window check), and a visible window grows
instead of clipping disclosures. This ships WITHOUT paging, type correction,
full-import claims or live Wayland/mixed-DPR qualification; a live attach →
ready → gated send pass remains to be recorded.

Live 1.22.0 attach → ready → gated-send pass recorded (2026-10-06): on the
committed deployment (backups + DB snapshot first), a real `.csv` attach
returned `previewing` and reached `ready` with 8 rows / 3 columns / total 8 and
no truncation; the panel and the detached window render the literal grid with
all disclosures inside the window bounds on the live scale-1.25 display. A
ragged file produced the static error `CSV line 2 has 3 columns; the header has
2.`, after which `submit` answered `attachment-error` with busy false, an
unchanged turn count and an idle broker: the send stayed gated. A shell
restart re-read the retained attachment to `ready` and kept the conversation
and all 67 user workspaces; the shell log is free of launcher errors. Held
outside the pass: mixed-DPR and a second display scale, a successful live
provider send (deliberately not attempted), the omarchy-owned `shell`/
`appLibrary` flag timing (fallback desktop scan works), a `hyprctl`
tiled-rect vs floating-center geometry mismatch (content fit verified
visually), and the codex/hermes-only `supported()` gate that requires
`~/.config/omarchy/defaults/agent` to name a supported agent for the attach
path to open (restored to `claude` after the test). One real dispatch happened
by design during testing (second `submitfile` on an already-ready attachment);
it was confined to test conversation `ws-62943ec34e1535ba` and failed codex
authentication without touching the 67 user workspaces.

Reviewed checkpoint (2026-10-06, manifest **1.21.2**): the local source is
represented by the explicit repository restore allowlist. Review corrections
align saves with the 20-turn cap, distinguish authoritative full content from
non-deleting thin saves, gate every workspace load, invalidate late timeout
responses, retire old provider sessions on workspace switches, preserve cleared
drafts, schedule restoration pruning, and retain epoch timestamps without QML
integer overflow. Store files now enforce private ownership/modes and no-follow
paths independently. Media resolution reserves the shared 12-asset budget before
downloads. Python and JS formula grammars agree on ASCII numbers and real-domain
failures. Depth text has measured geometry; hero-image replacement is wired to
saved state; keyboard focus scrolls into view; detached controls and initial
restore loading hints are correctly gated. These are checkpoint repairs, not
CSV preview, full dataset import, paging or the Phase 3 exit. New live lifecycle
verification remains separate from the software/offscreen regression results.

Follow-up review also bounds legacy hydration before resaving, guards every
intermediate formula operation (not only its final result), preserves scientific
notation exponents, and gives long multiline drafts a real caret-follow scroll
viewport with pinned action controls. No external scratch image is required.

Exact-index verification (2026-10-06, 1.21.2): 172 Python tests (2 skipped),
114 main QtTests, 15 blocks, 23 visual and 12 answer checks; isolated service
and store checks; repository audit and scratch allowlist restoration all pass.
The root restore suite passes 28 tests separately. Existing standalone QML and
Python resource warnings remain; these software-rendered checks do not validate
live Wayland lifecycle, a second scale or the remaining resource-budget gates.

Scoped live checkpoint verification (2026-10-06, 1.21.2): applied only the 63
committed launcher files after reviewing live-to-commit diffs, capturing a
SQLite backup, and checking for source conflicts. The shell was stopped during
replacement to avoid partial hot reload; desktop shell/bindings were untouched.
Restart restored `ws-52ce449a43c89ab5` with **Sorted · Filtered**, `o`, **3 of 8
rows**, Porto 600 / Lisbon 900 / Oslo 1200. Real Shift+Enter then `X` in a
ten-line synthetic draft showed the tail inside the capped editor with Send
pinned; the original draft was restored afterward. The detached window's
reverse-Tab reached visibly focused **New chat**, not hidden Back; Expand was
absent. Close/reopen kept the same workspace. Cropped screenshots
`/tmp/opencode/checkpoint-live-restored.png`, `checkpoint-live-long-draft.png`
and `checkpoint-live-detached.png` were read and visually inspected. No model
request was sent. The shell log showed no launcher errors (unrelated portal and
lock-explorer warnings remained). This checks these paths on the existing
fractional display, not a new image-gallery/DPR or full resource qualification.

Checkpoint preparation (2026-10-06, manifest **1.21.1**): bundled an in-memory
store/broker fixture for `AiServiceCheck` and made internal helper-path/state-root
injection effective. The check verifies injected dependencies before enabling
storage; it no longer depends on a disappearing scratch script or starts a real
provider. Earlier service-check isolation claims relied on ineffective readonly
overrides and are superseded by this fix. Documentation and test fixtures are
identity-neutral; runtime state and credentials stay outside repository commits.

Status: **Phase 3 underway; native OpenUI implemented, qualification pending**
(2026-10-26; working tree only, manifest still **1.22.0**). The existing native
task/calculator/CSV/workspace features remain alongside the new OpenUI path;
neither a Phase 3 exit nor general arbitrary-code artifacts are claimed.

Previous UI slice (2026-10-23; no release/canonical sync): task-first
composition now promotes existing native tools ahead of supporting prose and
uses task titles, an explicit long-explanation disclosure, wide form context
rails and coordinated diagram/control columns. Stored block/state identities
are unchanged. This improves existing saved answers without a schema migration.
Comparisons now use readable matrices or a shortlist with one inspected option,
recommendation/evidence before an explicit AI continuation action. Plans expose
progress, the first unfinished item and navigation to its actual row. These are
real native interactions, not generated executable layouts or a new runtime.
Prompt guidance prioritises useful task objects and brief orientation within
the existing budgets. Current screenshots are reproducible offscreen fixtures,
not evidence of better real-provider selection or new live lifecycle coverage.

Previous audit: **existing October 9–10 work reconciled**
(2026-10-22; installed manifest still **1.22.0**, no new product feature built).
Beyond the October 8 checkpoint, installed code includes editable calc data,
named scenarios/comparison, local undo/redo, Markdown/CSV copy, local calc
duplication, forms, actions/compare/timeline, “Ask about this”, Codex prompt
de-duplication/timing and soft block failures. Existing table tools, CSV preview/
type correction, kept-source paging/statistics, typed computation, workspace
Rename/Duplicate and bounded follow-up context remain implemented. Provider
sampling is still distinct from the full kept source.

Recorded live evidence includes the 100k × 20 kept-source check and the scoped
October 10 calc pass: keyboard table editing with hand-checked scores, undo/redo,
two saved scenarios and their comparison, CSV copy, local duplicate-as-new-turn
and restart restoration. This does not qualify every control: workspace
Rename/Duplicate, forms/waiting UI, dynamic-control/focus live clicks, corrected-
type delivery, calc provenance/numeric-input typing and mixed DPR/second scale
remain open. The October 10 missing compare-block body/stale-QML observation is
unresolved. See `AGENTS.md` and §5.1 for exact scope and known gaps.

That audit's scratch/offscreen verification passed **624 Python tests (2 skipped),
1,710 main QtTests, 28 blocks / 23 visual / 12 answer**, plus all eight isolated
checks listed in README. The main total includes eight new strict-equality
helper checks. Only test helpers, fixtures/assertions and docs changed during
this resume; no real provider or live user state was used. Existing
`ResourceWarning`s remain. Final logs are under
`/tmp/opencode/launcher-status-20261022-6ts2myhe/` (`*-final.log`, `visual.log`,
`answer.log`, `<Checkname>.log`). Canonical `~/Work/myarchy` is clean at
launcher commit `0a4ba8e` (October 6); the initial audit found 94 installed files
different/new before the new test-helper files. No sync, release, commit or push
was performed.

Next: finish native OpenUI regression/reproducibility and resource verification,
then qualify actual provider selection, end-to-end interaction quality and live
desktop lifecycle with approval before deployment. Persistence-refusal
notices, calculator-scenario reveal/paging and CSV/Markdown parity remain a
secondary backlog, not the owner's primary goal. Full state-aware AI revisions
(targeted artifact patches), full conversation branching and a general
arbitrary-code artifact runtime are not built. The restricted OpenUI DSL runtime
in §3.4 is implemented, not that broader escape hatch. No Phase 3 exit or full
dataset/resource qualification is claimed; instrumented CPU/wakeup attribution, decoded-pixel profiling and the
other recorded resource/live gates remain outstanding. Earlier dated checkpoint
paragraphs retain their historical qualification limits.

Prior delivery: Phase 1 delivered `ai:` entry, Ask AI discovery, the multiline composer, the versioned workspace store with restart restoration, artifacts/revisions, saved-workspace search, the Peek/Explore cards, and the detached window. Phase 2 added the learning-loop vocabulary (steps/check/predict), the native diagram scene, bounded local computation (slider + formula readouts), slider-to-diagram coupling, and multi-image exploration (gallery blocks, up-to-three image candidates with local Show-another, an enlarged viewer). Gallery output has live verification; the actual enlarged viewer is now live-verified after geometry refinement. Plain-image Show another has unit coverage only, with no recorded live verification. Medium selection is now automatic and subject-driven: the plain question "Help me recognise Gothic, Romanesque and Renaissance architecture" produced a resolved three-item gallery with no format hints, and the seasons question produced a coupled diagram+slider. Contextual model suggestions render as composer-filling chips. Adaptive explanation depth landed (manifest 1.17.0, extended in 1.17.1/1.17.2): the latest answer with a learning block offers **Simpler** / **More depth** / **Another example** prose sidecars that leave the blocks and their state untouched, and a stale resumed provider session — depth explains included — now falls back to a fresh session once instead of hard-failing follow-ups. Seasons flagship acceptance run (manifest 1.17.3): through the real entry flow, the seasons question produced a 7-part orbit diagram plus a month slider with two diagram links and an honest note; **Simpler** persisted a prose sidecar on the same turn; the transfer follow-up ("If it is summer in Australia right now, roughly what month is it, and why?") answered correctly from the tilt concept (October is not Australian summer; it runs roughly December–February when the Southern Hemisphere tilts toward the Sun); and a full shell restart restored the two-turn conversation with its workspace, blocks and explanation intact. That run exposed and fixed a real save-gating bug: after **New chat**, `restoreSettled` stayed false and suppressed every autosave until close (`AiServiceCheck` now asserts a fresh conversation is immediately persistable). Phase 2 exit evidence was recorded under manifest 1.19.3 with the limits below; refinement and outstanding measurements remain.

Medium-selection benchmark (manifest 1.19.0): the plan's 30-prompt evaluation now exists as `ai_bench.py` plus the versioned `bench-prompts.json` (8 learning / 8 exploration / 8 mini-app / 6 simple+mixed+failure, each with structural expectations: required or forbidden block kinds, resolved images, hard failure states; qualitative review stays a human step over the JSON). The harness drives the RUNNING shell through `newchat`/`submit`/`status`, waits for each answer, reads the persisted artifact read-only, and evaluates structure per prompt; it prints a per-prompt line and writes a JSON report (summary by kind). Five offline tests pin prompt-file validation, expectation evaluation (including "slow is a note, not a failure"), image checks, the newest-revision read, and the summary. First live baselines: a four-prompt smoke passed 3/4 (the failure was a harness read racing the settled save — fixed with a bounded retry), and a six-prompt baseline passed 4/6: one failure was Wikimedia rate-limiting the gallery ("Media provider rate limited this request" — an honest environment flake now surfaced in the verdict note), the other was model variance (the predict prompt answered in prose). The first genuine medium-selection finding came from repeated runs of the architecture prompt: the model drifted to tables for recognition tasks; the gallery rule was strengthened ("when the user wants to RECOGNISE or IDENTIFY something visual, prefer the gallery so they can actually see the differences") and the next run selected the gallery again. The full 30-prompt pass and the 80% target remain to be run and scored.

First full benchmark pass (manifest 1.19.1): the 30-prompt list ran end-to-end on real output. The raw single-shot score was 23/30; triage showed two causes that were not medium-selection failures — the harness read a pre-enrichment "Loading visual…" snapshot saved by the autosave during slow media resolution (fixed with a bounded settled-read retry keyed on the loading placeholder, unit-tested), and three mini-app expectations were narrower than the plan's own vocabulary (budget/decision/recipe accept checklist/steps/metric as appropriate). After the harness fix and expectation calibration (three exploration prompts re-run: styles, birds, posters all passed on re-run; three mini-app results re-scored offline), the consolidated baseline is **29/30 with one environment failure** — explore-clouds was failed by Wikimedia rate-limiting under benchmark load ("Media provider rate limited this request; try again later"), not by selection. By kind: learning 8/8, exploration 7/8, mini-app 8/8, simple 3/3, mixed 2/2, failure recovery 1/1 — above the plan's 80% useful-interaction target for this baseline, with the caveats that the raw single-shot number was 23/30, that one prompt is environment-blocked, and that medium selection remains non-deterministic (the recognition-drift finding above).

Typographic refinement (manifest 1.19.2): the AI surfaces no longer carry raw font sizes — the launcher token set gained `small: 12, body: 14, subtitle: 17, prompt: 20, display: 29` (values identical to the literals they replaced, so no visual change by construction) and every `font.pixelSize` in the AI components now references a `Satin.type` token; `AiButton.qml` gained the missing `SatinGlass.js` import that the refactor exposed (a runtime-only failure `qmllint` could not see). Verified with 106 main / 23 visual / 14 blocks / 11 answer QtTests all green, `qmllint` clean, and a live hot-reload open with no shell-log errors. The same audit found no hardcoded colors anywhere in the AI components (all colors flow from the injected theme tokens), and the text-only additions (trail line, depth sidecar) are non-focusable so keyboard order is unchanged.

Keyboard/theme/accessibility refinement (manifest 1.19.3): the live tab chain was walked end-to-end on real answers — composer → answer summary → diagram parts (each selectable) → stepper controls and advance → **Simpler / More depth / Another example** → Copy → toolbar → back to composer; a fresh gallery walk showed every cell's chain as **frame (viewer) → Photo details → replacement**, and the reverse walk visits the same ring. A restore-time walk initially skipped gallery cells because the frame's focusability was gated on `imageReady`; the frame is now focusable while loading or errored too (viewer keys stay guarded), which also makes errored images reachable for keyboard users, with the status text as the accessible name and a real focus ring in every state; after the fix the restore walk enters all three cells immediately. Offscreen coverage: `test_galleryCellsEnterTheKeyboardChain` (Tab reaches a gallery example and its replacement control; 107 main QtTests). Theme resilience: switched the live theme to Kanagawa and back — the AI surface repainted from the injected tokens with state intact and no shell-log errors (Crimson Gold restored). Live scaling remains the real fractional condition (DP-1 at scale 1.25); a second scale was not exercised.

Phase 2 budget verdicts against §4.8, from the recorded measurements and direct storage inspection (manifest 1.19.3): **static native answer** — AI-visible with a cached answer measured within sample noise of rest (500.6 vs 506.9 MiB shared-tree median), far below the 96 MiB incremental ceiling for the native surface (shared-shell figures, not an isolated A/B); **active native learning/tool workspace** — +28 MiB aggregate over rest including broker (35 MiB) and store worker (8.7 MiB), below the 192 MiB native/helper ceiling, with the provider CLI's 435 MiB PSS recorded separately and in the total as required; **idle after close** — zero AI helper processes and no measurable retained increment beyond ambient variance, inside the ≤20 MiB + zero-helper gate; **settled idle CPU** — attributable CPU is effectively zero because no feature-owned process survives close (the shared-tree percentages are ambient and not instrumented for attribution, so the <0.1 % one-core bar is argued from process absence, not tracing); **media cache** — 32.1 MiB exact across 35 files, held at the 32 MiB cap by startup pruning (the plan's 64 MiB allowance for galleries remains available headroom); **store** — 64 workspaces in a 0.2 MiB database with a 2.8 MiB WAL, 61 artifacts, 77 revisions and 145 interaction rows, with the 256-revision cap enforced per artifact and tested. Unmeasured and explicitly not claimed: the full 100,000-row dataset paging/UI gate (the 2026-10-05 isolated sampler check below is narrower), programmable-artifact runtime budgets, decoded-pixel profiling at DPR, instrumented wakeup/CPU attribution, and a second display scale.

Phase 3 opener — comparison table as a local tool (manifest 1.20.0): the `table` block is no longer static. Column headers are buttons that cycle ascending → descending → authored order, sorting numbers numerically and text lexically; a filter field appears for tables of four or more rows and narrows rows by literal case-insensitive substring (never a pattern), with a live "n of m rows" count while filtering. Both the arrangement and the filter live in the turn's persisted interaction state (`table:<blockIndex>` = `{sort, dir, filter}`), so reopening a workspace restores the user's arrangement, and the exploration trail gained **Sorted** and **Filtered** entries. Verification: `AiBlocksCheck.test_tableSortsAndFiltersLocally` (header click emits one scoped state edit, applies numeric-aware ordering, cycles all three states, filters to "1 of 4 rows", and proves the filter is literal); trail unit tests for the two new entries; live run — a fresh comparison answer's header was reached by Tab, Return cycled to descending, the state persisted (`{"88":{"table:0":{"dir":-1,"filter":"","sort":0}}}`) and survived a full shell restart restore. This starts Phase 3's "comparison tool works with user changes, accurate local computations, persistence" deliverable; CSV import and scenario controls remain.

Phase 3 CSV sampling foundation (2026-10-05, manifest **1.21.0**): explicit home-contained/no-follow regular-file attachments with case-insensitive `.csv` read the first 8 MiB. Strict comma `csv.reader` parsing accepts UTF-8 with optional BOM, preserves whitespace, and reports understandable turn errors for ragged/malformed rows or oversized fields without killing the worker. The unchanged non-CSV 64 KiB guard also rejects growth after stat. A read-window boundary withholds an incomplete UTF-8 codepoint and discards an incomplete logical CSV record, including multiline quoting. The provider snapshot keeps at most 200 prefix data rows, 20 columns and 80 characters per header/cell, bounded to 24,000 complete serialized UTF-8 JSON bytes, including metadata, quotes and escapes. `columnsTruncated` and `cellsTruncated` disclose loss separately and contribute to overall `truncated`; exact `totalRows` requires a fully read source, otherwise null. `ai_catalog` requires sample-only claims and forbids whole-file aggregates or exact calculations/identifiers from clipped values. This is an import/sampling foundation for provider context, **not** the
complete source, a type-correction UI, a full resource copy or paged
exploration; the local native CSV preview is a separate surface delivered in
1.22.0.

The test-only `submitfile 'prompt' 'path'` IPC rejects busy/stopping, loading and invalid requests before draft/attachment mutation; a newly attached CSV returns `previewing` (or `attachment-error`) without dispatching and needs a second explicit submit once the current preview is ready, while a ready current attachment or a non-CSV file calls the same `submitAi()` synchronously. It grants no model file tool; users still attach via `f:` Ask AI / Ctrl+Enter and review before sending. The table filter ring now uses `activeFocus` (`visualFocus` is not a `TextField` member), and `tableState` avoids shadowing `QQuickItem.state`. `tests/AiBlocksCheck.qml` now exercises actual keyboard filter editing, its state emission and focus ring. `tests/test_ai_broker.py` pins serialized UTF-8/escape bounds, prefix retention, separate clipping disclosure, whitespace, BOM/multiline parsing, ragged/malformed errors, read-window records/codepoints, and worker recovery after malformed/oversized fields with one-time snapshot accounting.

Verification (2026-10-05, manifest **1.21.0**): 107 main QtTests, 15 blocks, 23 visual and 11 answer checks; 161 Python tests (2 skipped with normal offline-audit flags unset); isolated `AiServiceCheck` and `AiWorkspaceStoreCheck` passed with scratch state. No test failures. Lint reported no errors but existing standalone `qs.Commons` resolution, Quickshell, old state-override, unqualified-access and `MoveAnchor` warnings remain; do not read earlier historical lint wording as a current warning-free claim. Existing Python database/test-pipe `ResourceWarning`s remain.

Live foundation check: the corrected eight-row synthetic `~/rents-sample.csv` was submitted and all eight native table rows compared unchanged to the fixture. Concurrent `submitfile` returned `busy`, leaving the empty draft/attachment untouched. Rent-header Tab + Return sorted ascending; filter `o` typed with real `wtype` yielded Porto 600, Lisbon 900, Oslo 1200, **3 of 8 rows** and **Sorted · Filtered**. Full restart visually restored the same rows/count/arrow/filter/trail. Workspace `ws-52ce449a43c89ab5`, turn 92, persisted `{"92":{"table:0":{"dir":1,"filter":"o","sort":1}}}`. Screenshots `/tmp/opencode/csv-live-table.png`, `/tmp/opencode/csv-live-filtered.png`, `/tmp/opencode/csv-live-restored.png` were read and visually inspected, unlike earlier captures.

Isolated **sampling-only** stress: 100,000 numeric rows × 20 columns, 14,989,091 source bytes; snapshot took 0.202 s and returned 140 prefix rows in 22,157 serialized JSON bytes, `totalRows: null`. Peak process RSS was 82,020 KiB and includes the full Python process plus fixture generation, **not** incremental memory, PSS or native UI responsiveness. Record: `/tmp/opencode/csv-sampling-stress.json`. This does not satisfy the full 100k-row dataset stress exit. Later kept-source paging/persistence, preview type correction and typed units/cycles checks supersede the implementation gaps at this sampling checkpoint, not its measurement limits; full resource qualification and the narrower live gaps in the current Phase 3 slice remain outstanding.

Exploration trail (manifest 1.18.1): every answer now carries a compact trail line derived only from persisted interaction state (`AiState.trailSummary`): "Checked" / "Predicted" / "Stepped through" / "Scrubbed" / "N examples replaced" / "Depth added", joined with " · " and shown silently when there is nothing to report. An attempted selection counts as exploration and shrinking it back to empty removes the entry; predictions count only once committed (the stored index); being on the first stage of a stepper is not "stepped through". Unit-tested key by key (unknown keys never invent entries) and rendered under each turn in `AiPane` (`aiTrail`); because the trail is pure state it restores with the workspace.

Architectural-styles flagship acceptance (manifest 1.18.0): through the real entry flow, "Help me recognise Gothic, Romanesque and Renaissance architecture" produced a resolved three-item gallery, and gallery items now resolve two candidates each (media budget widened to 12 assets/answer) so a single example can be replaced without resetting the comparison: the in-cell **Show another** swaps just that item through its own `gallery:<block>:<item>` state key. Live-verified: items 0 and 2 replaced independently while item 1 stayed untouched, persisted as `{"10":{"gallery:0:0":1,"gallery:0:2":1}}`, and restored intact after a full shell restart. `AiVisualCheck` pins the scoped replacement path (exactly one state edit, key `gallery:0:0`, value 1).

Image refinement (2026-10-04, manifest 1.12.1): galleries now reserve equal aspect-fit comparison frames, preserving the full subject and full wrapping captions through loading/errors. The viewer uses actual fitted geometry relative to the Flickable viewport, centered fit/2× zoom, bounded drag/arrow-key panning, a reserved credit footer, and zoom reset/focus return on close; its hidden image source is cleared. Compact/expanded native galleries, keyboard opening of full uncropped images, zoom/pan, Esc return to `aiImageFrame`, credit focus on `aiImageCreditClose`, and close/reopen were checked live with no active-shell-log errors. Mixed-DPR remains untested. See README for suite counts; these checks do not complete a roadmap phase or establish resource-budget compliance.

Efficiency revision: resource qualification is the immediate milestone before expanding the feature set. The read-only `ai_resource_probe.py` is released after each measurement run and the first paired shared-shell observations are recorded below; lazy restore (manifest 1.13.0) landed as the first lifecycle-refactor slice, the burst-oriented store worker (manifest 1.13.1) as the second, collapsed-history unloading plus event-driven supervisor waits (manifest 1.14.0) as the third and fourth, and the idle-broker lifecycle (manifest 1.15.0) as the fifth, and coalesced dirty-field saves (manifest 1.16.0) as the sixth. Adaptive explanation depth (manifest 1.17.0) is Phase 2 product work, not a lifecycle slice, so the resource-milestone remainders — feature-attributable A/B baselines, job peaks, the full interact/answer-cycle plateau, media/mixed-DPR readings, the remaining lifecycle refactors, and every budget pass — are unchanged.

Lazy-restore slice (2026-10-04, manifest 1.13.0): boot and saved-workspace discovery are metadata-only; the latest workspace hydrates once on real AI entry, with the pane showing **Loading your last conversation…** and submit gated until the load settles (5-second watchdog). Text or attachments typed or set in flight survive the completed snapshot (entry-state carry compared against the live draft); a programmatic empty draft never blocks restoring the stored one. Closing the launcher commits a pending debounced draft/attachment save; AI IPC resumes an existing conversation instead of forcing a bare prompt. Store responses route by the running op, so queued jobs cannot misroute, and superseded load responses are discarded by token. This is the first lifecycle slice of the milestone; burst-oriented persistence landed next as the store-worker slice (1.13.1), then collapsed-history unloading and event-driven supervisor waits as the 1.14.0 slices, the idle-broker lifecycle as the 1.15.0 slice and coalesced dirty-field saves as the 1.16.0 slice (below). Acknowledged close/delete, the re-taken closed-state reading, the A/B baselines, and all budget passes remain. See README for suite counts.

Store-worker slice (2026-10-04, manifest 1.13.1): persistence is now burst-oriented over one persistent worker. `ai_workspace_store.py` gained `--serve`: one JSON line per request (`{op, payload}`) answered strictly in order over one connection, in-band static error results, and a structured read loop that keeps lines sharing a transport chunk together; `fd`/`idle` parameters exist for tests, idle-exit is configured by `LAUNCHER_STORE_IDLE` (test-only) and a Python-side self-exit fires after roughly 30 s of no requests. `AiService.qml` now runs ONE lazy demand-started Python store worker per session instead of one interpreter per operation: the burst queue writes through the same open stdin pipe (`stdinEnabled` is never flipped — flipping closes the pipe and EOFs the worker), results are matched to requests by order, the store idle timer releases the worker 30 s after the last operation, only a queue with real work resurrects it, and killing the worker mid-burst restarts it for queued work. Verification: two new Python tests (worker burst order/in-band errors/idle+EOF exit; worker error contract and empty-store null load), 102 main QtTests, 14 blocks, 11 answer, 22 visual, 138+2=140 Python tests total, the isolated service/store checks (`AiServiceCheck`/`AiWorkspaceStoreCheck`) green, `qmllint` clean on `AiService.qml` (environmental warnings only), and live shared-shell runs: one worker PID reused across entry/typing/close/reopen with no per-op respawn, worker present during bursts, and the idle self-exit observed (exit 0 with an empty queue, not resurrected). Honest note: live patterns showed both a session-persistent worker and a Python-side idle self-exit; both keep store operations correct; per-session process count is now one instead of one-per-op. No efficiency measurement beyond that process-count observation is claimed. This is the second lifecycle slice of the milestone.

Collapsed-history slice (2026-10-04, manifest 1.14.0): `AiPane.qml` conversation rows are now Loader-gated — each turn renders through a `Loader` active only when it is the newest turn or history is expanded — so collapsed history is uninstantiated entirely: its native answer trees, sibling images and delegates are released, expanding materialises them, and collapsing releases them again. The row component lives at file-root scope and receives its per-row data through the visual parent (the `host: parent` component-boundary rule in `AGENTS.md`); `WorkspaceWindow.qml` embeds the same pane and inherits the behavior. Verification: regression test `test_collapsedHistoryDoesNotInstantiateHeavyAnswers` (older answer tree absent while collapsed, present after expanding, released again on collapse), main suite now 103 QtTests. This is the third lifecycle slice of the milestone; it does not yet measure release, and cache/GPU reclamation remains unquantified.

Event-driven-supervisor slice (2026-10-04, manifest 1.14.0): the `ai_broker.py` guard/`supervise` no longer polls — the 20 ms `proc.poll`/sleep loop is replaced by a reaper thread taking `proc.wait()` and a `threading.Event` that the SIGTERM/SIGINT handlers set, so both paths (child exit, supervisor signal) wake the main thread exactly once. Cancellation/descendant cleanup (TERM → SIGKILL of the group, adopted-children reaping) is unchanged; the unused `time` import was removed. Verification: new test `test_supervise_waits_event_driven_and_tears_down_group` covers natural-exit passthrough (exit 7) and immediate TERM wake (exit 143) with the group leader torn down; Python suite is now 141 tests (2 skipped), the isolated service/store checks are green, and `qmllint` is clean on `AiPane.qml`. This is the fourth lifecycle slice of the milestone.

Idle-broker slice (2026-10-04, manifest 1.15.0): the broker now has a service-side closed-state lifecycle. `ai_broker.py` lets a fresh broker adopt the persisted provider session from submit's `resumeSession` hint — validated against the same `[a-zA-Z0-9_-]{1,128}` pattern as provider sessions — while a warm broker ignores the hint because its own session is newer. `AiService.qml` sends the persisted `sessionId` with every submit request, tracks `panelActive` (raised from `LauncherPanel`'s `syncPanelActive()`) and `windowActive` (raised from `WorkspaceWindow`'s `onVisibleChanged`), stamps `lastBrokerActivity` on every `send()`/`receive()`, and `brokerIdleCheck()` returns true only when the broker is started, not busy/stopping, every AI surface is hidden, and the last activity is 30 s or more old. A 1-second repeating timer then retires the broker via `broker.running = false` (the Quickshell Process terminates the child), and the next submit cold-starts a fresh broker that resumes the persisted session. QML note: `Timer.repeat` defaults to false — the lifecycle timers must set `repeat: true`; the store idle/stall timers were fixed the same way. A test-only `submit` IPC (`omarchy-shell rosakodu.launcher submit 'text'`) drives the exact submit path without keyboard input (used by the harness; ordinary users still use Enter). Verification: live shared-shell run — restart with no broker, submit via IPC, answer completed, surfaces closed, broker retired ~30 s after the last activity (retirement observed in the shell log); gate state exposed via `status` (`brokerIdle`/`brokerRunning`). Suites: 103 main QtTests, 14 blocks, 11 answer, 22 visual, and 143 Python tests (2 skipped — the 141 of the previous slice plus `test_resume_session_survives_broker_restart`, where a fresh Broker resumes `resume abc -` in the provider argv after `stop()`, and `test_resume_session_rejects_foreign_patterns`, where invalid hints never reach the argv); `AiServiceCheck` includes broker-lifecycle assertions, the isolated store check is green, and `qmllint` is clean. This is the fifth lifecycle slice of the milestone; it addresses the closed-state idle-broker cost (≈18 MiB PSS, one process) of the first observations (below), whose closed-state reading is re-taken as a future item rather than re-measured with this slice.

Coalesced dirty-field saves slice (2026-10-04, manifest 1.16.0): autosave and close-commit now write through `AiService.savePayload()` instead of `workspaceSnapshot()` — the small workspace row fields (id/title/summary/agent/sessionRef/draft/attachment) are sent on every save, and the full artifacts/interaction serialization only when conversation content actually changed: `onTurnsChanged`/`onChecklistStatesChanged`/`onUiStatesChanged` raise `dirtyContent = true`, which the next full save consumes, so draft/attachment-only edits write a thin payload with empty artifacts/interaction lists. `newConversation`'s final save of the finished conversation stays full (`workspaceSnapshot()`). The store was already upsert-only for artifacts/interaction (no implicit deletes), so content omissions preserve stored rows; the new Python test `test_partial_save_preserves_stored_content` pins that contract (a draft-only save leaves artifacts and interaction rows intact; a later full save stays consistent), and `AiServiceCheck` asserts the payload shapes (thin for draft-only, full for content changes, dirty flag consumed). Honest boundary: the store deliberately remained full-row for workspace fields — `cmd_save` was NOT changed to field-preserving semantics (a COALESCE attempt broke NOT NULL columns and was reverted) because the launcher always sends the complete, cheap workspace field set; the coalescing win is skipping the heavy content serialization, not byte-level elision of the workspace row. Verification: 103 main QtTests, 14 blocks, 11 answer, 22 visual, 145 Python tests (2 skipped, including the new `test_partial_save_preserves_stored_content`), `AiServiceCheck` and `AiWorkspaceStoreCheck` green, `qmllint` clean; live shared-shell run — a draft-only edit, close committing a thin save, reopen restoring both the draft and the full prior conversation (turns intact). This is the sixth lifecycle slice of the milestone.

Adaptive explanation depth slice (2026-10-04, manifest 1.17.0, delta 1.17.1): learning answers gained a prose-only depth sidecar, and resumed provider sessions gained a stale-session fallback. The broker's new `explain` op reuses the provider run with `EXPLAIN_GUIDANCE` appended to the prompt, emits no deltas and no presentation/media enrichment, keeps only the final prose (structured blocks the model returns are dropped; an empty explanation is an error: "No explanation was returned."). Any run that adopted a persisted session hint — an ordinary submit or a depth explain — now clears the session and retries once from a fresh session (`allow_resume=False`) when the provider raises `ValueError`, because a restored conversation's `sessionRef` could be stale after a shell restart and hard-failed every follow-up; provider-side continuity is best-effort, availability is not. The 1.17.1 delta added **Another example** (`aiDepthExample` → `explainLatest("example")`, treatment text "another example") and tightened `EXPLAIN_GUIDANCE` so "another example" means one fresh, specific situation (a place, object or everyday case) showing the same idea, not a restatement of the mechanism. EXPLAIN_GUIDANCE is appended exactly once in the command handler (before size/context accounting), so a stale-resume retry cannot duplicate it (pinned by `test_explain_retry_includes_guidance_once`, manifest 1.17.2). `AiService.explainLatest(mode)` builds a bounded context from the latest learning block only (diagram selection label, slider value+unit, steps index), is gated on busy/loading/stopping, sends `{op:"explain", turnId, agent, prompt, resumeSession?}`, and its `explain` receive path sets the latest turn's prose `explanation` and clears busy — it never appends a turn or rewrites blocks. `explanation` persists in the interaction turn rows, restores with the workspace, and appears in the text fallback (`AiState.textAnswer`). `AiPane.qml` shows the `Simpler` / `More depth` / `Another example` actions only on the latest answer with a learning block (hidden while busy) and renders the explanation as a bordered prose box (`aiDepthActions`/`aiDepthSimpler`/`aiDepthDeeper`/`aiDepthExample`/`aiDepthText`/`aiDepthTextLabel`); the test-only `depth '<simpler|deeper|example>'` IPC drives the action. Verification: three new broker tests (`test_explain_emits_prose_sidecar_only` — prose only, blocks dropped, no done/presentation/delta; `test_explain_rejects_missing_text`; `test_stale_resume_falls_back_to_fresh_session`), the `AiServiceCheck` depth assertions (busy gate, explain receive, persistence), and `test_adaptiveDepthActionsAndSidecar` in `tests/tst_AiPane.qml` (all three actions on learning answers, hidden on plain ones, sidecar text). Suites: 104 main QtTests, 14 blocks, 11 answer, 22 visual, 148 Python tests (2 skipped), `qmllint` clean. Live shared-shell runs: restart → AI entry → `submit seasons` (diagram+slider answer) → `depth simpler` → the prose explanation persisted on the turn with the blocks untouched; and (1.17.1) restart → sky-blue submit → `depth example` → the sunset-red example persisted with the blocks untouched. This is Phase 2 product work continuing adaptive depth, not a lifecycle slice: the resource-milestone remainders — the full interact plateau, longer-job provider peaks, media/mixed-DPR readings and the budget verdicts — are unchanged.

First paired A/B observations (2026-10-04, manifest 1.14.0): five 60-second probe runs on one verified shared-shell PID (387618), no restarts between runs (reports `/tmp/opencode/ab2-*.json`). Rest baseline (launcher never opened, no AI): 506.9 MiB median tree PSS (shell 481.3), zero launcher helpers. AI visible with a cached 2-turn answer and collapsed (loader-gated) history: 500.6 MiB — **within sample noise of rest (Δ −6.3 MiB)**; zero helpers; no retained incremental memory from the static AI surface. Active live generation: 534.9 MiB median (Δ +28 MiB), with the provider CLI (codex) at **435 MiB PSS** — recorded separately and in the total per §5.4 — broker 35 MiB (broker+guardian), store worker 8.7 MiB. Closed 40 s after the job: 518.2 MiB (Δ +11.3 MiB), provider and worker gone, and the sole retained AI cost was the **idle broker (~18 MiB PSS, one process)** — addressed by the idle-broker slice (1.15.0), which retires the broker once every AI surface is hidden and resumes the persisted provider session on the next submit. Post-fix re-reading (`/tmp/opencode/ab3-closed.json`, manifest 1.15.0): the closed state now shows **zero broker/worker/provider processes** (median 518.3 MiB, peak 518.4 — the earlier +11–18 MiB against rest is ambient shell variance, not AI). First plateau probe (manifest 1.16.0): 50 scripted open/close cycles on the shared shell — descriptors flat (189 → 186) and **zero AI processes 35 s after the burst** (no orphan accumulation); a full interact/answer-cycle plateau and longer-job provider peaks remain to be measured before any gate verdict. CPU percentages are shared-shell ambient (agent updater, hyprctl, ddcutil, pacman, external-provider trees) with incomplete intervals and are deliberately not attributed to the launcher. These are paired single-session observations, not a repeat-use plateau and not a gate verdict; provider peaks over longer jobs, media resolve, mixed-DPR, and the full 50-cycle interact plateau remain unmeasured.

Date: 2026-10-05

Home: `~/.config/omarchy/plugins/rosakodu.launcher/`

## 1. Executive Summary

### Problem statement

The launcher already produces useful structured answers, but its interaction model is largely a short document inside a temporary popup. Different questions receive similar compositions, pictures are selected narrowly, and most follow-ups require another text prompt rather than interaction with the subject itself.

The original entry syntax conflicted with file search: AI used `:ai` while files used `f:`. The implemented AI entry syntax is now **`ai:` only**, with no `:ai` compatibility alias.

### Proposed solution

Build a persistent AI workspace that starts at launcher speed and grows into the interface the task deserves: a visual explanation, a guided lesson, an exploratory collection, a simulation, or a useful mini-app. A question can take five seconds, ten minutes, or become an ongoing project without losing its context or state.

The defining interaction is **an answer that becomes an object you can work with**. Users manipulate examples, select details, change assumptions, explore branches, and build reusable tools. Conversation supports that object and can revise it in place.

### Confirmed direction

- Learning, visual exploration, and mini-apps are all core product pillars.
- Longer sessions are welcome; the product can grow beyond a launcher popup.
- `ai:` replaces `:ai` completely.
- System efficiency is a core product requirement: negligible idle work, bounded memory, and expensive capabilities loaded only when used.
- This revision updates the plan only. Further implementation and refactoring follow separately.

### Planning assumptions

- Retain Quickshell/QML, Python orchestration/storage, theme tokens, and Codex/Hermes adapters. Refactor lifecycle and data flow first; use Rust for a demonstrated backend bottleneck if the criteria in section 4.10 are met.
- Preserve instant app/file launching as the entry experience.
- Support keyboard and pointer equally; a touch-first redesign is not assumed.
- Local, restart-persistent workspaces are the default persistence direction.
- Budget, delivery dates, new media providers, and image-generation provider are unspecified. Estimate these after the architecture spike; do not treat proposed services as already available.
- The working product name is **AI Workspace**. Naming is not a prerequisite for development.

### Success criteria

These are proposed release targets, not current measurements.

1. **Useful interaction:** at least 80% of a fixed 30-prompt evaluation set yields an appropriate usable presentation on its first response; every flagship journey passes its end-to-end acceptance scenario.
2. **Continuity:** all scripted close/reopen, restart, detach, follow-up, and undo scenarios retain the expected draft, workspace, inputs, learning position, and revision history.
3. **Responsiveness:** local interaction feedback has p95 latency below 100 ms; warm workspace opening has p95 latency below 300 ms on the development machine. Measure cold restoration separately with a target below 1 second for a typical cached workspace.
4. **Direct manipulation:** each flagship learning, exploration, and mini-app experience supports at least three useful interactions without requiring the user to write another prompt.
5. **Practical and learning value:** in owner-led trials, at least four of five representative tasks can be completed without abandoning the workspace for missing UI; teaching trials include a transfer question to establish whether the interaction helped understanding, rather than measuring dwell time alone.
6. **System efficiency:** pass the lifecycle, memory, idle CPU, process-count, and repeated-use gates in section 4.8. Fast rendering alone is insufficient; a capability that exceeds its resource budget stays out of the normal path until corrected.

### Product principles

- **The subject determines the interface.** A mechanism needs a diagram; a visual distinction needs examples; a decision needs tradeoffs and controls.
- **Immediate value, optional depth.** Answer the question first. Offer a deeper path where it helps.
- **Continuity over replacement.** A follow-up should preserve the object, selections, and reading position whenever possible.
- **Local motion and computation feel immediate.** Dragging a slider must not require a model round trip.
- **State is part of the conversation.** A chosen option, changed parameter, or incorrect prediction should inform the next response.
- **A small useful tool is a first-class result.** It can be named, saved, found again, duplicated, and revised.
- **Ambition comes from capability and composition.** Use the existing matte, theme-aware material language while substantially expanding what the surface can do.
- **Saved does not mean resident.** Persist state on disk, restore views on demand, and release heavyweight objects when they are no longer useful.
- **Pay for active capability only.** A simple launcher search must not initialise the AI backend, decode old answer images, or start a browser engine.

### 1.1 Market context: ChatGPT "Intelligent UI" (2026-10-07)

On 2026-10-07 OpenAI shipped GPT-6 in ChatGPT with **Intelligent UI**: answers composed of text,
graphics, tappable buttons, forms, charts, diagrams, maps, checklists and multiple-choice follow-ups,
plus small on-demand tools (calculators, bill splitters, recipe scaling, small games). The disclosed
mechanism is the same shape as this plan's: a library of native, streamable components and a
compiler that renders the interface while the model is still generating, so the answer appears
progressively and the model can "start answering while it continues to think". OpenAI's own
acknowledged weakness is design judgment and the range of experiences it can create. The public
coverage does not describe saving, editing, or reusing a generated tool, nor how interaction feeds
back to the model. Sources: the announcement page (blocked to automated fetch) and press coverage
(TestingCatalog, MacRumors, 2026-10-07).

What this changes for us (decision record, not a pivot):

- **Confirmed**: the declarative, bounded, native-component approach (section 3.4 level 1, section
  4.4) is the industry's chosen shape; do not drift toward arbitrary generated code for ordinary
  answers. The programmable runtime stays the Phase 4 escape hatch.
- **Where we are ahead or different**: local-first and private (state on disk, no account); the
  interface is a *workspace*, not a transcript fragment: edits, scenarios, undo, exports, duplicates
  and a durable 100k-row CSV source persist across restarts; every computed number has verifiable
  provenance and a golden-tested local engine; provider-agnostic; keyboard-first on the desktop.
- **Where we are behind**: (G1) **progressive rendering**: the launcher waits for the complete
  structured answer, then renders. MEASURED 2026-10-09 (3 real requests, broker-identical argv):
  Codex 0.160.0 `exec --json` delivers the whole structured answer as ONE `item.completed`
  agent_message at the end (no `item.updated` or partial agent_message events; first answer byte equals
  completion: 4.5 s for a greeting, about 11 s for a calc or gallery answer, all model time), so
  progressive block rendering is impossible with Codex as invoked; Hermes `stream-json` emits text
  deltas (token-chunk granularity, by code reading; not timed live); no progressive block compiler
  is built yet. (G2) **forms and actions**: the original catalogue gap now has bounded `form`
  and `actions` blocks whose explicit submissions become structured follow-ups. General form-
  to-local-calc binding and live form/action interaction qualification remain open. (G3)
  **maps and route/place visuals**. (G4)
  **design judgment** at scale: medium selection is benchmarked (33 prompts) but there is no
  visual-quality evaluation. (G5) **speed to first useful pixel**: first answer text and the
  skeleton of the interface should appear before the model finishes.
- **Roadmap effect**: promote G1 and G2 into Phase 3 (they extend the same block catalogue and
  state model), schedule G3 with the Phase 4 media providers, treat G4 as part of the Phase 5
  evaluation, and keep G5 as the acceptance metric for G1 (time to first block, p50/p95).
- **Progress through 2026-10-10; audited 2026-10-22**: G2 forms/actions and the G5 groundwork
  (honest phase + elapsed counter,
  per-turn timing metrics, Codex prompt de-duplication saving about 5.4k input tokens per
  request, per-block validation shared with any future stream) are built and offscreen-verified;
  comparison and timeline blocks plus selected-part follow-up context are also implemented.
  Small live model-output checks exercised action/timeline/comparison selection, not the full
  control/focus paths; the compare-body/stale-QML issue remains unresolved. Forms/waiting UI
  still lack live qualification. G1 for Hermes (a stream compiler) is designed, not built;
  G3 (maps) and G4 (visual-quality evaluation) are not started. Current prompt guards are
  13,000 / 15,000 / 26,000 bytes (Codex / Hermes / full), with a 13,500-byte output-schema
  guard; the conversation budget is 192 KiB, distinct from the 64 KiB text-attachment cap.
- **Non-goals**: matching ChatGPT's breadth of games and bespoke experiences before the isolated
  programmable runtime is qualified; cloud accounts; sharing generated tools.

## 2. User Experience & Functionality

### 2.1 Users and jobs

The primary user is the desktop owner moving between quick questions and sustained work. These are different needs of one person, not separate products:

| User stance | Main job | Desired result |
| --- | --- | --- |
| Curious learner | Understand an unfamiliar concept | A mental model they can test and explain |
| Visual explorer | Recognise, compare, discover, and connect subjects | A navigable set of examples and relationships |
| Practical maker | Turn a question or dataset into a useful tool | A working, editable, reusable mini-app |
| Returning user | Continue something started earlier | The same workspace with its state intact |

### 2.2 Entry and launcher integration

**Story:** As a desktop user, I want to enter AI naturally so I can ask a question without remembering inconsistent syntax.

Requirements:

- Recognise `ai:`, `ai: `, and `ai:question`, case-insensitively, only at the beginning of the launcher query.
- `:ai` no longer enters AI mode. Text containing `ai:` elsewhere remains ordinary search text.
- Consume the prefix into a visible AI mode indicator, retaining the exact editable draft after the separator.
- Preserve pasted multiline content; replace the single-line composer with an auto-growing field.
- Enter submits; Shift+Enter inserts a newline. Input-method composition must not accidentally submit.
- Add a visible **Ask AI** result for an ordinary non-empty search. App matches retain predictable ranking; selecting Ask AI transfers the query into the composer without sending it.
- Keep file search's Ask AI action and support attaching additional content from the workspace.
- Show at most three compact, capability-revealing examples in the empty AI state, such as “Explain with a diagram,” “Explore a subject,” and “Make a small tool.” They prefill a draft and disappear once work starts. Allow dismissal.
- Provide an obvious route back to app/file search without discarding the active workspace.

Acceptance:

- Parser, IPC entry, resume paths, file handoff, placeholder text, documentation, and fixtures all use `ai:`.
- No code path silently recreates `:ai` as the internal query prefix.
- Switching modes, pasting a prompt, or choosing an example never starts generation on its own.
- A keyboard-only user can discover Ask AI, enter it, submit, and return to app search.

### 2.3 One workspace, three presentation sizes

**Story:** As a user, I want a quick answer to grow into a longer activity without starting over.

| Presentation | Purpose | Proposed shape | Dismissal |
| --- | --- | --- | --- |
| **Peek** | Quick answer and one useful interaction | Launcher card, approximately 680–820 logical px wide, bounded by available screen size | Esc or outside click hides it |
| **Explore** | Diagrams, lessons, galleries, and comparisons | Expanded overlay, approximately 960–1280 logical px where space allows | Explicit collapse; Esc follows nested focus rules |
| **Workspace** | Sustained work and multiple artifacts | Resizable normal desktop window, with optional outline and inspector | Normal window lifecycle; outside click does not dismiss |

These are initial design dimensions to validate on the actual monitor and scaling configuration, not hard-coded product guarantees.

- Expand and collapse preserve workspace ID, object IDs, scroll position, focus, draft, and local state.
- Show **Open workspace** as an explicit action when a task deserves more room. Avoid moving the user's content into a different window without their action.
- The normal window participates in the compositor's usual focus, tiling, and workspace behavior.
- Default to one active view per workspace. If it is already open, focus that view rather than create competing editors.
- Closing a view retains the workspace. **Stop** cancels the current generation; deleting a workspace is a separate action.
- Offer a deliberate keep-open/pinned overlay behavior for medium sessions if native surface behavior proves reliable.
- Long-running tasks have a recoverable status and do not require keeping the launcher visible.
- A kept-open or pinned view is not an exemption from suspension when minimised or otherwise reported non-visible. Saved/pinned workspaces do not keep processes alive. Heavy views may be unloaded after the grace period in section 4.8, preserving continuity through saved state.

Acceptance:

- A learner can begin in Peek, expand, detach, close, reopen, and continue from the same step and parameter values.
- Popovers and local inspection panels consume Esc before the enclosing surface; Esc in the normal workspace window does not destroy or silently close the workspace.
- Opening and closing the quick launcher never resets a detached workspace.

### 2.4 Workspace composition and visual identity

Task-first native composition landed on 2026-10-23. The renderer identifies the
primary task from supported blocks, retains original indices, keeps linked
diagram/slider state coherent across columns and places support/sources after
the working object. Narrow decisions show a shortlist rather than a stack of
full detail cards; plans expose the next unfinished step. Width/text-view changes
do not recreate the tool. `AiTaskVisualCheck` supplies inspected illustrative
fixtures at three widths and three palettes; live/provider-quality qualification
and richer model-authored composition remain separate goals.

The first viewport should show the user's subject, a useful answer, and the main interactive object. Use a conversation rail when needed rather than forcing the object below an accumulating chat transcript.

Proposed wide composition:

```text
┌ Workspace title                         Saved · Expand / Window ┐
│ Optional outline │ Main canvas                    │ Inspector  │
│                  │ Title + brief orientation      │ contextual │
│                  │                                │ details    │
│                  │ Diagram / gallery / mini-app   │            │
│                  │                                │            │
│                  │ Relevant next action           │            │
├──────────────────┴────────────────────────────────┴────────────┤
│ Selected: Earth's axis ×     Ask about this / revise this…  ↑  │
└────────────────────────────────────────────────────────────────┘
```

- Keep the outline and inspector absent until they serve an actual task. Narrow layouts move them into accessible drawers.
- Use a prominent subject title, compact orientation text, and clear labels at the point of interaction.
- Give diagrams and meaningful photography enough space to explain something.
- Avoid making every paragraph a bordered card. Group content through alignment, spacing, and typographic hierarchy.
- Inherit Omarchy foreground/background/accent and the launcher's matte surface. Use additional semantic colors only where the subject needs distinctions; pair color with labels or patterns.
- Follow the existing translucency preference. Dense reading and diagram areas need locally sufficient contrast.
- Use restrained, interruptible transitions to explain expansion, selection, and revision. Reserve space for late-loading media so controls do not move under the pointer.
- Freeze the viewport anchor while a user is reading or manipulating something. New content should not pull focus or force scrolling.
- Reduced-motion mode uses immediate state changes or simple fades with identical functionality.

Acceptance:

- Validate compact, expanded, and normal-window layouts at 100%, 150%, and 200% scaling where supported.
- At a narrow window width, the task remains usable through structural rearrangement rather than shrunken controls.
- Keyboard focus, selected state, active parameter, loading state, and errors remain distinguishable across representative light and dark themes.

### 2.5 Learning: explanations you can act on

**Story:** As a learner, I want to manipulate a concept and receive relevant feedback so that I understand why it works.

The learning loop is:

1. Give a direct explanation and one revealing visual.
2. Invite an action: adjust, predict, sort, identify, or step through.
3. Show the consequence immediately where the behavior is locally computable.
4. Explain the observed result, including a specific misconception when relevant.
5. Offer a transfer example or next question.

Core learning components:

- Annotated diagrams with selectable parts and relationships.
- Step-through processes with previous/next and an overview of the current stage.
- Parameter controls coupled to visual changes and readouts.
- Prediction/reveal interactions with a clear explanation after commitment.
- Short checks: single/multiple choice, ordering, matching, and numeric entry with tolerance where appropriate.
- Worked examples with revealable steps and inspectable intermediate values.
- Optional “Simpler,” “More depth,” “Another example,” and “Check my understanding” transformations.
- A lightweight learning trail recording topics, examples, checks, and where to resume. Avoid equating time spent or a single correct answer with mastery.

Flagship: **“Why do seasons happen?”**

- Start with an orbit diagram, Earth tilt, selected month, and selected hemisphere.
- Scrub the month using either a drag gesture or a labelled slider.
- Switch hemisphere and observe the corresponding season and daylight explanation.
- Toggle a sunlight-angle view to inspect the mechanism.
- Predict the other hemisphere's season, then receive feedback.
- Ask about the selected axis and get a local explanation without replacing the diagram.
- Save and return with the month, selected element, and lesson position intact.

Scientific fidelity is part of the interaction design: label schematic geometry and simplified assumptions. A responsive illustration must not teach an incorrect causal model.

Acceptance:

- The flagship includes at least three useful local interactions and one transfer check.
- All drag actions have keyboard and labelled-input equivalents.
- Changing explanation depth preserves simulation state and the selected subject.
- A wrong answer produces specific explanatory feedback and a meaningful retry, not only a red indicator.
- Simple questions can remain short; the system does not turn every factual answer into a lesson.

### 2.6 Exploration: images, relationships, and discovery

**Story:** As an explorer, I want multiple relevant ways to look at a subject so I can notice differences and follow my curiosity.

Core exploration components:

- Image collections arranged around a purpose: overall appearance, detail, variant, historical change, or contrasting example.
- Hotspots and labelled regions that connect an image to explanations.
- Side-by-side comparisons and before/after controls where the images are genuinely comparable.
- Timelines with inspectable events and a readable list alternative.
- Relationship diagrams with a small initial neighborhood and deliberate expansion.
- Geographic views for location-dependent questions, introduced once a map/data integration is chosen.
- A visible exploration trail with back/forward, branching, and saved discoveries.

Flagship: **“Help me recognise Gothic, Romanesque, and Renaissance architecture.”**

- Show a small number of well-chosen, labelled photographs rather than a generic hero image.
- Select an arch, window, or facade feature to inspect it.
- Compare two styles using coordinated images and concise distinguishing details.
- Replace one example with a different building without resetting the comparison.
- Try identifying an unfamiliar example, then inspect the relevant visual cues.
- Save a comparison or branch into a specific building while preserving the original trail.

Image experience:

- Every image has a role and an explicit relationship to the explanation.
- Offer **Other views**, **Show detail**, and **Replace example** when the available assets support them.
- Use a viewer with zoom/pan, captions, credits, and keyboard navigation.
- Distinguish a photograph, schematic, generated illustration, and transformed source image in the information available to the user.
- Use native/text labels for technical diagrams rather than relying on generated image lettering.
- Continue rendering the explanation if one image fails; retry or replace that asset independently.

Acceptance:

- At least three relevant visual interactions work without a new prompt.
- Replacement maintains the image's semantic role and does not silently swap to an unrelated subject.
- A selected visual feature can become the target of a follow-up question.
- Every retrieved image retains source and attribution; annotations have readable text equivalents.

### 2.7 Mini-apps: useful tools created in context

**Story:** As a maker, I want the AI to produce a working tool from my request or data so I can use and revise it instead of repeatedly asking for recalculations.

Initial mini-app families:

| Family | Inputs | Local behavior | Saved result |
| --- | --- | --- | --- |
| Decision workbench | Options, criteria, priorities | Filter, weight, compare, expose contributions | Comparison and rationale |
| Scenario calculator | Values, ranges, assumptions | Recalculate outputs and charts | Named scenarios |
| Data explorer | CSV or pasted table | Sort, filter, select columns, change chart | Dataset and view configuration |
| Plan builder | Constraints, steps, dates | Reorder, edit, check completion | Editable plan |
| Learning tool | Topic, examples, controls | Simulate, reveal, check, repeat | Resumable activity |

Flagship: **“Compare these three laptops for coding, travel, and occasional gaming.”**

- Build a comparison from supplied links/specifications and clearly sourced additional data.
- Let the user change priorities and inspect why rankings change.
- Keep unknown specifications visibly unknown; distinguish factual values from subjective ratings.
- Allow editing a value, excluding an option, and adding another candidate.
- Explain the selected tradeoff using the actual current inputs.
- Save the comparison as a named tool and reopen it from launcher search.

For weighted decisions, expose the scoring method and normalization. Model-selected default ratings are editable assumptions, not measured facts.

Acceptance:

- Input changes recalculate supported outputs locally and can be undone.
- The AI receives current tool state when asked to explain or revise the result.
- A revision preserves compatible user inputs and names any affected assumptions.
- Tools can be renamed, duplicated, exported, and reopened after a shell restart.
- CSV import includes a preview with column/type correction and understandable parse errors.

### 2.8 Conversation as targeted editing

**Story:** As a user, I want to ask about or change the thing I am looking at without losing it.

- Selecting an object creates a visible composer target, such as `Selected: sunlight angle` or `Selected: laptop comparison`.
- Contextual actions use verbs: Explain, Compare, Show another example, Adjust, Turn into a tool, Add a check.
- Choose at most three relevant next actions based on the current object and state. Avoid a permanent wall of generic suggestion chips.
- A follow-up may answer locally, patch the current artifact, add an artifact, or create a branch. Represent those outcomes clearly.
- Keep conversation history available in a collapsible rail or panel with the prompts that caused revisions.
- Local state changes and AI revisions have a navigable undo/history model.
- Before a structural revision, retain a recoverable checkpoint. Never erase user-entered values merely because a component was regenerated.
- While a request runs, keep the draft editable and existing local controls usable. Offer Stop and retry at the affected task or object.

Acceptance:

- “Make it simpler” preserves the selected example and current parameter values.
- “Compare with X” can extend the comparison rather than create a separate unrelated answer.
- A response targeting an older revision does not overwrite newer edits.
- Undo restores both visible content and associated inputs; redo behaves predictably after new edits.

### 2.9 Persistence, library, and return journeys

**Story:** As a returning user, I want to recover a useful workspace without reconstructing its context.

- Autosave draft, artifacts, interaction state, sources, conversation references, and revisions locally.
- Maintain **Recent workspaces**, named/pinned workspaces, and a lightweight searchable library.
- Search saved workspace titles and explicit descriptions from the launcher. Keep matches visually distinct from apps and files.
- Resume the last active workspace from the AI entry surface while keeping New workspace readily available.
- Save reading position and selection per view where useful; persist actual activity state independently of the view.
- Include assets needed for meaningful cached reopening, with a visible result when an asset has expired or needs refreshing.
- Support Markdown/text export, CSV for tabular data, and a versioned workspace bundle for restoring interactive state. Add print/PDF after the content layouts are stable.
- Workspace deletion removes its owned saved state; shared media is reclaimed when no saved workspace references it.
- If an agent session can no longer be resumed, rebuild the next request from the saved workspace and a bounded summary rather than making the saved tool unusable.

Acceptance:

- Restart restores a workspace with its draft, controls, notes, learning step, and sources intact.
- Cached local tools remain usable without connectivity; unavailable model or remote-data actions explain what needs a connection.
- Exported tabular data matches the current view/selection chosen by the user.
- Searching a saved tool focuses or opens the correct workspace, rather than creating a duplicate.

### 2.10 Common experience states and accessibility

Design these states as part of every component, not as a final styling pass:

- Empty and ready; first useful content; partial content with assets pending.
- Hover, focus, selected, pressed, editing, and disabled with a reason.
- Remote data loading, no results, stale data, retryable error, and stopped generation.
- Local save pending, saved, save failed, interrupted session, and restored session.
- Narrow layout, large text, reduced motion, missing images, and keyboard-only use.

Every interactive component needs accessible names, roles, values, and a predictable focus order. Charts expose values in text/table form; diagrams expose labelled entities and relationships; generated tools reuse these semantics. Do not rely on hover or color alone.

### 2.11 Scope boundaries

The full direction includes all three pillars and persistent workspaces. The first complete release targets the flagship journeys plus a reusable foundation, rather than claiming arbitrary subject-specific simulations already work.

Deferred beyond that release: multi-user collaboration, cloud account/sync, public tool marketplace, and general autonomous desktop operation. Audio narration, voice input, and richer 3D can follow when they serve validated learning or task needs.

## 3. AI System Requirements

### 3.1 The current baseline

Working-tree baseline updated 2026-10-25. OpenUI additions are not live-installed;
the older native capabilities were reconciled with the installed tree on October
22. This table is not a new live verification or resource profile.

| Area | Current implementation | Planned evolution |
| --- | --- | --- |
| Entry | Canonical `ai:`, Ask AI search result, multiline composer implemented | Retain behavior during efficiency refactoring |
| Presentation | Existing answer envelope/blocks; Codex OpenUI profile additionally allows one bounded DSL tool rendered as a native tree | General revision-aware presentation patches |
| Composition | Native task-first layouts; OpenUI-authored layouts/controls/SVG through QML adapters; existing editorial image layout retained | Broader real-content visual-quality evaluation |
| Images | Wikimedia single images and captioned galleries; local candidates and fitted zoom/pan viewer | Richer role-driven retrieval, annotations, generated illustrations |
| Controls | Learning blocks, local table sort/filter, typed calc inputs/editable data/scenarios/undo, forms, action buttons, comparison and timeline blocks, adaptive prose depth sidecars | General state transitions, plan editing and targeted revision actions |
| State context | Bounded latest-answer/calc and form/choice/focus context; OpenUI follow-ups additionally carry latest completed tool code/state (48 KiB total / 12 KiB state); depth is separate | Revision-aware artifact patches, not merely new answers |
| Suggestions | Contextual chips fill the composer without sending; selected-part targets accompany the next explicit question | Broader contextual action model |
| Lifecycle | Lazy restore implemented (metadata-only boot; hydrate once on real AI entry); one lazy `--serve` store worker per session (one connection across a burst, strictly ordered results, idle/EOF exit); coalesced dirty-field saves (workspace row on every save, full content only when a content change raised `dirtyContent`) | Remaining lifecycle refactors |
| Agents | New Codex chats default to OpenUI; legacy workspaces/Hermes retain native generation; Codex hosted lookup and Hermes's no-tool boundary are unchanged | Explicit adapter capability negotiation |
| OpenUI runtime | One lazy retained service controller, credential-free guardian/Node core evaluator, native QML presentation; explicit historical-tool selection | Live lifecycle/resource qualification; broader arbitrary-code artifacts remain separate |
| Window | Connected Peek/Explore panel and detached normal workspace window | Remaining lifecycle, focus and multi-scale qualification |

### 3.2 Response planning and presentation contracts

The agent should decide whether a request needs a brief answer, explanation, exploration, mini-app, or update to an existing artifact. This is a presentation decision, not a compulsory user-facing mode picker.

Use an internal response contract containing:

- A concise direct answer and a proper display title.
- The target workspace/artifact and base revision, if modifying existing content.
- A composition made from supported components, with stable IDs.
- Initial state and declared bindings between inputs, computed values, and views.
- Asset requests describing subject, role, view, and relevance requirements.
- Source references and data provenance attached to the relevant claims or values.
- Contextual actions with declared intent and expected target.
- A plain-text representation for copy/export and degraded rendering.

Keep this planning inside one model request when practical. Introduce a separate planner call only if evaluation demonstrates a quality improvement worth its extra latency.

The prompt should encourage medium selection and useful interaction rather than universally prescribing a tiny answer with one or two blocks. Greetings and simple facts remain compact.

### 3.3 Interaction event model

Three event classes make the experience predictable:

1. **Local UI events:** selection, reveal, navigation, expansion, checklist state. No model request.
2. **Local computed events:** slider changes, scoring, filters, unit conversions, supported simulation updates. Execute in the local runtime; no model request.
3. **Semantic events:** explain a selection, generate another example, assess an open response, revise a tool. Make a bounded agent request with relevant state.

Do not send a model request for every pointer movement. Commit/debounce state for persistence, and invoke reasoning only when the action needs it.

Each semantic request includes the selected object, current relevant inputs, recent committed interactions, artifact revision, source references, and a bounded conversation summary. The system must distinguish facts, user inputs, model assumptions, and computed outputs.

### 3.4 Three levels of generated UI

**Owner integration constraint (2026-10-24):** intelligent UI is part of the
existing native launcher, NOT a separate app/manual-preview workflow. Preserve
the native composer, submission/Stop, turns, workspace identities and save
ownership. Only the answer/tool region changes. The standalone page is an
internal development harness and must not be presented as delivered integration.

**Native implementation (2026-10-25; working tree only):** `AiService.qml` owns
one retained `AiOpenUiRuntime.qml`; `AiAnswer`/`AiBlocks` mount disposable native
`AiOpenUiSurface`/`View`/`Node`/`Svg` adapters in the existing answer region.
`ai_openui_runtime.py` supervises the bundled actual `@openuidev/lang-core`
evaluator. No WebEngine, browser runtime, React runtime or DSL evaluation enters
Qt. Existing composer, submission/Stop, turns, artifacts, typed `calc` validation
and SQLite ownership remain native; generic OpenUI math does not inherit the
typed calculation engine's units/provenance guarantees.

- New Codex conversations automatically select `responseMode: "openui"` and may
  author one `openui` block (`title`, bounded `code`) alongside existing blocks.
  Restored legacy workspaces default to `native`; Hermes stays native. Mode is
  persisted, not silently switched within an existing conversation.
- Only one runtime/tool is selected. The latest eligible tool opens by default;
  an earlier tool needs explicit **Use this tool**. Workspace/turn/block/code
  mount identities and request tokens reject stale replies; state echoes do not
  remount/reset live controls. Semantic SHA-256 event handles reject queued
  action/input retargets even when a structural node path is reused; action
  handles include the authored action AST so late-bound Copy payloads stay one
  action across edits without sharing a handle with a replacement Copy.
- Canonical acknowledged state uses
  `uiStates[turnId]["openui:<originalBlockIndex>"]` in the existing save path.
  Transition/snapshot gates wait for runtime acknowledgements; a pending restore
  is deferred until drained. Duplicate retains OpenUI state opaquely, without
  rewriting strings that resemble artifact IDs. Hidden views do not own workers;
  the retained controller finishes queued work and retires its guardian/Node
  after the hidden idle grace (30 s), with canonical state available to reload.
- The credential-free guardian starts permission-limited Node >=24 (actual 26),
  readable bundle only, with a 96 MiB old-space cap and external 3-second
  per-request watchdog. Language/AST/action allowlists, 32 KiB programs, 64 KiB
  state, 512 KiB frames, bounded queues and 512-node/64-depth trees are enforced.
  There is no arbitrary HTML/JS, provider/host execution bridge, Query/Mutation,
  external-media fetch or telemetry in this runtime. Node permissions supplement
  the language restrictions; the heap flag is not a total-process memory budget.
- Follow-ups send the latest completed tool's code plus saved state, bounded to
  48 KiB total JSON and 12 KiB state. Unsupported/oversized context is refused,
  never silently truncated/reset. Cold OpenUI brokers do not adopt untagged saved
  provider sessions; this bounded context is not transcript reconstruction,
  full conversation branching or an in-place artifact patch.
- `openui/` contains build source, lockfile, upstream provenance and MIT notices.
  `python3 -B tests/build_openui.py --check` uses scratch
  `npm ci --ignore-scripts`, build/tests and byte-identical asset comparisons;
  only explicit `--write` updates generated assets. `tests/run_offline.py` uses
  private scratch HOME/XDG for all suites, including native runtime/service checks.

Final scratch/offscreen verification (2026-10-26): **21 worker tests**, **649
Python tests (2 skipped)**, **1,799 main QtTests**, 29 blocks / 23 visual /
12 answer / 6 task-visual, all ten isolated checks, byte-identical generated
assets and a passing audit. Action handles include a fingerprint of the authored
action AST, so a queued Copy survives an ordinary edit but a stale conditional
Copy cannot execute its replacement; that path has a worker regression. An
isolated native QML + guardian/Node run measured **204.32 MiB PSS** across three
processes and left zero owned processes after teardown (helper-only 80.58 MiB;
event p95 1.8 ms), but this is scratch instrumentation, not live-shell resource
cost. One real Codex garden tool generated through the production broker
in 27.58 s was replayed as exact DSL through native `AiService`/`AiAnswer` at
420/980px: 72 initial positions/SVG dots, then 48 at 3.6 m length / 30 cm spacing.
Screenshots `opaque-garden-420.png` and `opaque-garden-edited-980.png` under
`/tmp/opencode/native-openui-visual-qsgbpwid/` were read and inspected; item alpha
was composited over the actual `#202124` Window colour. Raw model output stays
outside the repository. This is one sample/offscreen replay, not a reliability
benchmark or live Wayland/mixed-DPR/resource qualification. No live
installed-plugin deployment, shell restart, version bump or
user-workspace mutation was performed.

**Historical browser-host investigation (2026-10-24; superseded for native
integration):** `launcher/embedded.tsx` in the fork extracted only the renderer/
library, with snapshot/state/copy/height/Escape messages and no second composer,
provider, history or store. Nine browser checks included one mocked Qt-host
round trip; a native browser host/save lifecycle was not built at that checkpoint.

Browser-host qualification found a separate blocker: loading `WebEngineView`
in a scratch-only Quickshell config crashed with `Argument list is empty ...
QCoreApplication`. Log:
`/tmp/opencode/native-openui-engine-28145hly/check.log`. The live shell was not
used. Installed Quickshell's startup lacks Qt WebEngine Quick's documented early
initialization, and the exact fatal is its hard-coded Qt `argc = 0`, confirmed in
matching `launch.cpp`. No supported CLI/pragma workaround was found. Do not
hot-load the browser into the actual launcher or change the shell binary/startup
without separate owner approval. The native QML/core alternative above avoids
this browser-host dependency. The standalone browser's cost is NOT an embedded-
or native-runtime measurement.

**Historical decision and working prototype (2026-10-24):** the owner authorised
proceeding after the comparison. Use [OpenUI core](https://github.com/thesysdev/openui)
(`lang-core` + `react-lang`) as the framework and reuse the Thesys demo's
components/functions. CopilotKit's reviewed app
(`8391a94c1c3939c679e40ddd7bfc08a9ef690e70`) remains a free-form HTML/canvas/3D
reference, not the first integration: its current app also requires a Jev
presentation router plus the answer model and a larger backend stack. This is
an integration-fit decision, not an independent visual-quality/latency benchmark.
OpenUI's main repository (reviewed `9d73d17d2bbac565672a85e78f6eb7740cb0d9ca`)
is the underlying framework, not a third competing demo. Its maintained
FastAPI/design-system/native examples do not remove the QML integration work.

Prototype: `~/Work/launcher-openui/launcher/`, based on Thesys demo
`03213439358bf3408ad61a46ec9e3230c5572e48`, npm-locked core/runtime **1.0.0**.
Static esbuild assets, actual upstream renderer/components/functions, bounded
local state and a matching 31,442-byte system prompt; no Next.js server, Cloud
account or new keys. Stdlib loopback server reuses the audited Codex isolation
helpers with native JSON instructions/schema deliberately replaced. Browser
never receives credentials or provider/host execution tools. Exclude arbitrary
HTML, network media/maps, Query/Mutation and telemetry; CSP blocks remote loads.
An explicit Chromium app owns a temporary profile and one desktop lock; nothing
starts in ordinary launcher/AI use. Desktop behavior is not live-qualified.

Reuse `ai_workspace_store.py`'s private transactional implementation under a
SEPARATE `<launcher-state>/rich/workspace.db`, never the native DB. Save complete
program/state with optimistic revision checks, serialised/coalesced writes,
visible failures and a flush barrier before navigation. An older acknowledgement
must not label newer debounced edits saved or rehydrate the controls. New AI
revisions retain the previous tool. No retention/pruning/deletion. The native
validated calculation engine remains authoritative for its supported use cases;
generic OpenUI math does not inherit that validation/provenance guarantee.

Checks: **336 Vitest, 30 Python backend, 8 Playwright**, types/static build. Browser
checks use real SQLite in scratch state, local controls/keyboard/reload at
420/1280px, failed/delayed saves, invalid output and cancellation. Three synthetic
real Codex generations (meal scaler, garden plan, bicycle gearing) all parsed;
~15/28/30 seconds, one sample each. Exact outputs replayed through the UI passed
local interactions, with no page errors/external browser requests. Not a broad
provider-quality or source/claim verification benchmark. No user workspace writes.
Review subagents hit quota, so independent review remains outstanding.

**Browser candidate rejected for native replacement at this checkpoint:** a
headless reference measured 435–437 MiB aggregate PSS (browser/GPU subprocesses + Python, ten processes),
above the 256 MiB optional-runtime allowance. GPU-off variants were no better;
cleanup left zero owned processes. 51ms server readiness / 411ms first useful
fixture and 1.5% one-core CPU over four early seconds are short headless
observations, NOT settled CPU/Wayland/DPR or 50-cycle qualification. Reports:
`/tmp/opencode/openui-resource-ht7cE4/report.json` and
`/tmp/opencode/openui-renderer-cost-b2Nm74/report.json`. Generated-output replay
screenshots/report: `/tmp/opencode/openui-generated-ui-q9a0vj/`; real programs
under `/tmp/opencode/openui-live-mh4yxqpr/` and `openui-live-qbw6addk/`.
These scratch artifacts are ephemeral. This motivated the lighter native-QML/core
implementation above, whose resource qualification remains separate. At that
checkpoint Qt WebEngine Quick development libs were installed, CMake
was absent. No native deletion, installed-renderer change, shortcut, release,
version bump, canonical sync, commit or push. The native fallback stays intact.

**Historical reuse candidate supplied by the owner (2026-10-23):**
[Open Intelligent UI](https://github.com/thesysdev/open-intelligent-ui) and
[OpenUI](https://github.com/thesysdev/openui) are MIT-licensed. Source review
confirmed model-authored layout trees, shared reactive variables, local actions,
a streaming parser/runtime, component-library-driven prompts and worked tools.
This is a stronger composition foundation than adding more fixed blocks.
The ready-made components are React/web, not drop-in QML; `lang-core` is
framework-agnostic but a native renderer/bridge would still require porting work.

Recommended evaluation, not an approved migration: reuse their actual renderer
and component/function library in an isolated, explicitly opened rich workspace,
preserving the native launcher, existing provider adapters and durable SQLite
workspaces. Compare a meal scaler, a linked travel plan and an interactive
learning tool against the current native path, including state restore, keyboard
access, first useful rendering, memory and complete idle unloading. A static
browser bundle exists, so the whole Next.js chat/server need not become our base.
Cloud is optional: upstream also supports direct compatible APIs and Ollama;
Cloud-only output correction must not be assumed on those paths. Our Codex CLI
does not become progressively streaming merely by changing renderers.

Keep arbitrary `HtmlView` scripts, demo telemetry, unrestricted external asset
fetching and broad host/tool bridges disabled for an initial spike. Preserve
license notices and independently review dependency/runtime limits, provenance
and numerical behavior before adoption. No packages were installed, upstream
code imported, provider calls made or renderer swapped during this source review;
upstream gallery programs are hand-written examples, not proof of live model
quality. The browser lifecycle/resource gates below still apply.

**Level 1: composed native interfaces**

The model composes a curated library of native primitives: text, layouts, images, hotspots, comparisons, diagrams, timelines, forms, charts, quizzes, and controls. This supports a broad range of custom interfaces with consistent appearance and keyboard behavior.

**Level 2: declarative mini-apps**

The model declares state, dependencies, formulas, and event transitions. A typed expression/operation runtime evaluates computations, validates units/types, detects cycles, and applies resource limits. Implement mathematical and statistical operations deliberately rather than using arbitrary `eval`.

**Level 3: programmable interactive artifacts**

For bespoke visualizations and simulations that exceed the native vocabulary, support generated programs in an isolated artifact runtime with a narrow host bridge. This is a planned capability, not merely a future idea, but it requires a separate architecture milestone.

- Prototype an out-of-process web/canvas renderer as a candidate; assess Qt WebEngine packaging/integration and an external renderer approach on the installed stack.
- Keep the native workspace responsible for input context, persistence, sources, history, and window behavior.
- Expose explicit bridge operations for state, events, assets, and exports rather than direct access to shell internals.
- Version generated code alongside state. Provide reset, previous working revision, runtime error reporting, and a bounded repair attempt.
- Pause inactive artifacts and stop unresponsive execution without taking down the desktop shell. Snapshot and unload the runtime after the hidden grace period; pausing alone does not reclaim its memory.
- Require an accessible control/text representation for important functions, even when the main view is canvas-based.

Levels 1 and 2 should cover normal requests efficiently; Level 3 supplies the longer-term creative range. The implementation sequence includes all three, but Level 3 integration must pass its separate resource gate. No browser runtime may be preloaded by the shell or loaded merely by opening AI mode. If browser candidates exceed the budget, pursue a lighter isolated runtime with native presentation primitives before shipping that capability; do not compensate by making the ordinary launcher heavier.

### 3.5 Tool and data requirements

| Capability | Existing starting point | Planned need |
| --- | --- | --- |
| Reasoning and generation | Codex/Hermes adapters | Structured artifacts, patches, repair, state-aware follow-ups |
| Current information | Codex hosted web search | Source-linked extraction and adapter-aware availability |
| Photos and reference images | Wikipedia/Wikimedia resolver | Multi-candidate retrieval, relevance selection, alternative views |
| Generated illustration | None | Provider adapter, asynchronous jobs, labelled outputs, cached results |
| Diagrams | Native scene primitives, selectable labels and slider coupling | Richer semantic scenes and grounded image hotspots |
| Charts and market data | Existing chart/market resolver | Direct controls, tabular alternative, dataset bindings |
| Files | One bounded text attachment | Attachment collection, CSV first, then PDF/image ingestion with adapter capability checks |
| CSV sampling/data | Bounded provider prefix snapshot, local preview/type correction, durable kept source, paged explorer and exact supported statistics | Remaining delivery/resource qualification and broader dataset bindings |
| Geographic exploration | None | Map renderer/data provider selection during its milestone |
| Tool execution | Bounded native typed computation, editable data/scenarios/local undo; restricted OpenUI core DSL with native QML presentation | Revision reconciliation, runtime qualification and broader arbitrary-code artifacts |

A provider-specific feature must be discoverable through capabilities; do not silently imply that an adapter supports image understanding, structured updates, or web lookup when it does not. Keep existing agent sessions pinned, and provide an explicit path when a requested capability needs another adapter.

### 3.6 Visual asset pipeline

1. Determine the visual's explanatory role: recognition, detail, comparison, location, mechanism, or atmosphere.
2. Choose the appropriate medium: retrieved photo, native diagram/chart, or generated illustration.
3. Retrieve several candidates where applicable; rank subject match, required view, resolution, and available attribution. Start with richer Wikimedia queries, then evaluate additional providers for genuine coverage gaps.
4. Attach semantic metadata and cache the selected asset through the app-owned resolver.
5. Render a stable placeholder and stream the asset into its reserved location.
6. Offer alternatives and independent retry/replacement without regenerating the whole answer.

Annotation coordinates must use an explicit image coordinate space and account for crop/orientation. If precise grounding is unavailable, use an unannotated image or a labelled schematic rather than invented hotspots.

Generated illustration is useful for hypothetical scenes, conceptual contrasts, and personalised examples. Technical labels, numerical relationships, and simulation behavior should remain native/computed where precision matters.

### 3.7 Evaluation strategy

Create a versioned 30-prompt benchmark: eight learning, eight exploration, eight mini-app, and six simple/mixed/failure-recovery prompts. Include the three flagship journeys, ambiguous requests, narrow layouts, missing data, and unsupported adapter capabilities.

Score each result on:

- Direct answer quality and factual/source consistency.
- Appropriateness of the chosen medium and composition.
- Whether the interactions help the actual task or concept.
- Correctness of local computation and explanatory feedback.
- Preservation of user state across follow-ups and revisions.
- Keyboard usability, readable labels, and fallback quality.
- Time to useful content, local responsiveness, and model/media usage.

Use deterministic fixtures for renderer/state/transport tests and separate live-agent evaluations for quality. Require every flagship acceptance scenario to pass; a strong aggregate score must not conceal a broken core journey.

For learning, test explanations against known misconceptions and independent expected outcomes. For calculations, use known datasets and boundary cases. For visual selection, inspect actual retrieved images, not only their captions.

## 4. Technical Specifications

### 4.1 Target architecture

```text
Launcher query / workspace composer / object interaction
                  │
           Intent + context controller
                  │
     Lightweight workspace controller ─── Durable store + revisions + assets
          │                │
          │          Agent broker + capability adapters
          │                │
          │          Structured answer / artifact / patch
          │                │
          └──── Presentation validation + reconciliation
                           │
        Native component runtime + local computation
                           │
       Peek / Explore / normal Workspace window
                           │
          Optional isolated programmable artifact host
```

Media/data resolution runs asynchronously beside the artifact pipeline. Source data and resolved assets update their owning object without replacing unrelated UI. The controller retains lightweight identities/status; Python helpers and renderers are demand-started, bounded, and idle-exiting. The diagram describes logical responsibilities, not an always-running process per box.

### 4.2 State and persistence model

Proposed entities:

| Entity | Main fields |
| --- | --- |
| Workspace | ID, schema version, title, timestamps, agent/session reference, summary, active artifact, draft |
| Artifact | ID, kind, presentation version, root node, bindings, source references, active revision |
| Node | Stable ID, component type, typed properties, child IDs, state bindings, action bindings |
| Interaction state | Workspace/artifact/node IDs, input values, selections, lesson progress, local notes |
| Revision | ID, parent revision, base revision, patch/checkpoint, reason, associated prompt/event |
| Asset | ID, source/generation metadata, local content reference, dimensions, attribution, freshness |
| Dataset | ID, columns/types/units, data reference, provenance, import corrections |
| Job | ID, target, generation/revision token, status, progress events, error/retry information |

Keep SQLite and the existing Python store logic. Persistence uses one lazily started, serial, line-oriented store worker (`--serve`) while a workspace is being used: retain its connection across an operation burst, answer requests strictly in order, and exit when idle (store-worker slice, 1.13.1). It is not an always-on daemon. Keep the store worker independent of provider imports so editing a draft does not start a full agent broker. Transactions cover artifact revisions and associated state; content references avoid duplicating large media. Keep a versioned export format independent of the database schema.

Default proposed state location: `$XDG_STATE_HOME/omarchy/launcher-ai/`, falling back to `~/.local/state/omarchy/launcher-ai/`. Reuse the existing root while adding an explicit storage migration/version policy.

Autosave committed interactions and debounce transient edits. Use an approximately 800 ms trailing debounce with a maximum dirty interval of 5 seconds during continued editing, plus an acknowledged flush on workspace switch/close and terminal job events. Do not block the UI thread while flushing. Retain unsaved state and an error/retry path when writes fail; do not destroy the last in-memory copy or shut down its worker before acknowledgement. After an unexpected restart, mark unfinished jobs interrupted and provide a retry/resume path rather than leaving an eternal spinner.

Send changed fields/objects instead of rewriting every turn on each draft or checkbox change; coalesced dirty-field saves landed in manifest 1.16.0 (the small workspace row on every save, the full artifacts/interaction serialization only when a content change set `dirtyContent`). Keep at most one in-flight save and one coalesced pending update for the active workspace. Preserve ordering barriers for delete, switch, and revision commits; an old save must never resurrect a deleted workspace. Streaming tokens update the visible view in batches and produce bounded recovery checkpoints, not a new persistent revision per token.

At shell startup retain only the metadata needed for entry/routing. Load transcript, artifact data, and assets on AI/workspace entry, not automatically for ordinary app search. Workspace search uses a bounded metadata index and never hydrates all matching workspaces. Query old turns/revisions on demand; library size must not determine idle RAM usage.

### 4.3 Presentation tree and reconciliation

- Replace the six-flat-block ceiling with versioned, bounded composition rules: node count, nesting depth, text size, image count, and dataset size appropriate to each surface.
- Convert existing answer blocks into initial artifact nodes through a compatibility adapter for old response formats. This does not preserve the old `:ai` entry syntax.
- Keep stable IDs independent of position, so moving a checklist item does not transfer its checked state to another item.
- Patch operations address stable IDs and a base revision: add, replace properties, remove, move, and update bindings.
- Validate a complete update before committing it; retain the last working artifact on failure.
- Reconcile in place to preserve input focus, selection, viewport position, and compatible values.
- Discard or explicitly reconcile late results targeting superseded revisions. A stopped generation cannot update a newer job.
- Merge local edits made during generation where compatible; otherwise preserve a checkpoint and show the proposed alternative without overwriting those edits.

### 4.4 Component catalogue

Build in dependency order:

1. **Foundations:** text, heading, row/column/grid, disclosure, tabs, toolbar, status, sources, selectable object frame.
2. **Inputs:** button, select, segmented choice, slider, numeric field with units, text field, checklist, editable table.
3. **Visuals:** image/viewer, image collection, hotspot layer, chart, comparison layout, timeline, diagram scene.
4. **Learning:** steps, prediction/reveal, quiz, matching/ordering, worked example, simulation controls.
5. **Tools:** dataset view, filter/sort, calculated values, scenario comparison, editable plan.
6. **Advanced:** geographic view, isolated programmable canvas/web artifact.

Each component declares its input schema, persistent state, local events, semantic actions, accessibility representation, text export, supported sizes, and error/loading behavior.

### 4.5 Existing file evolution

Rows marked implemented describe current working-tree modules, not live
deployment. Other changes below remain planned evolution.

| File | Implementation / planned evolution |
| --- | --- |
| `LauncherPanel.qml` | `ai:` entry, saved workspace results, surface transitions, focus/window handoff |
| `AiState.js` | New prefix parsing; move from turn-index UI state to workspace/artifact identity |
| `AiComposer.qml` | Multiline input, attachments, selected-object target, busy/stop behavior |
| `AiPane.qml` | Workspace host, lazy/virtualised history, contextual actions, surface-independent state; do not instantiate collapsed answers |
| `AiAnswer.qml` / `AiBlocks.qml` | Existing native renderer plus integrated OpenUI answer surface |
| `AiOpenUiRuntime.qml` / `ai_openui_runtime.py` | Implemented retained controller, bounded IPC and credential-free Node supervision; qualify live lifecycle/resource costs |
| `AiOpenUiState.js` / `AiOpenUiSurface.qml` / `AiOpenUiView.qml` / `AiOpenUiNode.qml` / `AiOpenUiSvg.qml` / `AiOpenUiNative.js` | Implemented inert state/routing and native layout/control/SVG presentation; extend only with matching restricted schema/tests |
| `openui/` | Actual core worker, adapted library/function source, generated prompt/schema, lockfile and MIT provenance; scratch reproducibility check before asset updates |
| `AiImage.qml` / `AiChart.qml` | Richer viewer/chart controls and bindings to persistent state |
| `AiService.qml` | Lightweight controller, acknowledged/coalesced saves, lazy restore, idle helper shutdown; avoid retaining duplicate full histories |
| `ai_workspace_store.py` | Preserve SQLite schema and tests; add burst-oriented worker transport, incremental updates, paged reads, and ordered flush/close |
| `ai_broker.py` / `ai_hermes.py` | Versioned artifact/patch events, state context, capability reporting, retry/cancel semantics |
| `ai_catalog.py` / `ai-answer.schema.json` | Versioned presentation contract, validation, medium-selection instructions |
| `ai_media.py` | Role-driven asset requests, candidate selection, independent jobs, durable asset references |
| `AiLayout.js` / `SatinGlass.js` | Surface/layout tokens, adaptive composition, motion/contrast rules |
| `manifest.json` | Normal-window/service integration if required by the verified shell API |
| `tests/` | State, rendering, interaction, persistence, adapter, and flagship journey coverage |
| `README.md` | Update delivered features and controls as each phase actually ships |

Likely new responsibilities include a workspace store, presentation validator/reconciler, local expression runtime, asset job manager, workspace window host, and programmable artifact host. Split by responsibility rather than enlarging the current service and pane indefinitely.

### 4.6 Integration points and lifecycle

- Reuse Omarchy theme and launcher/dock integration.
- Verify normal-window creation and retention through the installed Quickshell/plugin API before choosing whether the workspace window is hosted in the shell process or a companion process.
- Retain the existing JSON-line broker transport where suitable, but add protocol versions, request/job IDs, target revisions, and explicit cancellation completion.
- Use the demand-started store worker for persistence. Add a separate long-session job owner only if lifecycle testing requires it, with the same bounded queue and idle-exit contract; do not create a permanent background daemon per workspace.
- Existing CLI authentication remains adapter-owned; this plan does not introduce another account system.
- Keep terminal continuation available, while treating exported workspace context as the fallback when a raw provider session cannot represent the interactive artifact.
- Import attachments as explicit workspace resources with status, type, size, and removal controls. Large datasets need paging/sampling rather than sending every row to the model.

### 4.7 Security and privacy: architectural data handling

Saved workspaces and imported content are local by default. Requests include the selected context needed for the action, with visible attachments and selected-object targeting. Credentials remain with the existing agent/provider adapters rather than entering workspace exports.

Model output is validated data for native components. Programmable artifacts run outside the shell with an explicit host bridge. This separation also supports crash recovery, predictable resource use, and portable exports.

### 4.8 Performance and reliability budgets

Resource efficiency is a release gate. The numbers below are initial engineering budgets, not measured results. Record hardware, scaling, fixtures, and baseline before implementation. If a target is infeasible, first fix lifecycle/algorithm choices; any revised budget needs an explicit measured rationale in this document rather than silently relaxing it.

#### Lifecycle contract

| State | Required behavior |
| --- | --- |
| Shell start / ordinary app-file launcher use | No AI broker, media worker, programmable runtime, or full workspace restore. Metadata lookup for saved-workspace results may use a short-lived store worker only when needed. |
| AI visible, static | No recurring animation or application polling. Render only changed content. Keep only the active visible artifact and a bounded nearby view cache. |
| AI visible, interactive | Compute changed dependencies only. Run animation only while the interaction requires it; aggregate updates per frame rather than binding one timer to each object. |
| Hidden/minimised, no job | Suspend visual timers/simulations within 250 ms of a supported visibility notification. Allow a 10-second view reuse grace period, then release heavyweight views and decoded assets. Idle helper processes must exit within 30 seconds of their last needed operation after saves are acknowledged. |
| Closed, no job | Same release policy as hidden. No AI-owned helper/renderer processes after the 30-second grace period, and no periodic AI timers or network activity. |
| Hidden/closed, explicit job active | Continue that requested job and needed save operations; pause presentation and speculative work. Begin normal idle cleanup when the job finishes. |
| Multiple saved/open workspaces | Saved workspaces are data, not live runtimes. Start with one foreground compute/artifact runtime; inactive workspaces restore from snapshots. Keep multiple static windows possible without multiplying active simulations. |

Use actual window visibility/exposure/minimisation events where available. Do not infer that every unfocused window is hidden, and do not add a visibility polling loop. No continuously running housekeeping task: prune on bounded writes/worker startup when a persisted last-run timestamp shows it is due.

#### Memory, CPU, and process budgets

Memory gates use **aggregate proportional set size (PSS)**, including shell growth and all launcher-owned children. Establish an A/B baseline with the same shell/plugins/theme and ordinary launcher present but its AI workspace uninitialised. Also record whole-feature enabled/disabled deltas to expose static AI loading costs. Report RSS and peak memory separately; summing shared-library RSS is not an accurate total. These budgets do not include unrelated shell plugins.

| Scenario | Initial budget / gate |
| --- | --- |
| AI fully idle after close and cleanup | At most 20 MiB retained incremental PSS over the uninitialised AI baseline; zero surviving AI helper/runtime processes |
| Static native answer, no provider running | At most 96 MiB incremental aggregate PSS for the reference answer with two images |
| Active native learning/tool workspace | At most 192 MiB incremental aggregate PSS for the flagship fixtures, including its store/helper processes |
| Optional programmable artifact | At most 256 MiB additional aggregate PSS beyond its native host for the reference artifact, including renderer/GPU subprocesses; at most one active artifact runtime initially |
| Settled idle CPU, closed or static | Below 0.1% of one logical core averaged over a 60-second sample, attributable to this feature; no feature-owned periodic wakeup source or continuous GPU rendering |
| Active work concurrency | One agent request, one store operation, and up to two media fetches globally initially; one image decode at a time; one foreground simulation/runtime. Queue other work and prioritise visible requests. |

Provider CLIs have their own substantial and variable footprint: record their complete process-tree PSS/CPU/peaks separately **and in the total observed footprint**. Native UI budgets must not hide provider cost. They may run only for requested jobs and must exit afterward; they must not remain as prewarmed idle agents. Establish a job-specific total peak envelope from the measured Codex/Hermes fixtures in the first qualification milestone before adding concurrency.

Memory ceilings are release checks and backpressure/eviction triggers, not instructions to kill the shared desktop shell. Isolated artifact resource limits may terminate that artifact and restore its last saved state. Store failures or memory pressure must preserve unacknowledged edits.

#### Rendering, data, and storage rules

- `visible: false` is not resource unloading. Use lazy `Loader` creation or virtualised delegates for collapsed history and offscreen heavy artifacts, with correct destruction/focus handling. Maintain the live image lifetime rules in `AGENTS.md`.
- Keep one authoritative bounded data model; avoid full transcript copies across arrays, `ListModel` payloads, queued snapshots, and rendered delegates. Old turns remain queryable on disk.
- Decode images near the displayed size at the current DPR; request a larger version only for zoom/details. Initially cap the app-managed decoded image cache at 32 MiB for Peek and 64 MiB for expanded/native Workspace. Include GPU textures in profiling and avoid duplicate decodes for equal size requests.
- Cap reusable fetched media at 64 MiB initially, growing the current 32 MiB cache only when the new galleries need it. Saved workspace assets are separately accounted durable data, deduplicated by content; pinned/saved content is not silently deleted to satisfy a cache cap.
- Page datasets and downsample chart rendering to the pixel budget while preserving full source data on disk. Reference stress fixture: 100,000 numeric rows and 20 columns, never instantiated as 2 million QML cells.
- Start with a 16 MiB combined queued-IPC payload cap and per-message bounds; transfer large assets/datasets by validated local references, not base64 copies through QML/JSON. Backpressure queues instead of growing them indefinitely.
- Batch streamed presentation updates to at most 20 per second with immediate terminal/error events. Dependency-driven local controls may render at the display frame rate. Do not repeatedly parse or serialise the entire workspace for a token or slider event.
- No database writes while settled idle. Debounce edits, acknowledge commits, and avoid per-keystroke schema checks, connection creation, and whole-history writes. Schedule WAL checkpointing based on size/transaction count rather than each input event.
- Track database, WAL, revisions, assets, provider-session files, and logs separately. Keep diagnostic logs within 10 MiB and recoverable revision overhead within 32 MiB per workspace initially, compacting into checkpoints without discarding the current artifact or named checkpoints. Retention policy for saved work is separate from transient-cache eviction.
- Use no busy waits. Replace fixed-interval child-process polling with OS/async process-exit notifications while preserving cancellation and descendant cleanup.

#### Responsiveness and reliability

- Local controls: p95 event-to-visible-response below 100 ms.
- Warm workspace opening: p95 below 300 ms; cached cold opening below 1 second for a typical workspace.
- These targets apply with the lifecycle policy enabled. Do not meet warm-opening targets by retaining a hidden browser or all historical images. Record the cold reopen after eviction independently.
- Expansion, selection, and resize: aim for display-refresh-rate animation on the target system only during transitions; static content must settle. Record frame pacing and actual outliers rather than claiming smoothness from offscreen tests.
- Busy feedback: visible within 100 ms of submission. Track provider-dependent time to first useful content separately; initial quality target is p50 below 3 seconds and p95 below 10 seconds for simple text requests, subject to measured provider behavior.
- No network or model dependency in the app/file search path.
- A failed media job, malformed response, or artifact crash must leave the rest of the workspace usable.

### 4.9 Efficiency refactoring of the partial implementation

These observations come from source inspection and identify work to measure/refactor. They do not establish current CPU or memory consumption.

| Observed implementation | Planned change and verification |
| --- | --- |
| Process-per-operation store CLI invocations (one interpreter per save/load/prune) | Store-worker slice landed (1.13.1): one lazy `--serve` worker and connection per session across an editing burst, strictly ordered results, in-band static errors, idle/EOF exit. Coalesced dirty-field saves landed in the 1.16.0 slice (`savePayload()`: workspace row on every save, full content only when dirty; the store's upsert-only content handling preserves omitted rows). Remaining: measured A/B comparison of launches, CPU time, write amplification, and cold restoration; acknowledged close/delete ordering barriers. |
| An 800 ms debounce always serialised the complete conversation through `workspaceSnapshot()`; pending operations can accumulate | Coalesced dirty-field saves landed (1.16.0): `savePayload()` sends the small workspace row on every save and the full artifacts/interaction only when `dirtyContent` was raised by a turns/checklists/uiStates change; the workspace row stays full-row deliberately (the field set is cheap and always complete; a COALESCE attempt broke NOT NULL columns and was reverted). Verify bounded queue size under slow disk and that close/delete ordering preserves data. |
| Store connection setup executes WAL/schema setup on every CLI invocation | Initialise once per worker connection; retain schema compatibility checks on open and migrations as needed. |
| Service startup scheduled a full latest-workspace load; restored turns populated both an array and `ListModel` | Lazy hydration on AI entry landed as the first slice (1.13.0): metadata-only boot, one load on real entry, gated submit with watchdog, carry-protected draft/attachment, op-routed store responses. Remaining: bounded metadata for discovery; one authoritative active model with paged older turns. |
| `AiPane.qml` used a `Repeater` for every turn and hid earlier answers with `visible` | Collapsed-history slice landed (1.14.0): rows are Loader-gated (active for the newest turn or expanded history only), so collapsed answers are uninstantiated and released; the regression test asserts the older answer tree is absent while collapsed and returns after expanding. Remaining: measured release evidence and GPU/cache reclamation. |
| The broker starts on demand but had no service-side idle shutdown | Idle-broker slice landed (1.15.0): the persisted provider session travels with each submit (`resumeSession`, validated `[a-zA-Z0-9_-]{1,128}`; a warm broker ignores it), and `AiService.qml` retires the broker via `broker.running = false` once it is started, not busy/stopping, every AI surface hidden, and 30 s since the last activity; the next submit cold-starts a fresh broker that resumes the session. Remaining: the closed-state reading is re-taken as a future item (not re-measured with the slice) and the milestone A/B baselines. |
| Agent/media supervisors polled child completion every 20 ms during a job | Event-driven-supervisor slice landed (1.14.0): the `--supervise` guardian blocks on a `threading.Event` set by a reaper thread on `proc.wait()` and by the SIGTERM/SIGINT handlers, so child exit or a supervisor signal wake it once; parent-death, cancellation and descendant reaping are unchanged and regression-tested. The polling was job-scoped, not proof of idle CPU load. |
| Images currently request a fixed 960 px decode width | Profile pixel/texture allocation at actual display size and DPR; use size-aware variants/cache keys without introducing unsafe live-image layers. |

Implement these as incremental changes with before/after measurements. Preserve the already implemented `ai:` entry, composer, SQLite data, restored turns/checklists, and provider continuation. Add a real old-database fixture to verify data preservation through protocol/store changes.

### 4.10 Language and runtime decision

**Decision: keep Python for the current broker, provider adapters, media pipeline, and SQLite store. Refactor lifecycle, process churn, and data copying now. Do not perform a blanket Rust rewrite.**

Rationale:

- The inspected backend mainly orchestrates external CLIs, network requests, JSON, and SQLite. No measured CPU-heavy Python bottleneck has been established.
- SQLite and Pillow already do substantial work in native code. A Rust wrapper does not make model latency, browser-engine memory, duplicated QML objects, or excessive database writes disappear.
- A lazy worker that exits when unused removes its idle interpreter footprint. That is a more direct first fix than replacing an interpreter while preserving the inefficient lifecycle.
- Keep existing transaction, provider cancellation, media, and persistence tests and behavior instead of paying to recreate them before measuring a benefit.
- Native QML remains the presentation choice. Small bounded formula operations can stay in the existing runtime; large parsing/computation belongs off the UI thread.

**Rust is the preferred compiled backend option if a measured need remains.** Candidates are a bounded dataset/formula worker, a process supervisor, or the combined lightweight store/protocol helper. Prefer a separate executable behind the versioned IPC boundary over a custom Qt plugin unless profiling shows IPC itself is the blocker. C++ is justified only for a necessary Qt-native integration that an executable cannot provide efficiently.

Migration gate:

1. Profile the fixed lifecycle/data flow and identify the actual cost centre on reference fixtures.
2. Prototype only that bounded component in Rust, in release mode, with equivalent correctness and limits.
3. Compare process-tree PSS, CPU time, energy/wakeups where measurable, cold startup, p95 operation latency, distribution size, and maintenance/dependency cost.
4. Adopt it when it brings a failing resource/latency gate into compliance or yields a repeatable material gain: at least 30% in the targeted cost plus at least 16 MiB memory saved, 10 ms saved per latency-critical operation, or 100 ms aggregate CPU time saved per representative workflow. Percentages alone on negligible work do not justify a rewrite.
5. Preserve the SQLite/export format and use differential fixtures against the existing helper. Switch ownership once verified; do not retain both implementations as duplicate resident services.

Do not compile a new Rust executable per generated mini-app. Generated artifacts use the already-installed native/declarative runtime or the qualified isolated artifact host. Local model inference or local image generation is not enabled as an efficiency optimisation; either would need its own explicit compute/VRAM budget.

## 5. Risks & Roadmap

### 5.1 Delivery method

Deliver vertical journeys with actual interaction before broadening the catalogue. Each phase ends with a live walkthrough using real content and records what was actually verified. The full plan includes advanced programmable artifacts; sequencing protects quality without shrinking the long-term scope.

No calendar estimate is committed here. Each milestone should be estimated after its dependencies and installed-platform behavior are measured.

### Immediate milestone — qualify and refactor current resource use

This is the next step before adding richer surfaces/components. Qualification has started with a read-only sampler and initial observations; no resource-budget passes are asserted yet. Lazy restore (manifest 1.13.0), the burst-oriented store worker (manifest 1.13.1), collapsed-history unloading, and event-driven supervisor waits (manifest 1.14.0) are the first four lifecycle-refactor slices to land, and the idle-broker lifecycle (manifest 1.15.0) the fifth, and coalesced dirty-field saves (manifest 1.16.0) the sixth (above). The image refinement clears the hidden viewer source, but cache/GPU reclamation still needs measurement. Some Phase 1 features already exist; do not restart or discard that work. Phase 2 product work continues in parallel — adaptive explanation depth landed in manifest 1.17.0 (above) without changing these remainders.

Initial observations (2026-10-04, manifest 1.12.1): Omarchy 4.0.4-1, kernel 7.2.5-3-omarchy, Qt 6.11.2, Quickshell 0.3.1; Ryzen 9 9900X (24 logical cores), 31,922,104 KiB RAM, RTX 5080 (16,303 MiB VRAM); Crimson Gold theme, DP-1 3440×1440 at scale 1.25 / 179.981 Hz. Fixture: cached three-image architectural comparison `ws-02892f74f61d7ca6`. Both runs used the same shared-shell PID after the final reload, 61 samples over 60 seconds; the closed run began after the 30-second cleanup deadline. No model job was requested.

| Warm scenario | Median aggregate PSS | Peak observed aggregate PSS / RSS | Median shell-only PSS | Known aggregate CPU, one core | Launcher broker/provider/media/store counts |
| --- | --- | --- | --- | --- | --- |
| Static gallery | 638.22 MiB | 641.55 / 772.52 MiB | 620.46 MiB | 0.917% | 0 sampled |
| Closed after cleanup | 508.41 MiB | 646.90 / 821.83 MiB | 490.63 MiB | ≥1.067% (process churn) | 0 sampled |

Reports: `/tmp/opencode/resource-gallery-static-v2.json`, `/tmp/opencode/resource-gallery-closed-v2.json`; environment notes: `/tmp/opencode/resource-environment.json`. All PSS samples were readable. These are whole shared-shell/tree observations, **not incremental AI cost or gate results**; unrelated plugins/apps remain included, GPU memory is not measured, sampled peaks are not true peaks, and short-lived/reparented children may be missed. An earlier contaminated sample included Codex beneath Omarchy's agent updater; the probe now separates such `external-provider` trees from launcher broker descendants. Required next work: uninitialised-AI and enabled/disabled A/B baselines (lazy restore has landed as the first slice, 1.13.0, the store worker as the second, 1.13.1, collapsed-history unloading plus event-driven supervisor waits as the third and fourth, 1.14.0, and the idle-broker lifecycle as the fifth, 1.15.0, and coalesced dirty-field saves as the sixth, 1.16.0), then the remaining lifecycle and repeated-use qualification below.

1. Capture the resource baseline and fixtures using the measurement protocol in section 5.4.
2. Refactor lazy restore (first slice, manifest 1.13.0) and burst-oriented persistence (store-worker slice, 1.13.1); coalesced incremental saves landed as the sixth slice (manifest 1.16.0); acknowledged close/delete behavior remains.
3. Add provider-state restoration before idle broker shutdown (landed with the idle-broker slice, 1.15.0: the broker is retired once every AI surface is hidden and 30 s after the last activity, and the next submit resumes the persisted session in a fresh broker).
4. Unload remaining heavyweight hidden views (collapsed history landed in 1.14.0 with Loader-gated rows) while preserving the documented live scene-graph lifetime constraints; record measured release evidence and GPU/cache reclamation.
5. Verify the initial lifecycle/idle/static budgets and repeat-use plateau; record full process-tree cost for real agent/media jobs. The closed-state reading after the idle-broker slice is re-taken with these budget checks, not re-measured now.
6. Apply the Rust migration gate only if the measured residual cost warrants a focused prototype.

Exit: resource measurements and chosen budgets are recorded; idle cleanup, save/restore, continuation, and current entry/composer regressions pass. No claim of efficiency is based solely on a language choice or an offscreen test.

### Phase 0 — Experience design and feasibility

Deliverables:

- Capture the current live launcher baseline and confirm behavior against the README/source inspection.
- Storyboard all three flagship journeys, including first answer, three interactions, follow-up, failure, and return after restart.
- Produce visual studies for Peek, Explore, and normal Workspace using the actual theme and representative content.
- Prototype normal-window lifecycle, shared state between surfaces, keyboard focus, and mixed-DPR behavior.
- Inspect the README's unresolved image/retained-panel crash investigation and complete the relevant live lifecycle checks before building richer image interactions on that path.
- Spike a minimal presentation tree, slider-driven native diagram, transactional save/restore, and candidate programmable runtime.
- Record architectural decisions, measured latency/resource baselines against section 4.8, dependencies, and implementation estimates. The programmable runtime candidate must demonstrate bounded memory and real idle unloading before selection.

Exit: a chosen visual composition, a verified window strategy, a state/persistence contract, and an explicit feasibility decision for the programmable runtime. If the first runtime candidate fails, select and document an alternative rather than implying the capability is complete.

### Phase 1 — Entry, continuity, and workspace foundation

Deliverables:

- Replace every `:ai` entry/internal query path with `ai:`; update controls, tests, and documentation.
- Add Ask AI discovery, multiline composer, selected-context affordance, and draft preservation.
- Introduce workspace/artifact/job IDs and the versioned local store.
- Add Peek/Explore/normal-window continuity, autosave, recent workspaces, and a working restore path.
- Adapt existing blocks into artifacts and expose relevant contextual actions.
- Implement stable loading geometry, per-object errors, and revision checkpoints.

Exit: an existing-style answer can be generated, expanded, detached, closed, reopened after shell restart, and revised without losing its state. App/file launching retains baseline behavior and performance. Lifecycle/idle budgets pass with actual worker/view unloading enabled.

### Phase 2 — Interactive learning and visual exploration

Deliverables:

- Native diagram scene, hotspots, stepper, controls, prediction/reveal, and short-check components.
- Rich image collections, image viewer, semantic asset roles, alternative selection, and multi-candidate retrieval.
- State-aware follow-ups and targeted object explanations.
- Complete seasons and architectural-style flagship journeys.
- Add adaptive explanation depth, exploration trail, and resumable learning position. Adaptive-depth prose sidecars landed in manifest 1.17.0; the exploration trail landed in 1.18.1, and the resumable learning position is satisfied by the persisted interaction state (step/slider/diagram/check/predict keys restore with the workspace).

Exit: both flagship experiences satisfy their interaction, factual, keyboard, visual, and restart criteria using real model output and actual images. Native workspace, image-cache, and hidden-state budgets pass.

### Phase 3 — Declarative mini-apps and data

Current slice (audited 2026-10-22; October 9–10 additions remain unreleased,
manifest still 1.22.0): native
table sorting/filtering and saved arrangement plus bounded CSV provider-context
sampling are delivered and live-verified. The earlier isolated 100k-row sampler
check is not full dataset qualification. Preview column inference/correction and
bounded corrected-type transport are implemented, with a live correction check
on 2026-10-07; sending a corrected type to the model remains unverified live.
Durable CSV source + paged explorer + exact whole-file statistics are delivered:
a live 100k × 20 source exercised sort/filter/page, restart restoration, median
refusal and true sum/mean. The typed calculation runtime (units, dependency graph,
error values, provenance; independent Python/JS engines checked against one
322-case golden table and a 1,794-row differential fuzz) and model-authored `calc`
renderer are implemented. Live on 2026-10-08, three weight sliders, typed fields,
basis badges and computed outputs rendered; End changed a slider to hand-checked
scores and the adjustment survived a shell restart. Provenance disclosure,
typing into the numeric input field, mouse paths, narrow peek fit and mixed DPR
remain unqualified live; see `AGENTS.md` for the recorded evidence. Editable
table cells, up to three saved input scenarios with a compare view, local
undo/redo, Markdown/CSV copy and Duplicate-as-new-turn were implemented on October
9. The scoped October 10 live pass used a real Codex three-laptop block: keyboard
grid editing changed a price 1200 → 1000 and its score 54.44 → 57.78 (hand-checked),
Ctrl+Z/Y restored/reapplied it, two scenarios saved and compared, CSV copy and
local duplication worked, and a shell restart restored edits/scenarios/copy.
That is not a complete live pass of all scenario, row-edit or pointer controls.

Read-only inspection on October 22 confirms the October 10 gaps remain:
`AiCalcScenarios` opens its comparison Loader without reveal/focus, and the pane
has no PageDown handling. The CSV scenario section includes differing inputs and
scalar cells but omits the table-formula rows shown on screen; `AiState`'s
Markdown comparison also omits differing scenario inputs. The 200 KiB whole-map
saved-edit guard raises `stateNotice`, but no UI renders it. Secondary backlog: a visible
persistence-refusal notice, then comparison reveal/paging and export parity.

Dynamic UI additions (October 9–10): bounded forms and actions submit structured
follow-ups; comparison options can be pinned/hidden locally; authored-order
timelines keep completion state; “Ask about this” attaches a bounded selected-part
target to the next explicit question. Codex prompt de-duplication, phase/elapsed
feedback and content-free timing metrics are implemented, as are per-block soft
failures (invalid blocks drop with a generic warning; malformed envelopes/output
still fall back as a whole). Small live model-output checks are not live control
qualification: forms/waiting UI and dynamic-control/focus clicks remain pending,
and the missing live compare-block body/stale-QML issue is unresolved. Hermes's
progressive block compiler remains designed, not built; Codex still delivers the
whole structured answer at completion.

Reusable-tools addition: **More → Rename… / Duplicate…** offers themed keyboard
dialogs for trimmed plain single-line names (non-empty, ≤96 UTF-16 units).
`interaction.workspaceName` persists the title override through draft/full saves
and restoration, feeding detached-window titles and launcher search without
changing answer headings. Duplication creates independent workspace/artifact
identities with remapped references and one new parentless revision checkpoint
per artifact, retaining turns, checklists, UI state, adjusted calc inputs, draft
and attachment, not the original revision history. The original stays saved with
its provider session/home; the duplicate has blank provider session/handoff.
Kept CSV resources and registry ownership stay solely with the original, while
cached image references remain unchanged. This is not full AI conversation
branching: the first future provider prompt does not reconstruct copied history.
Save acknowledgements gate the backend mutation and, after cloning, the original's
edits made during the action before switching to the copy. Busy/stopping, load,
keep and pending-action gates apply; no prune is performed.
The final hydration briefly freezes outgoing controls. A failed open keeps the
original's session/handoff/source ownership, and a lost rename acknowledgement
replays its requested name rather than undoing it. Forms are tied to workspace
identity; named empty copies retain management controls.

State-aware follow-up context (2026-10-08, unreleased): every ordinary explicit
submit captures `AiState.workspaceContext` before appending the new turn — the
latest completed turn (prompt ≤512 / answer ≤1024 UTF-16 units) plus the most
recent completed `calc` block within the 20-turn window, even when older than
that turn, so a prose follow-up still sees the open calculator. The snapshot is
one ≤8 KiB UTF-8 JSON: ≤12 inputs, ≤12 outputs and ≤4 tables × ≤6 columns ×
≤6 rows with ≤12 table cells total. `AiCalcView.js` is the shared build/restore
adapter for the renderer and the snapshot, so saved input state validates
exactly as the tool renders it (invalid range/unit resets to the authored
default, never clamps), numeric values come from the typed engine with honest
error/boolean cells, and partial displays, formulas or units are withheld under
`unavailable`/`truncated` flags rather than sent. The broker validates the
closed schema before any file read, session adoption or task creation, appends
the snapshot once as fixed untrusted-data guidance, and charges its bytes once
against the conversation budget (192 KiB since October 9, superseding the
original 64 KiB limit); stale-resume retries assemble an identical prompt.
The snapshot is context, not capability: no transcript, provider-session
reconstruction, source IDs, file paths or new tool access; local edits still
make no model call; a follow-up appends a new answer and never rewrites the
original blocks; a truncated snapshot cannot justify whole-table aggregates,
overall rankings or dropped metadata; depth sidecars never carry it. General
artifact revision and full conversation branching remain undelivered.

Historical October 8 slice verification passed 418 Python tests (two skipped; existing
`ResourceWarning`s), 1,077 main QtTests, isolated service + real-store checks in scratch
HOMEs, and the detached-window check. Wide Rename / narrow Duplicate form
screenshots were read and manually inspected on mock/offscreen surfaces, NOT
live. Independent review findings received regression fixes; live action qualification remains pending. The
follow-up-context slice then passed 437 Python tests (two skipped; existing
`ResourceWarning`s; `WorkerTests` now mocks `refresh_codex_auth` so protocol
tests can never copy the real `~/.codex/auth.json`), 1,113 main QtTests,
26 blocks / 23 visual / 12 answer, isolated service/store/detached checks and
the new `AiWorkspaceContextCheck` (real service → real broker → stub provider
in scratch HOMEs), all offscreen with no live provider call. No
version bump, release or canonical-repository sync is implied. The October 22
scratch/offscreen rerun passed 624 Python tests (2 skipped), 1,710 main QtTests,
28 blocks / 23 visual / 12 answer and all eight isolated checks listed in README.
The main total includes eight new `tests/TestJson.js` helper checks. Repaired
assertions use strict recursive leaf equality, ignoring only object key order,
not QtTest's numeric-tolerant object comparison (a 1e-6 difference is explicitly
rejected). The isolated fake Codex fixture was repaired too; no product changes
or new live qualification are implied.

Remaining: visible persistence-refusal feedback; scenario comparison reveal/
paging and export parity; plan editing beyond timeline completion; completed
laptop-decision flagship/provenance qualification; revision reconciliation and
conflict handling; general workspace export/bundle/history beyond calc copy and
view-local undo; full state-aware AI revisions (targeted artifact patches) beyond
bounded follow-up context, and full conversation branching. Live workspace
Rename/Duplicate, forms/actions/focus, bounded-snapshot provider quality,
corrected-type delivery, the compare-body issue, source disk-full/crash-mid-rename,
peek worst case, mixed DPR/second scale and full dataset/resource gates remain
outstanding. Editable calc data, named
scenarios, local undo, calc exports, source paging and typed computation are not
missing implementations. Phase 3 has not met its exit.

Deliverables:

- Typed expression runtime, input bindings, state transitions, and computed charts/tables.
- CSV import/preview, editable comparison data, scenario controls, and plan editing.
- Complete the laptop-decision flagship with transparent scoring and provenance.
- Add revision reconciliation, conflict handling, local undo, duplication, and exports.
- Search and reopen named tools from the launcher.

Exit: the comparison tool, a scenario calculator, and a CSV explorer work with user changes, accurate local computations, persistence, and state-aware AI revisions. The dataset stress fixture remains responsive with bounded memory, queued updates, and write volume.

### Phase 4 — Bespoke artifacts and richer media

The native OpenUI path in §3.4 is now a restricted declarative-runtime foundation,
not completion of this broader arbitrary-code/media phase. It is not yet deployed
or qualified against the live lifecycle/resource gates.

Deliverables:

- Integrate the isolated programmable runtime selected in Phase 0.
- Add generated artifact build/run/error/repair events, resource control, versioned code/state, and previous-working-version restoration.
- Implement at least two activities that exceed the declarative library: for example, a wave-interference canvas and a custom graph/pathfinding explorer.
- Add the chosen image-generation adapter and optional richer geographic/media providers where they improve evaluated tasks.
- Support selective regeneration of an illustration or interactive artifact without rebuilding the workspace.

Exit: both bespoke activities support meaningful interaction, state persistence, keyboard/text alternatives, cancellation, and crash recovery. The normal launcher stays responsive with the runtime active or failed. The runtime passes its separate process-tree memory budget and exits after the hidden grace period; it is absent from ordinary launcher/AI startup.

### Phase 5 — Sustained-use release and refinement

Deliverables:

- Complete workspace library, long-session navigation, branch/history UX, exports, and asset lifecycle management.
- Run the full benchmark and owner-led sessions spanning 10–30 minutes and return visits on another day.
- Tune medium selection, visual relevance, loading behavior, and model/media costs based on results.
- Finish theme/scaling/accessibility verification and document recovery paths.
- Update README and shipped capability descriptions to match verified behavior.

Exit: all six executive success criteria are met or have documented revised targets backed by measurements; the three core pillars and bespoke artifact path are demonstrably usable. Record idle and active cost alongside UI/quality results.

### 5.2 Dependency order

```text
Current implementation resource qualification + lifecycle refactoring
            ↓
Window/state/runtime feasibility
            ↓
Workspace identity + persistence + presentation contract
            ↓
Native interactive catalogue + asset pipeline
            ↓
Learning/exploration journeys + state-aware revisions
            ↓
Typed computation + data import + reusable tools
            ↓
Programmable artifacts + richer media
            ↓
Long-session refinement + release evaluation
```

Visual design and benchmark development should accompany every phase. Media-provider research and programmable-runtime research can proceed independently once their contracts are defined.

### 5.3 Principal technical and product risks

| Risk | Response in the plan |
| --- | --- |
| Generated interfaces become inconsistent or cluttered | Shared native vocabulary, composition rules, real-content review, benchmark medium selection |
| Elaborate interfaces delay a simple answer | Immediate useful answer, progressive assets, one-request planning where possible |
| Follow-ups destroy local edits | Stable IDs, base revisions, checkpoints, reconciliation and explicit conflicts |
| A simulation is plausible-looking but wrong | Reviewed formulas, expected-output fixtures, labelled simplifications, transfer checks |
| Retrieved images do not support the explanation | Role-driven candidate selection, actual-image review, alternatives and independent replacement |
| Shell/window lifecycle loses work or crashes | Transactional persistence, verified surface lifecycle, isolated advanced runtime |
| Provider capabilities differ | Capability negotiation, explicit unavailable states, state-based continuation |
| Long sessions exceed context or become expensive | Bounded summaries, selected-artifact context, local computation, measured request/media usage |
| Persistent artifacts depend on expired data/assets | Freshness metadata, retained asset references, refresh actions, cached local operation |
| Too much catalogue work before anything feels good | Three flagship vertical journeys and demonstrable exits at every phase |
| Hidden views, workers, or browser engines accumulate | Lazy instantiation, acknowledged snapshot/unload, process-tree budgets, repeated-use plateau test |
| A language rewrite adds complexity without reducing real cost | Keep Python initially; profile and prototype only a bounded Rust candidate that meets the migration gate |
| Autosave causes process churn, large writes, or lost edits | One lazy store connection, dirty updates, coalescing/backpressure, commit acknowledgements and ordering barriers |

### 5.4 Verification plan

- **Parsing/routing:** canonical `ai:` cases, rejected legacy prefix, query preservation, saved workspace ranking, mode handoff.
- **State/store:** transactions, schema migration, recovery from interrupted writes/jobs, deletion and asset reference cleanup, export/import round trips.
- **Presentation/runtime:** schema validation, invalid patches, stable identity, expressions and units, dependency cycles, runtime failures.
- **Interactions:** focus, multiline input, selections, keyboard diagram controls, quiz feedback, charts, sorting/filtering, undo/redo.
- **Async behavior:** cancellation, delayed/stale responses, edits during generation, failed media, adapter errors, reconnect/retry.
- **Live desktop:** repeated open/close, expansion/detach, click-outside behavior, normal window management, shell restart, monitor/scaling changes, theme changes.
- **Quality:** real sources/assets, correct calculations, relevant visual medium, useful teaching feedback, transparent assumptions.
- **Performance:** compare against the measured app/file launcher baseline and all phase-specific lifecycle, memory, CPU, process, latency, and storage budgets.

#### Resource measurement protocol

- Record OS/runtime versions, CPU/RAM/GPU, monitor scaling/refresh rate, theme, fixture versions, and cold versus warm conditions. Hold unrelated shell/plugin activity constant; use paired samples and repeat runs to distinguish feature cost from desktop noise.
- Capture idle shell/ordinary-launcher baselines, first AI entry, cached answer, real generation, media decode, active native tool, hidden view, post-cleanup close, and optional artifact runtime. Include helpers, provider CLIs, descendants, and GPU processes rather than measuring only the parent shell.
- Use `/proc/*/smaps_rollup` for PSS where available, process CPU counters and creation/exit tracing, and available GPU/frame/wakeup tools. Record tool limitations instead of attributing all shared-shell/GPU activity to the launcher. Profiling instrumentation runs for the test, not as permanent product polling.
- Use at least 30 measured opens/control sequences for p95 latency, after a separate warmup; report cold first use independently. Sample settled idle for 60 seconds after the 30-second cleanup deadline.
- Run 50 open/interact/close cycles on the same fixture and 20 workspace switches including images. After cleanup, final median retained PSS must remain within 5 MiB of the early warmed plateau and below the absolute idle budget; no monotonic process, descriptor, timer, or cache-count growth. Investigate allocator/Qt caching separately from true retained objects.
- Run a 30-minute mixed session and a continuous-edit/stream test. Verify no unbounded save backlog, bounded IPC/log/cache sizes, no writes during settled idle, and no orphan processes after Stop, close, failed jobs, or helper crash.
- Use fixed text/two-image, seasons, comparison, 100,000-row dataset, and programmable-artifact fixtures. Large libraries and long histories should increase disk/query work without hydrating every entry into RAM.
- Test correctness under eviction: close during autosave, reopen after worker exit, resume the provider session, restore after shell restart, handle a failed save, and Stop during media work. Repeat the required live image/DPR checks when changing view lifetime.
- Publish a compact before/after table per refactor: aggregate retained/peak PSS, CPU time/idle CPU, worker launches, bytes written, p95 latency, and correctness results. A feature/resource regression that breaches a gate blocks that milestone even if its UI tests pass.

Reuse the current QtTest/Python suites as appropriate, adding tests at the new architectural boundaries. Offscreen passes do not substitute for live scene-graph, compositor, focus, or image-lifecycle verification.

### 5.5 Decisions to resolve during implementation planning

These do not block adopting the product direction:

1. Exact normal-window hosting strategy after the installed-platform spike.
2. Programmable renderer/runtime choice and packaging cost, qualified against the resource gate.
3. Image-generation provider, additional retrieval/map sources, and acceptable per-session spend.
4. Model choice by task, after quality/latency comparison with the current launcher model.
5. Attachment/dataset limits and job-specific provider peak envelopes based on measured use; section 4.8 supplies initial local resource budgets.
6. Whether keep-open overlay is valuable alongside the normal workspace window.
7. Final product naming and an optional dedicated global shortcut, once the interaction is established.

### 5.6 First implementation brief

Continue with the immediate resource-qualification milestone on the existing implementation. Keep Python unless the measured migration gate warrants a targeted Rust component. Then complete the remaining Phase 0 design/feasibility work and three journey storyboards; settle the canvas composition and shared-state/window behavior before expanding the existing block list.

The first visible implementation milestone should demonstrate this continuous path:

**`ai:` → useful answer → manipulate an object → expand into a workspace → ask about a selection → close → restart → resume the same object.**

That continuity is the foundation for learning, exploration, and mini-apps to feel like one ambitious product.
