// Upstream schemas/descriptions unchanged; React rendering omitted. See upstream-inputs.json.
import { defineComponent } from "@openuidev/lang-core";
import { z } from "zod/v4";
import { children, color, length, radiusSchema } from "./style";

const align = z.enum(["start", "center", "end", "stretch"]);
const justify = z.enum(["start", "center", "end", "between"]);
export const Box = defineComponent({
  name: "Box",
  props: z.object({
    children: children.optional(),
    direction: z.enum(["row", "col"]).optional(),
    gap: z.number().optional(),
    padding: z.number().optional(),
    background: color.optional(),
    radius: radiusSchema.optional(),
    border: z.boolean().optional(),
    width: length.optional(),
    height: length.optional(),
    flex: z.number().optional(),
    align: align.optional(),
    justify: justify.optional(),
    wrap: z.boolean().optional(),
  }),
  description: "Flex container, a column by default. radius also clips the content.",
});
export const Row = defineComponent({
  name: "Row",
  props: z.object({
    children,
    gap: z.number().optional(),
    align: align.optional(),
    justify: justify.optional(),
    wrap: z.boolean().optional(),
  }),
  description: "Horizontal layout; items are vertically centered.",
});
export const Col = defineComponent({
  name: "Col",
  props: z.object({ children, gap: z.number().optional(), align: align.optional() }),
  description: "Vertical layout. Without gap it spaces blocks like an article.",
});
export const Grid = defineComponent({
  name: "Grid",
  props: z.object({
    children,
    columns: z.number().optional(),
    minChildWidth: z.number().optional(),
    gap: z.number().optional(),
  }),
  description: "Equal columns (default 2). With minChildWidth (px), columns drop on narrow screens.",
});
export const Card = defineComponent({
  name: "Card",
  props: z.object({
    children,
    variant: z.enum(["outline", "soft"]).optional(),
    padding: z.number().optional(),
    gap: z.number().optional(),
  }),
  description: "Panel with a border; soft is a filled panel for summaries.",
});
export const Divider = defineComponent({
  name: "Divider",
  props: z.object({}),
  description: "",
});
export const Spacer = defineComponent({
  name: "Spacer",
  props: z.object({}),
  description: "Fills the free space in a Row.",
});
