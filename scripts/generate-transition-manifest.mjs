import { writeFile } from "node:fs/promises";
import transitions from "gl-transitions";

const names = transitions.map(({ name }) => name).sort((left, right) => left.localeCompare(right));
const metadata = transitions
  .map(({ name, paramsTypes = {}, defaultParams = {} }) => ({ name, paramsTypes, defaultParams }))
  .sort((left, right) => left.name.localeCompare(right.name));
await writeFile(new URL("../transition-metadata.json", import.meta.url), `${JSON.stringify(metadata, null, 2)}\n`);
console.log(`Generated metadata for ${names.length} GL transitions.`);
