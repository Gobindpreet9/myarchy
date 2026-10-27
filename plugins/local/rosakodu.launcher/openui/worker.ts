import {
  createParser, createStore, evaluate, evaluateRoot, isReactiveAssign,
  markReactive, parseExpression, resolveStateField, split, tokenize, walkAST,
  type ActionPlan, type ASTNode, type ElementNode, type EvaluationContext,
  type Library, type LibraryJSONSchema, type ParseResult, type Store,
} from "@openuidev/lang-core";
import { functions } from "./vendor/src/lib/functions";
import schemaJSON from "./native-schema.json";
import reactiveJSON from "./native-reactive.json";
import { createHash } from "node:crypto";

export const LIMITS = Object.freeze({
  frameBytes: 512 * 1024, programBytes: 32 * 1024, stateBytes: 64 * 1024,
  stateVariables: 40, statements: 160, nodes: 512, propStringBytes: 4096,
  textAreaBytes: 32 * 1024, actionSteps: 8, tokenBytes: 128,
  jsonDepth: 64, jsonValues: 32768,
});

type JSONValue = null | boolean | number | string | JSONValue[] | { [key: string]: JSONValue };
export type Node = { id: string; kind: string; props: Record<string, JSONValue>; children: Node[] };
type ErrorCode = "invalid_request" | "invalid_program" | "limit_exceeded" | "stale_token" | "not_loaded" | "invalid_event" | "unsupported_action" | "runtime_error";
type Reply = { id: number | null; token: string; ok: false; error: ErrorCode } | {
  id: number; token: string; ok: true; tree: Node; state: Record<string, JSONValue>; copyText?: string; warning?: string;
};
type Control = { kind: string; prop: string; binding: unknown; props: Record<string, JSONValue> };
type Handles = { actions: Map<string, unknown>; controls: Map<string, Control>; disabled: Set<string>; identities: Map<string, string> };
type Loaded = { parsed: ParseResult; defaults: Record<string, JSONValue>; store: Store; handles: Handles };

const schema = schemaJSON as LibraryJSONSchema;
const reactiveProps = reactiveJSON as Record<string, string[]>;
const componentNames = new Set(Object.keys(schema.properties ?? {}));
const components = Object.fromEntries([...componentNames].map((name) => {
  const shape = Object.fromEntries(Object.keys(schema.$defs?.[name]?.properties ?? {}).map((key) => {
    const prop = {};
    if (reactiveProps[name]?.includes(key)) markReactive(prop);
    return [key, prop];
  }));
  return [name, { props: { shape } }];
}));
// The evaluator only reads props.shape. Actual schema and reactive markers were
// extracted from the real createLibrary; no React code exists in this bundle.
const library = { components } as unknown as Library;
const parser = createParser(schema, "Col");
const runtimeFunctions = Object.fromEntries(functions.map((fn) => [fn.name, { ...schema.functions![fn.name], fn: fn.fn }]));
const builtinNames = ["Count", "First", "Last", "Sum", "Avg", "Min", "Max", "Sort", "Filter", "Round", "Abs", "Floor", "Ceil", "Each"];
const allowedCalls = new Set([...componentNames, ...functions.map((fn) => fn.name), ...builtinNames, "Action", "Set", "Reset", "CopyToClipboard"]);
const forbiddenKeys = new Set(["__proto__", "constructor", "prototype"]);
const controlProps: Record<string, string> = {
  Input: "value", TextArea: "value", Slider: "value", Checkbox: "checked",
  Select: "value", SegmentedControl: "value", RadioGroup: "value",
};
const clickKinds = new Set(["Button", "IconButton", "Pressable"]);
const fail = (code: ErrorCode): never => { throw new WorkerError(code); };
class WorkerError extends Error { constructor(readonly code: ErrorCode) { super(code); } }
const bytes = (value: string) => Buffer.byteLength(value, "utf8");
// Trusted-only prop carrying the authored action fingerprint. The parser never
// produces this key, annotation replaces/deletes any authored copy, and convert
// consumes it instead of emitting it.
const AUTHORED_ACTION = "__openuiAuthoredAction";
const plain = (value: unknown): value is Record<string, unknown> => !!value && typeof value === "object" &&
  (Object.getPrototypeOf(value) === Object.prototype || Object.getPrototypeOf(value) === null);
const own = (value: object, key: string) => Object.prototype.hasOwnProperty.call(value, key);
const isElement = (value: unknown): value is ElementNode => plain(value) && value.type === "element" && typeof value.typeName === "string";

// Deterministic serialization of the authored AST. Property order is sorted so
// the same source always yields the same fingerprint, independent of how the
// parser happened to build the object.
function canonical(value: unknown): string {
  if (value === null || value === undefined) return "null";
  if (typeof value === "string") return JSON.stringify(value);
  if (typeof value === "number") return Number.isFinite(value) ? JSON.stringify(value) : "null";
  if (typeof value === "boolean") return value ? "true" : "false";
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (typeof value !== "object") return "null";
  const entries = Object.entries(value as Record<string, unknown>)
    .filter(([, item]) => item !== undefined)
    .sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0);
  return `{${entries.map(([key, item]) => `${JSON.stringify(key)}:${canonical(item)}`).join(",")}}`;
}

// Copy payloads are late-bound so a queued Copy still sees the acknowledged
// state. Two different authored Copy expressions must still get different
// semantic handles, otherwise a stale click could execute the replacement
// action at the same structural path. Fingerprint the authored action AST
// before evaluation and carry it through evaluation as an inert prop.
function annotateAuthoredActions(parsed: ParseResult) {
  const seen = new Set<object>();
  const fingerprint = (action: unknown) => action == null ? null
    : createHash("sha256").update(canonical(action)).digest("hex");
  function visit(value: unknown) {
    if (!value || typeof value !== "object" || seen.has(value)) return;
    seen.add(value);
    const node = value as Record<string, unknown>;
    if (node.type === "element" && typeof node.typeName === "string") {
      const props = node.props;
      if (plain(props)) {
        const authored = fingerprint(props.action);
        if (authored) props[AUTHORED_ACTION] = authored;
        else delete props[AUTHORED_ACTION];
        for (const item of Object.values(props)) visit(item);
      }
      return;
    }
    if (node.k === "Comp" && plain(node.mappedProps)) {
      const mapped = node.mappedProps as Record<string, unknown>;
      const authored = fingerprint(mapped.action);
      if (authored) mapped[AUTHORED_ACTION] = { k: "Str", v: authored };
      else delete mapped[AUTHORED_ACTION];
    }
    for (const item of Object.values(node)) visit(item);
  }
  visit(parsed.root);
  visit(parsed.rootExpression);
}

// Reject non-JSON/cyclic/prototyped input even for callers of the testable API.
// Also prevents core AST/action/reactive handles leaking through JSON props.
function json(value: unknown, stringLimit = LIMITS.stateBytes): JSONValue {
  let count = 0;
  const seen = new Set<object>();
  function copy(v: unknown, depth: number): JSONValue {
    if (++count > LIMITS.jsonValues || depth > LIMITS.jsonDepth) fail("limit_exceeded");
    if (v === null || typeof v === "boolean") return v;
    if (typeof v === "number") { if (!Number.isFinite(v)) fail("runtime_error"); return v; }
    if (typeof v === "string") { if (bytes(v) > stringLimit) fail("limit_exceeded"); return v; }
    if (!Array.isArray(v) && !plain(v)) fail("invalid_request");
    if (seen.has(v)) fail("invalid_request");
    seen.add(v);
    let result: JSONValue;
    if (Array.isArray(v)) result = v.map((item) => copy(item, depth + 1));
    else {
      if (isElement(v) || isReactiveAssign(v)) fail("invalid_request");
      const entries = Object.entries(v);
      if (entries.some(([key]) => forbiddenKeys.has(key))) fail("invalid_request");
      result = Object.fromEntries(entries.map(([key, item]) => {
        if (bytes(key) > LIMITS.propStringBytes) fail("limit_exceeded");
        return [key, copy(item, depth + 1)];
      }));
    }
    seen.delete(v);
    return result;
  }
  return copy(value, 0);
}

function stateJSON(value: unknown): Record<string, JSONValue> {
  if (!plain(value)) fail("invalid_request");
  if (Object.keys(value).length > LIMITS.stateVariables) fail("limit_exceeded");
  const result = json(value) as Record<string, JSONValue>;
  if (bytes(JSON.stringify(result)) > LIMITS.stateBytes) fail("limit_exceeded");
  return result;
}

function checkedProgram(program: string): ParseResult {
  if (!program.trim()) fail("invalid_program");
  if (bytes(program) > LIMITS.programBytes) fail("limit_exceeded");
  if (program.includes("]]>openui:") || program.includes("```")) fail("invalid_program");
  // This is a rejection-only lexical guard, not another language parser. Core's
  // lexer silently skips unknown punctuation; do not let scripts exploit that.
  const masked = program.replace(/"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\/\/[^\n]*|#[^\n]*/g, (part) => " ".repeat(part.length));
  if (/[^\w\s$@.()[\]{},:?+*/%!=<>|&-]/u.test(masked)) fail("invalid_program");
  const stack: string[] = [];
  for (const ch of masked) {
    if ("([{".includes(ch)) stack.push(ch);
    if (")]}".includes(ch) && stack.pop() !== ({ ")": "(", "]": "[", "}": "{" } as Record<string, string>)[ch]) fail("invalid_program");
  }
  if (stack.length) fail("invalid_program");
  // Use the real token/split/AST APIs to inspect ALL declarations, including
  // unreachable branches/statements (where the core parser may omit errors).
  const tokens = tokenize(program.replace(/"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\/\/[^\n]*|#[^\n]*/g, (part) => part.startsWith("//") || part.startsWith("#") ? " " : part));
  const statements = split(tokens);
  if (statements.length > LIMITS.statements) fail("limit_exceeded");
  if (!statements.some((s) => s.id === "root") || new Set(statements.map((s) => s.id)).size !== statements.length) fail("invalid_program");
  // Invalid non-statement lines are silently skipped by split; reject them.
  if (tokens.filter((t) => t.t !== 0 && t.t !== 13).length !== statements.reduce((n, s) => n + 2 + s.tokens.length, 0)) fail("invalid_program");
  for (const statement of statements) {
    if (forbiddenKeys.has(statement.id)) fail("invalid_program");
    const ast = parseExpression(statement.tokens);
    walkAST(ast, (node) => {
      if (node.k === "Comp" && !allowedCalls.has(node.name)) fail("invalid_program");
      if (node.k === "RuntimeRef" || node.k === "Ph") fail("invalid_program");
      if (node.k === "Member" && forbiddenKeys.has(node.field)) fail("invalid_program");
      if (node.k === "Obj" && node.entries.some(([key]) => forbiddenKeys.has(key))) fail("invalid_program");
    });
    if (statement.id.startsWith("$")) {
      walkAST(ast, (node) => { if (!["Str", "Num", "Bool", "Null", "Arr", "Obj"].includes(node.k)) fail("invalid_program"); });
    }
  }
  const parsed = parser.parse(program);
  if ((!parsed.root && !parsed.rootExpression) || parsed.meta.incomplete || parsed.meta.unresolved.length || parsed.meta.errors.length || parsed.queryStatements.length || parsed.mutationStatements.length) fail("invalid_program");
  if (parsed.meta.statementCount > LIMITS.statements || Object.keys(parsed.stateDeclarations).length > LIMITS.stateVariables) fail("limit_exceeded");
  annotateAuthoredActions(parsed);
  return parsed;
}

function context(store: Store, errors: unknown[]): EvaluationContext {
  return {
    getState: (name) => store.get(name), resolveRef: () => null,
    functions: runtimeFunctions, actions: schema.actions,
    reportError: () => { errors.push(true); },
  };
}

function render(loaded: Loaded): { tree: Node; state: Record<string, JSONValue>; handles: Handles; warning: boolean } {
  const errors: unknown[] = [];
  const functionErrors: unknown[] = [];
  const ctx = context(loaded.store, functionErrors);
  const handles: Handles = { actions: new Map(), controls: new Map(), disabled: new Set(), identities: new Map() };
  const root = evaluateRoot(loaded.parsed, { ctx, library, store: loaded.store, errors: errors as any[] });
  if (!root || errors.length) fail("runtime_error");
  let nodes = 0;
  const active = new Set<object>();

  function text(value: unknown, depth = 0): string {
    if (depth > LIMITS.jsonDepth) fail("limit_exceeded");
    let result: string;
    if (value == null) result = "";
    else if (typeof value === "string" || typeof value === "number" || typeof value === "boolean") result = String(value);
    else if (Array.isArray(value)) result = value.map((part) => text(part, depth + 1)).join("");
    else if (isElement(value) && componentNames.has(value.typeName)) {
      if (++nodes > LIMITS.nodes) fail("limit_exceeded");
      result = text(value.props.text ?? value.props.label ?? value.props.icon ?? value.props.name ?? value.props.children ?? "", depth + 1);
    } else fail("runtime_error");
    if (bytes(result) > LIMITS.propStringBytes) fail("limit_exceeded");
    return result;
  }

  function convert(el: ElementNode, id: string, depth: number): Node {
    if (++nodes > LIMITS.nodes || depth > LIMITS.jsonDepth) fail("limit_exceeded");
    if (!componentNames.has(el.typeName) || el.partial || active.has(el)) fail("invalid_program");
    active.add(el);
    const kind = el.typeName;
    const props: Record<string, JSONValue> = {};
    const children: Node[] = [];
    let authored: string | null = null;
    function append(value: unknown, nesting: number) {
      if (nesting > LIMITS.jsonDepth) fail("limit_exceeded");
      if (value == null || value === false) return;
      if (Array.isArray(value)) { for (const item of value) append(item, nesting + 1); return; }
      if (!isElement(value)) fail("runtime_error");
      children.push(convert(value, `${id}/${children.length}`, depth + 1));
    }
    for (const [key, value] of Object.entries(el.props)) {
      if (value === undefined) continue;
      if (key === AUTHORED_ACTION) { if (typeof value === "string") authored = value; continue; }
      if (key === "children") { append(value, 0); continue; }
      if (key === "action") { if (value != null) handles.actions.set(id, value); continue; }
      if (controlProps[kind] === key) continue;
      props[key] = key === "text" ? text(value) : json(value, LIMITS.propStringBytes);
    }
    if (clickKinds.has(kind)) props.hasAction = handles.actions.has(id);
    if (handles.actions.has(id)) {
      const plan = handles.actions.get(id) as ActionPlan;
      // Copy's payload is deliberately late-bound to the acknowledged state.
      // It is still the same local Copy action after a preceding queued edit.
      const identity = plain(plan) && Array.isArray(plan.steps) ? {
        steps: plan.steps.map((step) => step.type === "custom_action" && step.name === "CopyToClipboard"
          ? { ...step, params: { text: "<current plain text>" } } : step),
      } : plan;
      props._openuiHandle = createHash("sha256").update(kind + JSON.stringify(authored === null ? identity : { authored, identity })).digest("hex");
      handles.identities.set(id, props._openuiHandle as string);
    }
    if (props.disabled === true) handles.disabled.add(id);
    const prop = controlProps[kind];
    if (prop) {
      const binding = el.props[prop];
      if (!isReactiveAssign(binding) || !own(loaded.defaults, binding.target)) fail("invalid_program");
      const field = resolveStateField(id, binding, loaded.store, ctx, () => undefined, () => fail("invalid_event"));
      props[prop] = json(field.value, kind === "TextArea" ? LIMITS.textAreaBytes : LIMITS.propStringBytes);
      handles.controls.set(id, { kind, prop, binding, props });
      props._openuiHandle = createHash("sha256").update(JSON.stringify([kind, binding,
        props.type ?? null, props.options ?? null, kind === "Slider" ? [props.min, props.max] : null])).digest("hex");
      handles.identities.set(id, props._openuiHandle as string);
    }
    active.delete(el);
    return { id, kind, props, children };
  }
  const tree = convert(root, "root", 0);
  if (errors.length) fail("runtime_error");
  return { tree, state: stateJSON(loaded.store.getSnapshot()), handles, warning: functionErrors.length > 0 };
}

function controlValue(control: Control, value: unknown): JSONValue {
  const { kind, props } = control;
  if (kind === "Checkbox") {
    if (typeof value !== "boolean") fail("invalid_event");
    return value;
  }
  if (kind === "Slider" || (kind === "Input" && props.type === "number")) {
    if (kind === "Input" && value === null) return null;
    if (typeof value !== "number" || !Number.isFinite(value)) fail("invalid_event");
    if (kind === "Slider" && (typeof props.min !== "number" || typeof props.max !== "number" || props.max < props.min || value < props.min || value > props.max)) fail("invalid_event");
    return value;
  }
  if (typeof value !== "string") fail("invalid_event");
  if (bytes(value) > (kind === "TextArea" ? LIMITS.textAreaBytes : LIMITS.propStringBytes)) fail("limit_exceeded");
  if (["Select", "SegmentedControl", "RadioGroup"].includes(kind)) {
    const options = props.options;
    if (!Array.isArray(options) || !options.some((option) => typeof option === "string" ? option === value : plain(option) && option.value === value)) fail("invalid_event");
  }
  return value;
}

function action(loaded: Loaded, plan: unknown): { copyText: string | undefined; warning: boolean } {
  if (!plain(plan) || !Array.isArray(plan.steps) || !plan.steps.length) fail("unsupported_action");
  if (plan.steps.length > LIMITS.actionSteps) fail("limit_exceeded");
  // Preflight the WHOLE plan before touching even the candidate state.
  for (const step of plan.steps) {
    if (!plain(step)) fail("unsupported_action");
    if (step.type === "set") {
      if (typeof step.target !== "string" || !own(loaded.defaults, step.target) || !plain(step.valueAST)) fail("unsupported_action");
      walkAST(step.valueAST as ASTNode, (node) => {
        if (node.k === "Comp" && !allowedCalls.has(node.name)) fail("unsupported_action");
        if (node.k === "RuntimeRef") fail("unsupported_action");
      });
    } else if (step.type === "reset") {
      if (!Array.isArray(step.targets) || !step.targets.length || !step.targets.every((target) => typeof target === "string" && own(loaded.defaults, target))) fail("unsupported_action");
    } else if (step.type === "custom_action" && step.name === "CopyToClipboard") {
      if (!plain(step.params) || typeof step.params.text !== "string") fail("unsupported_action");
      if (bytes(step.params.text) > LIMITS.textAreaBytes) fail("limit_exceeded");
    } else fail("unsupported_action");
  }
  const errors: unknown[] = [];
  const ctx = context(loaded.store, errors);
  let copyText: string | undefined;
  for (const step of (plan as unknown as ActionPlan).steps) {
    if (step.type === "set") loaded.store.set(step.target, json(evaluate(step.valueAST, ctx, { library })));
    if (step.type === "reset") for (const target of step.targets) loaded.store.set(target, json(loaded.defaults[target]), { pristine: true });
    if (step.type === "custom_action") copyText = step.params.text as string;
    stateJSON(loaded.store.getSnapshot());
  }
  return { copyText, warning: errors.length > 0 };
}

export function createSession() {
  let token: string | null = null;
  let loaded: Loaded | null = null;
  function dispose() { loaded?.store.dispose(); loaded = null; }
  function handle(input: unknown): Reply {
    const id = plain(input) && Number.isSafeInteger(input.id) ? input.id as number : null;
    const replyToken = plain(input) && typeof input.token === "string" && bytes(input.token) <= LIMITS.tokenBytes ? input.token : "";
    let candidate: Loaded | null = null;
    try {
      if (!plain(input) || id === null || !replyToken) fail("invalid_request");
      if (bytes(JSON.stringify(json(input))) + 1 > LIMITS.frameBytes) fail("limit_exceeded");
      if (token !== null && replyToken !== token) fail("stale_token");
      if (input.op === "load") {
        if (Object.keys(input).some((key) => !["id", "token", "op", "program", "state"].includes(key)) || typeof input.program !== "string") fail("invalid_request");
        const parsed = checkedProgram(input.program);
        const defaults = stateJSON(parsed.stateDeclarations);
        const persisted = stateJSON(input.state);
        if (Object.keys(persisted).some((key) => !own(defaults, key))) fail("invalid_request");
        const store = createStore();
        candidate = { parsed, defaults, store, handles: { actions: new Map(), controls: new Map(), disabled: new Set(), identities: new Map() } };
        store.initialize(defaults, persisted);
      } else if (input.op === "event") {
        if (!loaded) fail("not_loaded");
        if (Object.keys(input).some((key) => !["id", "token", "op", "target", "event", "value", "handle"].includes(key)) || typeof input.target !== "string" || bytes(input.target) > 512) fail("invalid_request");
        if (own(input, "handle") && (typeof input.handle !== "string" || input.handle !== loaded.handles.identities.get(input.target))) fail("invalid_event");
        if (loaded.handles.disabled.has(input.target)) fail("invalid_event");
        const store = createStore();
        candidate = { ...loaded, store };
        store.initialize(loaded.defaults, loaded.store.getSnapshot());
      } else fail("invalid_request");
      let copyText: string | undefined;
      let warning = false;
      if (input.op === "event") {
        const target = input.target as string;
        if (input.event === "change") {
          const control = loaded!.handles.controls.get(target);
          if (!control) fail("invalid_event");
          const errors: unknown[] = [];
          const value = controlValue(control, input.value);
          const ctx = context(candidate!.store, errors);
          // Core 1.0's extraScope lookup uses ??, so a null $value otherwise
          // falls through to an undeclared state key and becomes undefined.
          // Preserve the control's explicit blank/null at that fallback too.
          ctx.getState = (name) => name === "$value" ? value : candidate!.store.get(name);
          resolveStateField(target, control.binding, candidate!.store, ctx, () => undefined, () => fail("invalid_event")).setValue(value);
          warning = errors.length > 0;
        } else if (input.event === "click") {
          if (own(input, "value") && input.value !== null) fail("invalid_event");
          const plan = loaded!.handles.actions.get(target);
          if (!plan) fail("invalid_event");
          const result = action(candidate!, plan);
          copyText = result.copyText;
          warning = result.warning;
        } else fail("invalid_event");
      }
      const result = render(candidate!);
      const reply: Reply = { id, token: replyToken, ok: true, tree: result.tree, state: result.state, ...(copyText !== undefined ? { copyText } : {}),
        ...(warning || result.warning ? { warning: "Some values could not be calculated." } : {}) };
      if (bytes(JSON.stringify(reply)) + 1 > LIMITS.frameBytes) fail("limit_exceeded");
      candidate!.handles = result.handles;
      loaded?.store.dispose();
      loaded = candidate;
      token = replyToken;
      return reply;
    } catch (error) {
      candidate?.store.dispose();
      return { id, token: replyToken, ok: false, error: error instanceof WorkerError ? error.code : "runtime_error" };
    }
  }
  return { handle, dispose };
}

// JSON-lines only: no file, credential, provider, network, module loading or
// JavaScript-evaluation APIs are reachable from program/state/event input.
// The native parent MUST watchdog each request and cap the child heap externally.
export function runCLI() {
  const session = createSession();
  let pending = Buffer.alloc(0);
  let discarding = false;
  let outputBytes = 0;
  const queue: Buffer[] = [];
  let writing = false;
  const badFrame: Reply = { id: null, token: "", ok: false, error: "invalid_request" };
  function flush() {
    if (writing) return;
    while (queue.length) {
      const frame = queue.shift()!;
      outputBytes -= frame.length;
      if (!process.stdout.write(frame)) {
        writing = true;
        process.stdin.pause();
        process.stdout.once("drain", () => { writing = false; flush(); if (!writing) process.stdin.resume(); });
        return;
      }
    }
  }
  function send(reply: Reply) {
    const frame = Buffer.from(JSON.stringify(reply) + "\n");
    if (frame.length > LIMITS.frameBytes || outputBytes + frame.length > LIMITS.frameBytes) { process.stdin.destroy(); process.exitCode = 1; return; }
    queue.push(frame); outputBytes += frame.length; flush();
  }
  process.stdin.on("data", (chunk: Buffer) => {
    let start = 0;
    for (let i = 0; i < chunk.length; i++) {
      if (chunk[i] !== 10) continue;
      const part = chunk.subarray(start, i);
      if (!discarding && pending.length + part.length + 1 <= LIMITS.frameBytes) {
        const line = Buffer.concat([pending, part]);
        try {
          const decoded = new TextDecoder("utf-8", { fatal: true }).decode(line);
          send(session.handle(JSON.parse(decoded)));
        } catch { send(badFrame); }
      } else send({ id: null, token: "", ok: false, error: "limit_exceeded" });
      pending = Buffer.alloc(0); discarding = false; start = i + 1;
    }
    if (!discarding) {
      const tail = chunk.subarray(start);
      if (pending.length + tail.length + 1 > LIMITS.frameBytes) { pending = Buffer.alloc(0); discarding = true; }
      else pending = Buffer.concat([pending, tail]);
    }
  });
  process.stdin.on("end", () => {
    if (discarding) send({ id: null, token: "", ok: false, error: "limit_exceeded" });
    else if (pending.length) send(badFrame); // A frame requires its newline.
    session.dispose();
  });
  process.stdin.on("error", () => { session.dispose(); process.exitCode = 1; });
  process.stdout.on("error", () => { session.dispose(); process.stdin.destroy(); process.exitCode = 1; });
}

if (require.main === module) runCLI();
