// Upstream schemas/descriptions unchanged; DOM rendering omitted. See upstream-inputs.json.
import { defineComponent } from "@openuidev/lang-core";
import { z } from "zod/v4";
import { children, color, length } from "./style";

const paint = { fill: color.optional(), stroke: color.optional(), strokeWidth: z.number().optional(), opacity: z.number().optional() };
export const Svg = defineComponent({
  name: "Svg",
  props: z.object({
    children,
    viewBox: z.string(),
    width: length.optional(),
    height: length.optional(),
  }),
  description: "A drawing for steps, parts, mechanisms, diagrams and layouts. Scales to its width; its shapes take expressions, so state can move them.",
});
export const Circle = defineComponent({
  name: "Circle",
  props: z.object({ cx: z.number(), cy: z.number(), r: z.number(), ...paint }),
  description: "",
});
export const Ellipse = defineComponent({
  name: "Ellipse",
  props: z.object({ cx: z.number(), cy: z.number(), rx: z.number(), ry: z.number(), ...paint }),
  description: "",
});
export const Rect = defineComponent({
  name: "Rect",
  props: z.object({ x: z.number(), y: z.number(), width: z.number(), height: z.number(), ...paint, rx: z.number().optional() }),
  description: "",
});
export const Line = defineComponent({
  name: "Line",
  props: z.object({ x1: z.number(), y1: z.number(), x2: z.number(), y2: z.number(), stroke: color.optional(), strokeWidth: z.number().optional(), opacity: z.number().optional() }),
  description: "",
});
export const Path = defineComponent({
  name: "Path",
  props: z.object({ d: z.string(), ...paint }),
  description: "",
});
export const Polyline = defineComponent({
  name: "Polyline",
  props: z.object({ points: z.string(), stroke: color.optional(), strokeWidth: z.number().optional(), fill: color.optional(), opacity: z.number().optional() }),
  description: 'points like "0,0 10,5 20,0".',
});
export const Polygon = defineComponent({
  name: "Polygon",
  props: z.object({ points: z.string(), ...paint }),
  description: "",
});
export const G = defineComponent({
  name: "G",
  props: z.object({ children, transform: z.string().optional(), opacity: z.number().optional() }),
  description: 'Group; transform like "rotate(30 50 50)" or "translate(10 0)".',
});
export const SvgText = defineComponent({
  name: "SvgText",
  props: z.object({
    text: z.string(),
    x: z.number(),
    y: z.number(),
    size: z.number().optional(),
    fill: color.optional(),
    anchor: z.enum(["start", "middle", "end"]).optional(),
    weight: z.enum(["normal", "medium", "semibold"]).optional(),
  }),
  description: "",
});
export const svgComponents = [Svg, Circle, Ellipse, Rect, Line, Path, Polyline, Polygon, G, SvgText];
