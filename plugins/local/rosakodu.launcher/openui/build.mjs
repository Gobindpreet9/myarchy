import { build } from "esbuild";
import { createRequire } from "node:module";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
import path from "node:path";

const here = fileURLToPath(new URL(".", import.meta.url));
const root = here;
const dist = path.join(here, "dist");
const require = createRequire(import.meta.url);
const pins = { "@openuidev/lang-core": "1.0.0", zod: "4.6.6", esbuild: "0.28.2" };
for (const [name, version] of Object.entries(pins)) {
  const installed = JSON.parse(await readFile(path.join(root, "node_modules", name, "package.json"), "utf8"));
  if (installed.version !== version) throw new Error(`Expected ${name} ${version}`);
}
const coreVersion = pins["@openuidev/lang-core"];
const corePath = path.join(root, "node_modules/@openuidev/lang-core/dist/index.mjs");
const coreSource = await readFile(corePath, "utf8");
const coreHash = "9e77ef9228181586002cb0b0d8a409a9e08dfa663099009b87a38d55b94bce4a";
const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");
if (sha256(coreSource) !== coreHash) throw new Error("Qualified upstream core source changed");

// The sole core adaptation removes optional analytics, not language semantics.
// Removing its import also prevents the public analytics key/CI detector from
// entering the native package. Preserve all legal comments and license files.
const telemetryStart = coreSource.indexOf("//#region src/telemetry/runtime.ts\n");
const telemetryEnd = coreSource.indexOf("//#region src/parser/validate-library.ts\n");
const telemetryImport = /^import \{[^\n]+\} from "\.\/shared-[^"\n]+\.mjs";\n/;
if (telemetryStart < 0 || telemetryEnd <= telemetryStart || !telemetryImport.test(coreSource)) {
  throw new Error("Upstream telemetry boundaries changed");
}
const nativeCore = (coreSource.slice(0, telemetryStart) + `
function recordSystemPromptGeneration() {}
function prepareParserParseTelemetry() {}
function captureParserParseResult() {}
function captureParserParseException() {}
` + coreSource.slice(telemetryEnd)).replace(telemetryImport, "");
function pureFunctions(external) {
  return {
    name: "pure-functions-use-core",
    setup(builder) {
      builder.onResolve({ filter: /^@openuidev\/react-lang$/ }, async (args) => {
        if (!args.importer.startsWith(path.join(root, "vendor/src/lib/functions/"))) {
          throw new Error("React is not permitted in the native worker");
        }
        return external ? { path: "@openuidev/lang-core", external: true }
          : builder.resolve("@openuidev/lang-core", { resolveDir: root, kind: args.kind });
      });
      if (!external) builder.onLoad({ filter: /[/\\]@openuidev[/\\]lang-core[/\\]dist[/\\]index\.mjs$/ }, () => ({
        contents: nativeCore, loader: "js", resolveDir: path.dirname(corePath),
      }));
    },
  };
}
// The build/test-only reference uses the untouched installed core. Force even
// inherited opt-in telemetry off before requiring it or generating the prompt.
process.env.OPENUI_TELEMETRY_DISABLED = "1";
process.env.DO_NOT_TRACK = "1";
await mkdir(dist, { recursive: true });

await build({
  absWorkingDir: root, entryPoints: [path.join(here, "spec-entry.ts")],
  outfile: path.join(dist, "native-spec.cjs"), bundle: true,
  platform: "node", format: "cjs", target: "node24", packages: "external",
  plugins: [pureFunctions(true)], logLevel: "warning",
});
const spec = require(path.join(dist, "native-spec.cjs"));
if (spec.functionNames.length !== 59) throw new Error("Expected the 59 actual upstream functions");
await Promise.all([
  writeFile(path.join(root, "native-schema.json"), JSON.stringify(spec.schema)),
  writeFile(path.join(root, "native-reactive.json"), JSON.stringify(spec.reactiveProps)),
  writeFile(path.join(root, "native-system-prompt.txt"), spec.prompt),
  writeFile(path.join(root, "native-examples.json"), JSON.stringify(spec.examples, null, 2) + "\n"),
]);

const runtime = await build({
  absWorkingDir: root, entryPoints: [path.join(here, "worker.ts")],
  outfile: path.join(root, "native-worker.cjs"), bundle: true, minify: true,
  platform: "node", format: "cjs", target: "node24", metafile: true,
  legalComments: "linked", logLevel: "warning",
  banner: { js: "/* Native OpenUI bundle. Complete MIT notices: THIRD_PARTY_NOTICES.txt and licenses/. */" },
  plugins: [pureFunctions(false)],
});
const inputs = Object.keys(runtime.metafile.inputs);
if (inputs.some((name) => /(?:node_modules\/(?:react(?:-dom)?\/|next\/|ci-info\/|@openuidev\/react-lang\/))|src\/lib\/components\/|shared-[^/]+\.mjs$/.test(name))) {
  throw new Error("React, components or telemetry leaked into runtime");
}
const imports = Object.values(runtime.metafile.outputs).flatMap((output) => output.imports);
if (imports.some((item) => item.path !== "node:crypto")) throw new Error("Runtime permits only the static Node crypto builtin, no external packages");
const bundle = await readFile(path.join(root, "native-worker.cjs"), "utf8");
if (/\bfetch\s*\(|getBuiltinModule|OPENUI_POSTHOG|cloudfront\.net|phc_/.test(bundle)) {
  throw new Error("Network or telemetry code leaked into runtime");
}
await writeFile(path.join(root, "native-worker.meta.json"), JSON.stringify(runtime.metafile, null, 2) + "\n");
const artifacts = {};
for (const name of ["native-worker.cjs", "native-system-prompt.txt", "native-examples.json", "native-schema.json", "native-reactive.json", "native-worker.meta.json"]) {
  const bytes = await readFile(path.join(root, name));
  artifacts[name] = { bytes: bytes.length, sha256: sha256(bytes) };
}
const { LIMITS } = require(path.join(root, "native-worker.cjs"));
await writeFile(path.join(root, "native-metadata.json"), JSON.stringify({
  protocol: 1, coreVersion, dependencyVersions: pins,
  upstreamRevision: "03213439358bf3408ad61a46ec9e3230c5572e48",
  upstreamCoreSha256: coreHash, runtimeTelemetry: false,
  componentNames: spec.componentNames,
  functionNames: spec.functionNames, actions: ["Set", "Reset", "CopyToClipboard"],
  reactiveProps: spec.reactiveProps, limits: LIMITS, runtimeReactInputs: 0,
  exampleAdaptations: "All three existing launcher examples unchanged, including upstream Icon and SVG. No behavior omitted.",
  artifacts,
}, null, 2) + "\n");
console.log(JSON.stringify({ coreVersion, components: spec.componentNames.length, functions: spec.functionNames.length, artifacts }, null, 2));
