// Upstream action definition only; native host performs the copy. See upstream-inputs.json.
import { defineAction } from "@openuidev/lang-core";
import { z } from "zod/v4";

export const CopyToClipboard = defineAction({
  name: "CopyToClipboard",
  description: "Copy text to the clipboard, e.g. a shopping list built with @Join",
  params: z.object({ text: z.string() }),
});
