// Upstream schemas/descriptions unchanged; React rendering omitted. See upstream-inputs.json.
import { defineComponent } from "@openuidev/lang-core";
import { z } from "zod/v4";
import { children, color } from "./style";

export const Title = defineComponent({
  name: "Title",
  props: z.object({
    text: z.string(),
    size: z.enum(["sm", "md", "lg", "xl", "2xl", "3xl"]).optional(),
    color: color.optional(),
  }),
  description: "Heading; md for a card title, lg for a section, 2xl for a big number.",
});
const richText = z.union([z.string(), children]);
export const Text = defineComponent({
  name: "Text",
  props: z.object({
    text: richText,
    size: z.enum(["xs", "sm", "md", "lg"]).optional(),
    color: color.optional(),
    weight: z.enum(["normal", "medium", "semibold"]).optional(),
    italic: z.boolean().optional(),
    lineThrough: z.boolean().optional(),
    tabularNums: z.boolean().optional(),
    maxLines: z.number().optional(),
  }),
  description: "Paragraph; supports **bold**, *italic*, `code` and [links](https://…). text may be a list mixing strings and inline components: [Icon(\"clock\", \"sm\"), \" 25 min · \", Badge(\"Easy\")].",
});
export const Caption = defineComponent({
  name: "Caption",
  props: z.object({ text: z.string(), color: color.optional() }),
  description: "Small secondary text.",
});
export const Label = defineComponent({
  name: "Label",
  props: z.object({ text: z.string() }),
  description: "Field or group label.",
});
export const Badge = defineComponent({
  name: "Badge",
  props: z.object({
    text: z.string(),
    color: z.enum(["neutral", "info", "success", "warning", "danger", "purple", "pink"]).optional(),
    icon: z.string().optional(),
  }),
  description: "Pill tag; icon is an optional leading lucide name.",
});
