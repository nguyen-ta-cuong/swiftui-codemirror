import { createHash } from "node:crypto";
import { readdir, readFile, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import path from "node:path";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const entryPath = path.join(scriptDirectory, "codemirror.js");
const lockPath = path.join(scriptDirectory, "package-lock.json");
const outputPath = path.resolve(
  scriptDirectory,
  "../Sources/CodeMirror/web.bundle/THIRD-PARTY-NOTICES.md"
);
const lockText = await readFile(lockPath, "utf8");
const lockfile = JSON.parse(lockText);
const lockedPackages = Object.entries(lockfile.packages ?? {})
  .filter(([packagePath]) => packagePath.startsWith("node_modules/"))
  .map(([packagePath, metadata]) => ({
    packagePath,
    name: packagePath.slice("node_modules/".length),
    version: metadata.version ?? "unknown",
    license: metadata.license ?? "UNKNOWN",
    resolved: metadata.resolved ?? "not listed",
    integrity: metadata.integrity ?? "not listed",
    optional: metadata.optional === true,
  }));

const compareStrings = (left, right) => (left < right ? -1 : left > right ? 1 : 0);
const escapeTableValue = value => String(value).replaceAll("|", "\\|");
const packageRootMarker = `${path.sep}node_modules${path.sep}`;
const importPatterns = [
  /\bimport\s+(?:[^"'()]+?\s+from\s+)?["']([^"']+)["']/g,
  /\bexport\s+(?:[^"'()]+?\s+from\s+)?["']([^"']+)["']/g,
  /\bimport\s*\(\s*["']([^"']+)["']\s*\)/g,
  /\brequire\s*\(\s*["']([^"']+)["']\s*\)/g,
];

function packageRootFor(filePath) {
  const markerIndex = filePath.lastIndexOf(packageRootMarker);
  if (markerIndex < 0) return null;
  const packageDirectory = filePath.slice(0, markerIndex + packageRootMarker.length);
  const packagePath = filePath.slice(markerIndex + packageRootMarker.length);
  const segments = packagePath.split(path.sep);
  const packageSegments = segments[0].startsWith("@")
    ? segments.slice(0, 2)
    : segments.slice(0, 1);
  if (packageSegments.some(segment => segment.length === 0)) return null;
  return {
    name: packageSegments.join("/"),
    root: path.join(packageDirectory, ...packageSegments),
  };
}

function importedSpecifiers(source) {
  const specifiers = new Set();
  for (const pattern of importPatterns) {
    pattern.lastIndex = 0;
    for (const match of source.matchAll(pattern)) {
      specifiers.add(match[1]);
    }
  }
  return [...specifiers].sort(compareStrings);
}

function resolveImport(specifier, sourcePath) {
  if (specifier.startsWith("node:")) return null;
  try {
    return createRequire(sourcePath).resolve(specifier);
  } catch (error) {
    throw new Error(`Unable to resolve ${specifier} imported by ${sourcePath}: ${error.message}`);
  }
}

async function collectRuntimePackages() {
  const visitedFiles = new Set();
  const runtimeRoots = new Map();
  const pendingFiles = [entryPath];
  while (pendingFiles.length > 0) {
    const sourcePath = pendingFiles.shift();
    if (visitedFiles.has(sourcePath)) continue;
    visitedFiles.add(sourcePath);
    const owner = packageRootFor(sourcePath);
    if (owner) runtimeRoots.set(owner.root, owner);
    const extension = path.extname(sourcePath).toLowerCase();
    if ([".json", ".node", ".wasm"].includes(extension)) continue;
    const source = await readFile(sourcePath, "utf8");
    for (const specifier of importedSpecifiers(source)) {
      const resolvedPath = resolveImport(specifier, sourcePath);
      if (!resolvedPath) continue;
      if (!resolvedPath.startsWith(`${scriptDirectory}${path.sep}`)) {
        throw new Error(`Resolved runtime import outside codemirrorjs: ${resolvedPath}`);
      }
      pendingFiles.push(resolvedPath);
    }
  }
  return [...runtimeRoots.values()].sort((left, right) => compareStrings(left.name, right.name));
}

function matchingLockEntries(name, version) {
  const suffix = `/node_modules/${name}`;
  return lockedPackages
    .filter(entry =>
      (entry.packagePath === `node_modules/${name}` || entry.packagePath.endsWith(suffix))
      && entry.version === version
    )
    .sort((left, right) => compareStrings(left.packagePath, right.packagePath));
}

const noticeNamePattern = /^(?:license|copying|notice)(?:[._-].*)?$/i;
const noticePriority = name => {
  const normalized = name.toLowerCase();
  if (normalized === "license") return 0;
  if (normalized.startsWith("license")) return 1;
  if (normalized === "copying") return 2;
  if (normalized.startsWith("copying")) return 3;
  if (normalized === "notice") return 4;
  return 5;
};

async function readRuntimeNotice(packageInfo) {
  const candidates = (await readdir(packageInfo.root))
    .filter(name => noticeNamePattern.test(name))
    .sort((left, right) => {
      const priorityDifference = noticePriority(left) - noticePriority(right);
      return priorityDifference || compareStrings(left.toLowerCase(), right.toLowerCase());
    });
  const notices = [];
  for (const candidate of candidates) {
    try {
      const text = (await readFile(path.join(packageInfo.root, candidate), "utf8"))
        .replace(/\r\n?/g, "\n")
        .trimEnd();
      if (text.length > 0) {
        notices.push({ fileName: candidate, text });
      }
    } catch {}
  }
  if (notices.length === 0) {
    throw new Error(
      `Missing runtime license/notice text for ${packageInfo.name}@${packageInfo.version} at ${packageInfo.root}`
    );
  }
  return {
    fileNames: notices.map(notice => notice.fileName),
    text: notices.map(notice =>
      notices.length === 1 ? notice.text : `===== ${notice.fileName} =====\n${notice.text}`
    ).join("\n\n"),
  };
}

async function lockMetadataForRuntime(rootInfo) {
  const packageJSON = JSON.parse(await readFile(path.join(rootInfo.root, "package.json"), "utf8"));
  const matches = matchingLockEntries(packageJSON.name ?? rootInfo.name, packageJSON.version);
  if (matches.length === 0) {
    throw new Error(
      `Installed runtime package ${rootInfo.name}@${packageJSON.version} is absent from package-lock.json`
    );
  }
  const metadata = matches[0];
  const notice = await readRuntimeNotice({
    ...rootInfo,
    name: packageJSON.name ?? rootInfo.name,
    version: packageJSON.version,
  });
  return {
    ...metadata,
    name: packageJSON.name ?? rootInfo.name,
    version: packageJSON.version,
    license: metadata.license === "UNKNOWN"
      ? packageJSON.license ?? "UNKNOWN"
      : metadata.license,
    lockPath: metadata.packagePath,
    noticeFiles: notice.fileNames,
    noticeText: notice.text,
  };
}

function licenseInventory(packages) {
  const counts = new Map();
  for (const packageInfo of packages) {
    counts.set(packageInfo.license, (counts.get(packageInfo.license) ?? 0) + 1);
  }
  return [...counts.entries()]
    .sort(([left], [right]) => compareStrings(left, right))
    .map(([license, count]) => `${license} (${count})`)
    .join(", ");
}

function codeFenceFor(text) {
  const longestRun = Math.max(0, ...[...text.matchAll(/`+/g)].map(match => match[0].length));
  return "`".repeat(Math.max(3, longestRun + 1));
}

const runtimeRoots = await collectRuntimePackages();
const runtimePackages = [];
for (const rootInfo of runtimeRoots) {
  runtimePackages.push(await lockMetadataForRuntime(rootInfo));
}
runtimePackages.sort((left, right) =>
  compareStrings(`${left.name}@${left.version}`, `${right.name}@${right.version}`)
);

const runtimeLockPaths = new Set(runtimePackages.map(packageInfo => packageInfo.lockPath));
const lockHash = createHash("sha256").update(lockText).digest("hex");
const noticeSections = runtimePackages.flatMap(packageInfo => {
  const fence = codeFenceFor(packageInfo.noticeText);
  return [
    `### ${packageInfo.name}@${packageInfo.version}`,
    "",
    `- License metadata: ${packageInfo.license}`,
    `- Notice files: ${packageInfo.noticeFiles.join(", ")}`,
    `- Locked source: ${packageInfo.resolved}`,
    `- Integrity: ${packageInfo.integrity}`,
    "",
    `${fence}text`,
    packageInfo.noticeText,
    fence,
    "",
  ];
});
const inventoryRows = lockedPackages
  .sort((left, right) => compareStrings(left.name, right.name) || compareStrings(left.version, right.version))
  .map(packageInfo => {
    const scope = runtimeLockPaths.has(packageInfo.packagePath)
      ? "bundled-runtime (notice above)"
      : packageInfo.optional
        ? "not-bundled optional/build-only"
        : "not-bundled build dependency";
    return `| ${escapeTableValue(packageInfo.name)} | ${escapeTableValue(packageInfo.version)} | ${scope} | ${escapeTableValue(packageInfo.license)} | ${escapeTableValue(packageInfo.resolved)} | ${escapeTableValue(packageInfo.integrity)} |`;
  });
const lines = [
  "# Third-Party Notices",
  "",
  "This notice is generated by `npm run generate-notices` from the committed `codemirrorjs/package-lock.json` and the locked installed package contents.",
  "Bundled runtime packages include their actual installed license/notice text below. Generation fails if a bundled runtime package is missing that text.",
  "Packages present only for build tooling or optional platform resolution remain in the inventory, explicitly marked not-bundled; their metadata is not represented as a runtime notice.",
  "",
  `Package-lock SHA-256: ${lockHash}`,
  `Locked package count: ${lockedPackages.length}`,
  `Bundled runtime package count: ${runtimePackages.length}`,
  `Not-bundled locked package count: ${lockedPackages.length - runtimePackages.length}`,
  `Bundled runtime license inventory: ${licenseInventory(runtimePackages)}`,
  "",
  "## Bundled runtime dependency notices",
  "",
  ...noticeSections,
  "## Locked package inventory",
  "",
  "| Package | Version | Scope | Lock license metadata | Locked source | Integrity |",
  "| --- | --- | --- | --- | --- | --- |",
  ...inventoryRows,
  "",
  "The runtime notice text is copied from the installed package named in each section. The lockfile metadata and integrity digests are retained for reproducible review; rerun the generator after any dependency or lockfile change.",
];
await writeFile(outputPath, `${lines.join("\n")}\n`, "utf8");
