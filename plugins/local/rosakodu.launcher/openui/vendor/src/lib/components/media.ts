// Only Icon's upstream schema/description; no media/network code. See upstream-inputs.json.
import { defineComponent } from "@openuidev/lang-core";
import { z } from "zod/v4";
import { color } from "./style";

export const Icon = defineComponent({
  name: "Icon",
  props: z.object({
    name: z.string(),
    size: z.enum(["sm", "md", "lg", "xl"]).optional(),
    color: color.optional(),
  }),
  description: 'Lucide icon by name, e.g. "map-pin".',
});
