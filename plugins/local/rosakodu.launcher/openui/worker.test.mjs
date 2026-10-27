import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { readFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";

process.env.OPENUI_TELEMETRY_DISABLED = "1";
process.env.DO_NOT_TRACK = "1";
const require = createRequire(import.meta.url);
const { createSession, LIMITS } = require("./native-worker.cjs");
const { referenceExpression } = require("./dist/native-spec.cjs");
const examples = require("./native-examples.json");
const metadata = require("./native-metadata.json");
const workerPath = fileURLToPath(new URL("./native-worker.cjs", import.meta.url));

const flatten = (node) => [node, ...node.children.flatMap(flatten)];
const find = (reply, kind, predicate = () => true) => {
  assert.equal(reply.ok, true, JSON.stringify(reply));
  const node = flatten(reply.tree).find((node) => node.kind === kind && predicate(node.props, node));
  assert.ok(node, `${kind} not found`);
  return node;
};
const hasText = (reply, text) => flatten(reply.tree).some((node) => node.props.text === text);
function client(program, state = {}, token = "session-a") {
  const session = createSession();
  let id = 0;
  const load = (code, saved = {}) => session.handle({ id: ++id, token, op: "load", program: code, state: saved });
  const initial = load(program, state);
  const change = (node, value) => session.handle({ id: ++id, token, op: "event", target: node.id, event: "change", value });
  const click = (node) => session.handle({ id: ++id, token, op: "event", target: node.id, event: "click" });
  return { session, initial, load, change, click };
}
const example = (id) => examples.find((item) => item.id === id).program;
function assertTree(reply) {
  assert.equal(reply.ok, true, JSON.stringify(reply));
  const ids = new Set();
  for (const node of flatten(reply.tree)) {
    assert.deepEqual(Object.keys(node), ["id", "kind", "props", "children"]);
    assert.ok(!ids.has(node.id)); ids.add(node.id);
    assert.ok(metadata.componentNames.includes(node.kind));
    assert.equal(Object.hasOwn(node.props, "children"), false);
    assert.equal(Object.hasOwn(node.props, "action"), false);
    assert.equal(Object.hasOwn(node.props, "__openuiAuthoredAction"), false);
    assert.doesNotMatch(JSON.stringify(node.props), /__reactive|"valueAST"|"typeName"|"steps"/);
    if (["Button", "Pressable", "IconButton"].includes(node.kind)) assert.equal(typeof node.props.hasAction, "boolean");
  }
  assert.ok(ids.size <= LIMITS.nodes);
  assert.ok(Buffer.byteLength(JSON.stringify(reply) + "\n") <= LIMITS.frameBytes);
}

test("build uses exactly 33 real upstream components, all 59 functions and zero React runtime inputs", async () => {
  assert.equal(metadata.coreVersion, "1.0.0");
  assert.deepEqual(metadata.componentNames, [
    "Col", "Row", "Grid", "Card", "Box", "Divider", "Spacer", "Title", "Text", "Caption", "Label", "Badge",
    "Button", "IconButton", "Pressable", "Input", "TextArea", "Slider", "Checkbox", "Select", "SegmentedControl", "RadioGroup", "Icon",
    "Svg", "Circle", "Ellipse", "Rect", "Line", "Path", "Polyline", "Polygon", "G", "SvgText",
  ]);
  assert.equal(metadata.functionNames.length, 59);
  const meta = require("./native-worker.meta.json");
  assert.ok(Object.keys(meta.inputs).some((name) => name.endsWith("lang-core/dist/index.mjs")));
  assert.ok(Object.keys(meta.inputs).some((name) => name.endsWith("src/lib/functions/dates.ts")));
  assert.ok(!Object.keys(meta.inputs).some((name) => /node_modules\/(react(?:-dom)?\/|@openuidev\/react-lang\/)|src\/lib\/components\//.test(name)));
  assert.deepEqual(Object.values(meta.outputs).flatMap((output) => output.imports).map((item) => item.path), ["node:crypto"]);
  assert.equal(metadata.runtimeTelemetry, false);
  assert.ok(!Object.keys(meta.inputs).some((name) => /ci-info\/|shared-[^/]+\.mjs$/.test(name)));
  const bundle = await readFile(workerPath, "utf8");
  assert.doesNotMatch(bundle, /\bfetch\s*\(|getBuiltinModule|OPENUI_POSTHOG|cloudfront\.net|phc_/);
  for (const [name, artifact] of Object.entries(metadata.artifacts)) {
    const bytes = await readFile(new URL(name, import.meta.url));
    assert.equal(bytes.length, artifact.bytes);
    assert.equal(createHash("sha256").update(bytes).digest("hex"), artifact.sha256);
  }
  // Fidelity to the verified original full-component build, before extraction.
  const baseline = require("./upstream-inputs.json").referenceArtifacts;
  for (const [name, digest] of Object.entries(baseline)) {
    assert.equal(createHash("sha256").update(await readFile(new URL(name, import.meta.url))).digest("hex"), digest, name);
  }
  const prompt = await readFile(new URL("./native-system-prompt.txt", import.meta.url), "utf8");
  assert.doesNotMatch(prompt, /ToAssistant|OpenUrl|@Run\(/);
  for (const name of metadata.componentNames) assert.ok(prompt.includes(`${name}(`), name);
  for (const name of ["Image", "HtmlView", "Link", "Markdown", "Table", "Chart", "DatePicker", "Timer", "Form"]) assert.ok(!prompt.includes(`${name}(`), name);
});

for (const id of ["meal", "plan", "learn"]) test(`unchanged ${id} example loads and returns flattened bounded JSON`, () => {
  const c = client(example(id));
  assertTree(c.initial);
  c.session.dispose();
});

test("dinner: Guests 4→12 updates quantities, @Each actions, copy and disabled navigation", () => {
  const c = client(example("meal"));
  const slider = find(c.initial, "Slider", (p) => p.label === "People at the table");
  assert.equal(slider.props.value, 4);
  assert.ok(hasText(c.initial, "400 g"));
  let r = c.change(slider, 12);
  assertTree(r);
  assert.equal(r.state.$guests, 12);
  assert.ok(hasText(r, "1200 g"));
  assert.equal(find(r, "Slider").id, slider.id);
  assert.deepEqual(flatten(r.tree).map((n) => n.id), flatten(c.initial.tree).map((n) => n.id));
  r = c.click(find(r, "Pressable"));
  assert.deepEqual(r.state.$got, ["Pasta"]);
  assert.ok(hasText(r, "1 of 6 ingredients ready"));
  r = c.click(find(r, "Button", (p) => p.label === "Copy shopping list"));
  assert.match(r.copyText, /^Pasta: 1200 g\nChopped tomatoes: 2400 g/);
  r = c.click(find(r, "Button", (p) => p.label === "Next step"));
  r = c.click(find(r, "Button", (p) => p.label === "Next step"));
  const disabled = find(r, "Button", (p) => p.label === "Next step");
  assert.equal(disabled.props.disabled, true);
  assert.equal(c.click(disabled).error, "invalid_event");
  c.session.dispose();
});

test("plan: project input, stage selection, completion and reset remain linked", () => {
  const c = client(example("plan"));
  let r = c.change(find(c.initial, "Input"), "A useful project");
  assert.equal(r.state.$name, "A useful project");
  assert.ok(hasText(r, "A useful project"));
  const stages = flatten(r.tree).filter((n) => n.kind === "Pressable");
  r = c.click(stages[2]);
  assert.equal(r.state.$selected, 2);
  assert.equal(flatten(r.tree).filter((n) => n.kind === "Pressable")[2].props.selected, true);
  r = c.click(find(r, "Button", (p) => p.label === "Mark stage complete"));
  assert.deepEqual(r.state.$done, [2]);
  assert.ok(hasText(r, "1 of 3 complete"));
  r = c.click(find(r, "Button", (p) => p.label === "Reset progress"));
  assert.deepEqual(r.state.$done, []);
  c.session.dispose();
});

test("lever: arm changes update SVG coordinates and real arithmetic together", () => {
  const c = client(example("learn"));
  const svg = find(c.initial, "Svg");
  assert.equal(svg.props.viewBox, "0 0 340 230");
  assert.equal(svg.children.find((n) => n.kind === "Line" && n.props.stroke === "chart2").props.x1, 204);
  assert.ok(hasText(c.initial, "60 N"));
  let r = c.change(find(c.initial, "Slider", (p) => p.label === "Effort arm"), 4);
  const changedSVG = find(r, "Svg");
  assert.equal(changedSVG.id, svg.id);
  assert.equal(changedSVG.children.find((n) => n.kind === "Line" && n.props.stroke === "chart2").props.x1, 308);
  assert.ok(hasText(r, "30 N"));
  assert.ok(hasText(r, "120 N × 1 m ÷ 4 m = 30 N"));
  r = c.change(find(r, "RadioGroup"), "It halves");
  assert.equal(r.state.$answer, "It halves");
  assert.ok(hasText(r, "Exactly. Force × arm length must balance on both sides."));
  c.session.dispose();
});

test("state restore is acknowledged, reset uses declared defaults, stale tokens never replace a session", () => {
  const code = '$n = 4\n$word = "default"\nroot = Col([Input($n, "Number", "number"), Button("Reset", @Reset($n, $word))])';
  const c = client(code, { $n: 12, $word: "restored" });
  assert.equal(c.initial.state.$n, 12);
  assert.equal(find(c.initial, "Input").props.value, 12);
  const stale = c.session.handle({ id: 88, token: "stale", op: "event", target: "root/0", event: "change", value: 8 });
  assert.deepEqual(stale, { id: 88, token: "stale", ok: false, error: "stale_token" });
  assert.equal(c.session.handle({ id: 89, token: "stale", op: "load", program: code, state: {} }).error, "stale_token");
  let r = c.click(find(c.initial, "Button"));
  assert.deepEqual(r.state, { $n: 4, $word: "default" });
  assert.equal(c.load('root = Unknown("bad")').ok, false);
  r = c.change(find(r, "Input"), 5);
  assert.equal(r.state.$n, 5); // Failed load did not destroy previous state/handles.
  c.session.dispose();
});

test("numeric blank, booleans, choices, textarea and reactive assignment use actual state fields", () => {
  const c = client('$n = 3\n$yes = false\n$choice = "a"\n$body = ""\nroot = Col([Input($n = @Clamp($value, 0, 10), "n", "number"), Checkbox($yes, "ok"), Select($choice, ["a", {value: "b", label: "Bee"}]), SegmentedControl($choice, ["a", "b"]), TextArea($body)])');
  assertTree(c.initial);
  let r = c.change(find(c.initial, "Input"), 20);
  assert.equal(r.state.$n, 10);
  assert.equal(find(r, "Input").props.value, 10);
  assert.equal(c.change(find(r, "Input"), "12").error, "invalid_event");
  assert.equal(c.change(find(r, "Checkbox"), "true").error, "invalid_event");
  r = c.change(find(r, "Checkbox"), true);
  assert.equal(r.state.$yes, true);
  assert.equal(find(r, "Checkbox").props.checked, true);
  assert.equal(c.change(find(r, "Select"), "invented").error, "invalid_event");
  r = c.change(find(r, "Select"), "b");
  assert.equal(r.state.$choice, "b");
  assert.equal(find(r, "SegmentedControl").props.value, "b");
  const large = "é".repeat(16000);
  r = c.change(find(r, "TextArea"), large);
  assert.equal(r.state.$body, large);
  assert.equal(c.change(find(r, "TextArea"), large + "é".repeat(385)).error, "limit_exceeded");
  c.session.dispose();
  const blank = client('$n = 2\nroot = Col([Input($n, "n", "number")])');
  assert.equal(blank.change(find(blank.initial, "Input"), null).state.$n, null);
  blank.session.dispose();
});

test("SVG G children are flattened; rich Text is a readable string; inert buttons cannot call AI", () => {
  const c = client('root = Col([Svg([G([Circle(5, 6, 2), Ellipse(7, 8, 3, 4), Path("M0 0 L2 2"), Polyline("0,0 1,1")], "translate(2 3)")], "0 0 10 10"), Text(["Ready ", Badge("now"), " ", Icon("check")]), Button("No action"), IconButton("copy")])');
  assertTree(c.initial);
  assert.equal(find(c.initial, "G").children.length, 4);
  assert.equal(find(c.initial, "Text").props.text, "Ready now check");
  const inert = find(c.initial, "Button");
  assert.equal(inert.props.hasAction, false);
  assert.equal(c.click(inert).error, "invalid_event");
  c.session.dispose();
});

test("only complete allowed local actions execute; unsupported full plans cannot partially Set", () => {
  const c = client('$n = 1\nroot = Col([Button("Bad", {steps: [{type: "set", target: "$n", valueAST: {k: "Num", v: 9}}, {type: "open_url", url: "https://example.invalid"}]}), Button("Copy", @CopyToClipboard("local text")), Button("Count", Action([@Set($n, $n + 1), @Set($n, $n + 1)]))])');
  assert.equal(c.initial.ok, true, JSON.stringify(c.initial));
  assert.equal(c.click(find(c.initial, "Button", (p) => p.label === "Bad")).error, "unsupported_action");
  let r = c.click(find(c.initial, "Button", (p) => p.label === "Copy"));
  assert.equal(r.copyText, "local text");
  assert.equal(r.state.$n, 1);
  r = c.click(find(r, "Button", (p) => p.label === "Count"));
  assert.equal(r.state.$n, 3);
  c.session.dispose();
  const tooMany = client('$n = 0\nroot = Col([Button("Many", Action([' + Array(9).fill('@Set($n, $n + 1)').join(",") + ']))])');
  assert.equal(tooMany.click(find(tooMany.initial, "Button")).error, "limit_exceeded");
  tooMany.session.dispose();
});

test("invalid source, unknown components/functions, protocol scripts and all tool/action calls are blocked", () => {
  const codes = [
    "garbage", 'root = Col([Title("truncated")', 'root = Col([Unknown("bad")])',
    'root = Col([Text(@NotAFunction(3))])', 'root = Col([])\nignored garbage',
    'root = Col([])\nx = Query("secret", {})', 'root = Col([])\nx = Mutation("secret", {})',
    'root = Col([Button("bad", @ToAssistant("go"))])',
    'root = Col([Button("bad", @OpenUrl("https://example.invalid"))])',
    'root = Col([Button("bad", @Run(tool))])',
    'root = Col([])\nunused = Image("https://example.invalid")',
    ']]>openui:script\nroot = Col([])', '```openui-lang\nroot = Col([])\n```',
    'root = Col([]); process.exit()', 'root = Col([])\n$n = @Random(1, 5)',
    'root = Col([Text("x".constructor)])', 'root = Col([Text({__proto__: "bad"})])',
    'notroot = Col([])', 'root = Col([]))',
  ];
  for (const code of codes) {
    const c = client(code);
    assert.equal(c.initial.ok, false, code);
    assert.ok(["invalid_program", "runtime_error"].includes(c.initial.error), JSON.stringify(c.initial));
    assert.equal(Object.keys(c.initial).length, 4);
    c.session.dispose();
  }
});

test("bounds reject excessive source/state/statements/variables/nodes/strings and roll back failed events", () => {
  const codes = [
    'root = Col([])\n' + " ".repeat(LIMITS.programBytes),
    Array.from({ length: 161 }, (_, i) => `x${i} = ${i}`).join("\n") + '\nroot = Col([])',
    Array.from({ length: 41 }, (_, i) => `$x${i} = ${i}`).join("\n") + '\nroot = Col([])',
    'root = Col(@Each(@Range(0, 512), "i", Text(i + "")))',
    `root = Col([Text("${"é".repeat(2049)}")])`,
  ];
  for (const code of codes) {
    const c = client(code);
    assert.equal(c.initial.error, "limit_exceeded", JSON.stringify(c.initial));
    c.session.dispose();
  }
  const state = client('$n = ""\nroot = Col([])', { $n: "x".repeat(LIMITS.stateBytes) });
  assert.equal(state.initial.error, "limit_exceeded"); state.session.dispose();
  const c = client('$n = 1\nroot = Col([Slider($n, 1, 1000), Col(@Each(@Range(0, $n), "i", Text(i + "")))])');
  assert.equal(c.change(find(c.initial, "Slider"), 0).error, "invalid_event");
  assert.equal(c.change(find(c.initial, "Slider"), 1001).error, "invalid_event");
  assert.equal(c.change(find(c.initial, "Slider"), 600).error, "limit_exceeded");
  const r = c.change(find(c.initial, "Slider"), 2);
  assert.equal(r.state.$n, 2);
  assertTree(r);
  c.session.dispose();
});

test("full V8 semantics: 38 spike vectors equal the untouched installed Node reference", () => {
  const sources = [
    '@Pow(2, 10)', '@Sqrt(-1)', '@Clamp(5, 0, 3)', '@Percent(3, 4)', '@Lerp(0, 10, 0.25)',
    '@Allocate(100, [1, 1, 1])', '@Round(@Payment(300000, 0.5, 360), 2)', '@Convert(100, "c", "f")',
    '@MixColor("#ffffff", "#000000", 0.5)', '@Join(["a", null, "b"], "-")', '@Pad(7, 2)',
    '@Upper("hello")', '@Lower("Hello")', '@Trim(" hi ")', '@Split("a, b,,c")', '@Replace("a-b-c", "-", " / ")',
    '@Duration(4800)', '@Default(null, 0)', '@Append([1, 2], 3)', '@Toggle([1, 2], 2)',
    '@Includes([{a: 1}], {a: 1})', '@Flatten([[1, 2], [3]])', '@Range(0, 3)',
    '@AddDays("2026-10-24", 2)', '@AddMonths("2026-01-31", 1)', '@DaysBetween("2026-10-24", "2026-10-26")',
    '@MonthsBetween("2026-01-24", "2026-10-24")', '@StartOf("2026-10-24", "week")', '@FormatDate("2026-10-24", "iso")',
    '@Each(@Range(0, 3), "n", n * 2)',
    '@Format(12345.678)', '@Format(1234.5, "currency")', '@Format(1234567, "compact")',
    '@FormatDate("2026-10-24", "long")', '@Plural(2, "guest")', '@Plural(1500, "step")',
    '@Capitalize("new york-city trip")', '@Capitalize("élan vital")',
  ];
  assert.equal(sources.length, 38);
  for (const source of sources) {
    const c = client(`$value = null\nroot = Col([Button("Evaluate", @Set($value, ${source}))])`);
    const reply = c.click(find(c.initial, "Button"));
    assert.equal(reply.ok, true, `${source}: ${JSON.stringify(reply)}`);
    assert.deepEqual(reply.state.$value, referenceExpression(source), source);
    if (source === '@Sqrt(-1)') assert.equal(reply.warning, "Some values could not be calculated.");
    c.session.dispose();
  }
  assert.equal(referenceExpression('@Format(1234.5, "currency")'), "$1,234.50");
  assert.equal(referenceExpression('@FormatDate("2026-10-24", "long")'), "Saturday, October 24, 2026");
  assert.equal(referenceExpression('@Capitalize("élan vital")'), "Élan Vital");
});

function cli(input) {
  const result = spawnSync(process.execPath, ["--max-old-space-size=64", workerPath], {
    input, timeout: 2000, maxBuffer: 2 * LIMITS.frameBytes,
    env: { PATH: process.env.PATH, HOME: "/tmp/opencode", LANG: "C.UTF-8", TZ: "UTC" },
  });
  assert.equal(result.error, undefined);
  assert.equal(result.status, 0, result.stderr.toString());
  assert.equal(result.stderr.toString(), "");
  const lines = result.stdout.toString().trimEnd().split("\n").filter(Boolean);
  for (const line of lines) assert.ok(Buffer.byteLength(line + "\n") <= LIMITS.frameBytes);
  return lines.map((line) => JSON.parse(line));
}

test("spawned bounded CLI loads all three examples with only fake JSON input", () => {
  for (const item of examples) {
    const [reply] = cli(JSON.stringify({ id: 7, token: `fake-${item.id}`, op: "load", program: item.program, state: {} }) + "\n");
    assert.equal(reply.id, 7); assert.equal(reply.token, `fake-${item.id}`); assertTree(reply);
  }
});

test("spawned CLI events, stale tokens, malformed JSON, invalid UTF-8 and unterminated frames", () => {
  const input = [
    { id: 1, token: "fake", op: "load", program: '$n = 4\nroot = Col([Input($n, "n", "number"), Button("Copy", @CopyToClipboard("safe"))])', state: {} },
    { id: 2, token: "old", op: "event", target: "root/0", event: "change", value: 9 },
    { id: 3, token: "fake", op: "event", target: "root/0", event: "change", value: 12 },
    { id: 4, token: "fake", op: "event", target: "root/1", event: "click" },
  ].map(JSON.stringify).join("\n") + '\n{broken\n';
  const replies = cli(input);
  assert.equal(replies.length, 5);
  assert.equal(replies[1].error, "stale_token");
  assert.equal(replies[2].state.$n, 12);
  assert.equal(replies[3].copyText, "safe");
  assert.equal(replies[4].error, "invalid_request");
  assert.equal(cli(Buffer.from([255, 10]))[0].error, "invalid_request");
  assert.equal(cli('{"id":1}')[0].error, "invalid_request");
});

test("spawned CLI discards an oversized frame, recovers, and never emits a huge frame", () => {
  const good = JSON.stringify({ id: 2, token: "fake", op: "load", program: 'root = Col([])', state: {} });
  const replies = cli("x".repeat(LIMITS.frameBytes + 100) + "\n" + good + "\n");
  assert.deepEqual(replies[0], { id: null, token: "", ok: false, error: "limit_exceeded" });
  assert.equal(replies[1].ok, true);
  const c = client('$n = 0\nroot = Col(@Each(@Range(0, 140), "i", Text(@Join(@Each(@Range(0, 4096), "j", "x")))))');
  assert.equal(c.initial.error, "limit_exceeded"); // Total frame, not just individual strings.
  c.session.dispose();
});

test("invalid API requests stay static and cannot mutate prototypes or expose exceptions", () => {
  const session = createSession();
  for (const input of [null, [], {}, { id: 1, token: "x", op: "file", path: "/etc/passwd" }, { id: 1.5, token: "x", op: "load" }, { id: 1, token: "x".repeat(129), op: "load" }]) {
    const reply = session.handle(input);
    assert.equal(reply.ok, false);
    assert.match(reply.error, /^[a-z_]+$/);
    assert.equal("stack" in reply, false);
  }
  const cyclic = { id: 1, token: "x", op: "load", program: "root = Col([])", state: {} }; cyclic.state.loop = cyclic;
  assert.equal(session.handle(cyclic).ok, false);
  const malicious = JSON.parse('{"id":1,"token":"x","op":"load","program":"root = Col([])","state":{"__proto__":{"polluted":true}}}');
  assert.equal(session.handle(malicious).ok, false);
  assert.equal({}.polluted, undefined);
  session.dispose();
});

test("semantic handles reject stale actions and input bindings at the same positional target", () => {
  const session = createSession();
  const token = "semantic";
  let reply = session.handle({ id: 1, token, op: "load", program: '$page = false\n$deleted = false\nroot = $page ? Button("Delete", @Set($deleted, true)) : Button("Next", @Set($page, true))', state: {} });
  const original = reply.tree.props._openuiHandle;
  reply = session.handle({ id: 2, token, op: "event", target: "root", event: "click", handle: original });
  assert.equal(reply.state.$page, true);
  assert.equal(reply.state.$deleted, false);
  assert.notEqual(reply.tree.props._openuiHandle, original);
  assert.equal(session.handle({ id: 3, token, op: "event", target: "root", event: "click", handle: original }).error, "invalid_event");
  reply = session.handle({ id: 4, token, op: "event", target: "root", event: "click", handle: reply.tree.props._openuiHandle });
  assert.equal(reply.state.$deleted, true);
  session.dispose();
  const input = createSession();
  reply = input.handle({ id: 1, token, op: "load", program: '$a = "A"\n$b = "B"\n$show = true\nroot = Col([$show ? Input($a, "A") : Input($b, "B"), Button("Switch", @Set($show, false))])', state: {} });
  const binding = reply.tree.children[0].props._openuiHandle;
  reply = input.handle({ id: 2, token, op: "event", target: "root/0", event: "change", value: "Ab", handle: binding });
  assert.equal(reply.tree.children[0].props._openuiHandle, binding, "state acknowledgements preserve semantic identity");
  reply = input.handle({ id: 3, token, op: "event", target: "root/1", event: "click" });
  assert.notEqual(reply.tree.children[0].props._openuiHandle, binding);
  assert.equal(input.handle({ id: 4, token, op: "event", target: "root/0", event: "change", value: "Wrong", handle: binding }).error, "invalid_event");
  input.dispose();
});

test("Copy keeps its semantic handle across an edit and copies current acknowledged values", () => {
  const c = client('$name = "Old"\nroot = Col([Input($name), Button("Copy", @CopyToClipboard($name))])');
  const copy = find(c.initial, "Button");
  const reply = c.change(find(c.initial, "Input"), "Current");
  assert.equal(find(reply, "Button").props._openuiHandle, copy.props._openuiHandle);
  const copied = c.session.handle({ id: 99, token: "session-a", op: "event", target: copy.id, event: "click", handle: copy.props._openuiHandle });
  assert.equal(copied.ok, true);
  assert.equal(copied.copyText, "Current");
  c.session.dispose();
});

test("distinct authored Copy actions keep distinct handles when a conditional replacement lands at the same path", () => {
  const c = client('$showA = true\nroot = Col([$showA ? Button("Copy A", @CopyToClipboard("A")) : Button("Copy B", @CopyToClipboard("B")), Button("Switch", @Set($showA, false))])');
  const copyA = find(c.initial, "Button", (p) => p.label === "Copy A");
  assert.equal(Object.hasOwn(copyA.props, "__openuiAuthoredAction"), false);
  const switched = c.click(find(c.initial, "Button", (p) => p.label === "Switch"));
  const copyB = find(switched, "Button", (p) => p.label === "Copy B");
  assert.equal(copyB.id, copyA.id);
  assert.notEqual(copyB.props._openuiHandle, copyA.props._openuiHandle);
  const stale = c.session.handle({ id: 100, token: "session-a", op: "event", target: copyA.id, event: "click", handle: copyA.props._openuiHandle });
  assert.equal(stale.error, "invalid_event");
  const fresh = c.session.handle({ id: 101, token: "session-a", op: "event", target: copyB.id, event: "click", handle: copyB.props._openuiHandle });
  assert.equal(fresh.ok, true, JSON.stringify(fresh));
  assert.equal(fresh.copyText, "B");
  c.session.dispose();
});
