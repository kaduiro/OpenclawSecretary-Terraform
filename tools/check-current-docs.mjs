import { readFile, readdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const targets = [path.join(root, "README.md"), path.join(root, "docs", "README.md"), path.join(root, "docs", "current")];
const forbidden = [
  { pattern: /OpenAPI\s+v1\.4\.0/iu, label: "obsolete OpenAPI v1.4.0" },
  { pattern: /ALLOWED_SUBJECT/u, label: "obsolete single-subject authorization" },
  { pattern: /DATABASE_URL/u, label: "obsolete production database configuration" },
];

async function markdownFiles(target) {
  const stat = await import("node:fs/promises").then(({ stat }) => stat(target));
  if (stat.isFile()) return [target];

  const files = [];
  for (const entry of await readdir(target, { withFileTypes: true })) {
    const child = path.join(target, entry.name);
    if (entry.isDirectory()) files.push(...(await markdownFiles(child)));
    else if (entry.isFile() && entry.name.endsWith(".md")) files.push(child);
  }
  return files;
}

const files = (await Promise.all(targets.map(markdownFiles))).flat();
const errors = [];
for (const file of files) {
  const content = await readFile(file, "utf8");
  for (const rule of forbidden) {
    if (rule.pattern.test(content)) errors.push(`${path.relative(root, file)}: ${rule.label}`);
  }
}

if (errors.length) {
  throw new Error(`Current documentation check failed:\n${errors.join("\n")}`);
}

console.log(`Current documentation verified (${files.length} files).`);
