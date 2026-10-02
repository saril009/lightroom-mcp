// Copies the Lightroom plug-in into Lightroom's Modules folder so it survives
// moving/removing this repository, and prints the one-time enable steps.
//
// Usage:  node src/install-plugin.mjs [--dest <dir>] [--uninstall] [--dry-run]

import { cpSync, existsSync, mkdirSync, rmSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const PLUGIN_NAME = 'LightroomMCPBridge.lrplugin';
const sourceDir = path.join(root, 'plugin', PLUGIN_NAME);

function defaultModulesDir() {
  if (process.platform === 'darwin') {
    return path.join(os.homedir(), 'Library', 'Application Support', 'Adobe', 'Lightroom', 'Modules');
  }
  if (process.platform === 'win32') {
    const appData = process.env.APPDATA
      ?? path.join(os.homedir(), 'AppData', 'Roaming');
    return path.join(appData, 'Adobe', 'Lightroom', 'Modules');
  }
  return null;
}

function parseArgs(argv) {
  const out = { dest: null, uninstall: false, dryRun: false };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--dest') out.dest = argv[++i] ?? null;
    else if (arg === '--uninstall') out.uninstall = true;
    else if (arg === '--dry-run') out.dryRun = true;
    else if (arg === '--help' || arg === '-h') out.help = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  return out;
}

const args = parseArgs(process.argv.slice(2));

if (args.help) {
  console.log(`Installs the ${PLUGIN_NAME} plug-in into Lightroom's Modules folder.

  --dest <dir>   Install into <dir> instead of the default Lightroom Modules folder
  --uninstall    Remove a previously installed copy
  --dry-run      Show what would happen without touching anything
`);
  process.exit(0);
}

const destDir = args.dest ?? defaultModulesDir();
if (!destDir) {
  console.error('Could not determine the Lightroom Modules folder on this platform;'
    + ' pass --dest <dir> (for example a folder you will add from the Plug-in Manager).');
  process.exit(1);
}
const dest = path.join(destDir, PLUGIN_NAME);

if (args.uninstall) {
  if (!existsSync(dest)) {
    console.log(`Nothing to remove: ${dest} does not exist.`);
    process.exit(0);
  }
  if (args.dryRun) {
    console.log(`Would remove ${dest}`);
    process.exit(0);
  }
  rmSync(dest, { recursive: true, force: true });
  console.log(`Removed ${dest}`);
  process.exit(0);
}

if (!existsSync(sourceDir)) {
  console.error(`Plug-in source not found at ${sourceDir}`);
  process.exit(1);
}

if (args.dryRun) {
  console.log(`Would copy ${sourceDir} -> ${dest}`);
  process.exit(0);
}

mkdirSync(destDir, { recursive: true });
// Copy the whole folder (cpSync on a directory copies its contents into dest).
rmSync(dest, { recursive: true, force: true });
cpSync(sourceDir, dest, { recursive: true });

console.log(`Installed ${PLUGIN_NAME} to:\n  ${dest}
`);
console.log(`Enable it once in Lightroom Classic:
  1. File > Plug-in Manager...
  2. Click "Add Plug-in..." and choose:
       ${dest}
  3. Make sure it is enabled, then close the manager.

From then on the bridge starts automatically with Lightroom. Check its status any
time in File > Plug-in Manager (select ${PLUGIN_NAME}), or run the "status" tool.`);
