import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative, resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const vpsRoot = join(root, "vps");
const required = ["terraform", "ansible", "compose", "policies", "tools", "runbooks"];
const errors = [];

for (const directory of required) {
  if (!statSafe(join(vpsRoot, directory))?.isDirectory()) {
    errors.push(`missing VPS ownership directory: ${directory}`);
  }
}

for (const file of walk(vpsRoot).filter((path) => path.endsWith(".tf"))) {
  const content = readFileSync(file, "utf8");
  if (/\bgoogle_[a-z0-9_]+\b|hashicorp\/google|source\s*=\s*"\.\.\//i.test(content)) {
    errors.push(`VPS Terraform crosses the GCP/root boundary: ${relative(root, file)}`);
  }
}

const baselinePath = join(vpsRoot, "policies", "root-gcp-baseline.sha256");
for (const line of readFileSync(baselinePath, "utf8").trim().split(/\r?\n/)) {
  const match = line.match(/^([0-9a-f]{64})\s{2}(.+)$/);
  if (!match) {
    errors.push(`invalid root baseline entry: ${line}`);
    continue;
  }
  const [, expected, name] = match;
  const file = join(root, name);
  if (!existsSync(file)) {
    errors.push(`root GCP source missing: ${name}`);
    continue;
  }
  const blob = spawnSync("git", ["show", `HEAD:${name}`], { cwd: root });
  if (blob.status !== 0) {
    errors.push(`root GCP source is not committed at HEAD: ${name}`);
    continue;
  }
  const actual = createHash("sha256").update(blob.stdout).digest("hex");
  if (actual !== expected) errors.push(`root GCP source changed outside its Change Set: ${name}`);
}

if (errors.length) {
  console.error(errors.join("\n"));
  process.exit(1);
}

console.log(`VPS boundary verified: ${required.length} ownership directories; root GCP source unchanged`);

function statSafe(path) {
  try {
    return statSync(path);
  } catch {
    return null;
  }
}

function walk(directory) {
  if (!existsSync(directory)) return [];
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = join(directory, entry.name);
    return entry.isDirectory() ? walk(path) : [path];
  });
}
