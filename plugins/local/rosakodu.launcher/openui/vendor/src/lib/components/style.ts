// Schema-only extraction from open-intelligent-ui; see upstream-inputs.json.
import { tagSchemaId } from "@openuidev/lang-core";
import { z } from "zod/v4";

const node = z.any();
tagSchemaId(node, "Node");
export const children = z.array(node);
export const color = z.string();
tagSchemaId(color, "Color");
export const length = z.union([z.number(), z.string()]);
tagSchemaId(length, "Length");
export const radiusSchema = z.union([z.enum(["sm", "md", "lg", "xl", "full"]), z.number()]);
tagSchemaId(radiusSchema, "Radius");
export const option = z.union([z.string(), z.object({ value: z.string(), label: z.string() })]);
