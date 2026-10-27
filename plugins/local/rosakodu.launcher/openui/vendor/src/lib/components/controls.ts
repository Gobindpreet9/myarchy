// Upstream schemas/descriptions unchanged; React rendering omitted. See upstream-inputs.json.
import { action, defineComponent, markReactive } from "@openuidev/lang-core";
import { z } from "zod/v4";
import { children, color, option, radiusSchema } from "./style";

// Same schema marker as the upstream React adapter; no React dependency.
function reactive<T>(schema: T): T { markReactive(schema); return schema; }

export const Button = defineComponent({
  name: "Button",
  props: z.object({
    label: z.string(),
    action: action().optional(),
    variant: z.enum(["solid", "outline", "soft", "ghost"]).optional(),
    color: z.enum(["primary", "danger", "success"]).optional(),
    size: z.enum(["sm", "md", "lg"]).optional(),
    icon: z.string().optional(),
    disabled: z.boolean().optional(),
    block: z.boolean().optional(),
  }),
  description: "icon is a lucide name.",
});
export const IconButton = defineComponent({
  name: "IconButton",
  props: z.object({
    icon: z.string(),
    action: action().optional(),
    label: z.string().optional(),
    variant: z.enum(["outline", "ghost", "solid"]).optional(),
  }),
  description: "Round icon-only button; label is read aloud.",
});
export const Pressable = defineComponent({
  name: "Pressable",
  props: z.object({
    children,
    action: action().optional(),
    selected: z.boolean().optional(),
    padding: z.number().optional(),
    background: color.optional(),
    radius: radiusSchema.optional(),
  }),
  description: "Makes any content clickable, such as a tile or a swatch.",
});
export const Input = defineComponent({
  name: "Input",
  props: z.object({
    value: reactive(z.union([z.string(), z.number()])),
    label: z.string().optional(),
    type: z.enum(["text", "number"]).optional(),
    placeholder: z.string().optional(),
  }),
  description: "Text or number field; a number field stores numbers.",
});
export const TextArea = defineComponent({
  name: "TextArea",
  props: z.object({
    value: reactive(z.string()),
    label: z.string().optional(),
    placeholder: z.string().optional(),
    rows: z.number().optional(),
  }),
  description: "",
});
const options = z.array(option);
export const Select = defineComponent({
  name: "Select",
  props: z.object({
    value: reactive(z.string()),
    options,
    label: z.string().optional(),
    placeholder: z.string().optional(),
  }),
  description: "Dropdown, for long option lists.",
});
export const SegmentedControl = defineComponent({
  name: "SegmentedControl",
  props: z.object({ value: reactive(z.string()), options, block: z.boolean().optional() }),
  description: "2 to 4 short choices in a row.",
});
export const Slider = defineComponent({
  name: "Slider",
  props: z.object({
    value: reactive(z.number()),
    min: z.number(),
    max: z.number(),
    step: z.number().optional(),
    label: z.string().optional(),
    unit: z.string().optional(),
    marks: z.array(z.object({ value: z.number(), label: z.string() })).optional(),
  }),
  description: 'Shows label and value; unit like "%" or "$" formats the value.',
});
export const Checkbox = defineComponent({
  name: "Checkbox",
  props: z.object({ checked: reactive(z.boolean()), label: z.string(), lineThrough: z.boolean().optional() }),
  description: "lineThrough strikes the label when checked, for to-do lists.",
});
const choice = z.union([z.string(), z.object({ value: z.string(), label: z.string(), description: z.string().optional() })]);
export const RadioGroup = defineComponent({
  name: "RadioGroup",
  props: z.object({
    value: reactive(z.string()),
    options: z.array(choice),
    label: z.string().optional(),
    variant: z.enum(["list", "pills", "cards"]).optional(),
  }),
  description: "pills for short choices; cards for choices that need a description line.",
});
