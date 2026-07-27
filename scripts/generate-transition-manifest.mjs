import { writeFile } from "node:fs/promises";
import transitions from "gl-transitions";

const names = transitions.map(({ name }) => name).sort((left, right) => left.localeCompare(right));
const output = `window.GL_TRANSITION_NAMES = ${JSON.stringify(names, null, 2)};\n`;

await writeFile(new URL("../transition-manifest.js", import.meta.url), output);
await writeFile(new URL("../transition-manifest.json", import.meta.url), `${JSON.stringify(names, null, 2)}\n`);
console.log(`Generated ${names.length} GL transition names.`);
