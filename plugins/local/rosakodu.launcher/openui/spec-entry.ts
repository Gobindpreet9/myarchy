import { createLibrary, evaluate, isReactiveSchema, parseExpression, tokenize } from "@openuidev/lang-core";
import { CopyToClipboard } from "./vendor/src/lib/actions";
import { functions } from "./vendor/src/lib/functions";
import {
  Button, Checkbox, IconButton, Input, Pressable, RadioGroup,
  SegmentedControl, Select, Slider, TextArea,
} from "./vendor/src/lib/components/controls";
import { Box, Card, Col, Divider, Grid, Row, Spacer } from "./vendor/src/lib/components/layout";
import { Icon } from "./vendor/src/lib/components/media";
import { svgComponents } from "./vendor/src/lib/components/svg";
import { Badge, Caption, Label, Text, Title } from "./vendor/src/lib/components/text";
import { examples } from "./examples";

// Only the upstream schemas/descriptions are needed; native QML renders them.
const library = createLibrary({
  root: "Col",
  components: [
    Col, Row, Grid, Card, Box, Divider, Spacer,
    Title, Text, Caption, Label, Badge,
    Button, IconButton, Pressable, Input, TextArea, Slider, Checkbox,
    Select, SegmentedControl, RadioGroup, Icon, ...svgComponents,
  ],
  functions,
  actions: [CopyToClipboard],
});

export const schema = library.toJSONSchema();
export const reactiveProps = Object.fromEntries(Object.entries(library.components).map(([name, def]) => [
  name, Object.entries(def.props.shape).filter(([, prop]) => isReactiveSchema(prop)).map(([key]) => key),
]).filter(([, props]) => props.length));
export const componentNames = Object.keys(library.components);
export const functionNames = functions.map((fn) => fn.name);
export { examples };

// Build/test reference only: untouched installed core + upstream definitions.
export function referenceExpression(source: string) {
  const runtimeFunctions = Object.fromEntries(functions.map((fn) => [fn.name, { ...schema.functions![fn.name], fn: fn.fn }]));
  return evaluate(parseExpression(tokenize(source)), {
    getState: () => undefined, resolveRef: () => undefined,
    functions: runtimeFunctions, actions: schema.actions,
  });
}

const generated = library.prompt({
  bindings: true,
  toolCalls: false,
  builtinFunctions: true,
  preamble: "Generate a useful local interface INSIDE the native launcher. Return ONLY a complete OpenUI Lang program, without fences or prose. The component signatures below are the complete supported subset.",
  examples: examples.map((example) => `${example.prompt}\n\n${example.program}`),
  additionalRules: [
    "No JavaScript, HTML, scripts, protocol frames, files, credentials, external resources, network calls or tools. The language evaluator is not a JavaScript execution environment.",
    "Use literal $variable defaults. Derive results, text, selection and Svg coordinates from the same state. Every control must bind its first argument to a declared $variable, optionally using a reactive assignment with $value.",
    "Only explicit local Set, Reset and CopyToClipboard actions exist. Buttons without an action do nothing. Never ask the assistant to perform arithmetic, selection, navigation or feedback.",
    "Keep within 32 KiB UTF-8 of source, 160 statements, 40 state variables, 512 rendered nodes and 64 KiB of JSON state. Prop strings must fit 4096 UTF-8 bytes, except TextArea values may use 32 KiB. Use no more than 8 steps per action.",
    "Use bounded Slider inputs for numbers and safe nonzero denominators. A blank numeric Input stores null; derive a safe value using @Default and @Clamp. Label illustrative quantities and assumptions honestly.",
    "Use Col/Row/Grid and clear hierarchy, Card only for genuinely grouped content. Spacing uses 4px steps. Svg/G children are native shapes. Text is displayed as plain text, not Markdown or links; use strings instead of rich inline components.",
    "Option values are strings. A selection must be one of its listed options. Preserve existing state variable names on revision unless a reset or a different task requires changing them.",
  ],
});

// lang-core 1.0.0 unconditionally teaches assistant/URL actions, even with
// toolCalls:false. Replace ONLY that host-policy section, never its language,
// component or function definitions. Fail the build if its boundary changes.
const start = generated.indexOf("## Action — Button Behavior");
const end = generated.indexOf("\n## ", start + 1);
if (start < 0 || end < 0) throw new Error("Upstream action prompt boundary changed");
const hostPrompt = generated.slice(0, start) + `## Action — Local Button Behavior

Pass one explicit step, e.g. Button("Next", @Set($step, $step + 1)), or Action([@Set($step, 0), @Reset($done)]) for up to 8 steps, executed in order.

- @Set($variable, value): evaluate the value against current local state and assign it.
- @Reset($variable, ...): restore the declared defaults, not persisted values.
- @CopyToClipboard(text): ask the native host to copy plain text. No automatic clipboard reads.
- Only these steps are supported. Buttons without an action are inert.

` + generated.slice(end);
export const prompt = hostPrompt.replace("(@ToAssistant, @OpenUrl, @Set, @Reset, @CopyToClipboard)", "(@Set, @Reset, @CopyToClipboard)");
if (/ToAssistant|OpenUrl|@Run\(/.test(prompt)) throw new Error("Forbidden upstream action guidance remains: " + prompt.split("\n").filter((line) => /ToAssistant|OpenUrl|@Run\(/.test(line)).join("\n"));
