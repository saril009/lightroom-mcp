// Syntax-checks the Lightroom Lua plug-in (Lua 5.1) and the Node sources.
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import luaparse from 'luaparse';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
let failures = 0;

function walk(dir, match, out = []) {
  for (const name of readdirSync(dir)) {
    const full = path.join(dir, name);
    if (statSync(full).isDirectory()) walk(full, match, out);
    else if (match(name)) out.push(full);
  }
  return out;
}

const luaFiles = walk(path.join(root, 'plugin'), (n) => n.endsWith('.lua'));
for (const file of luaFiles) {
  try {
    luaparse.parse(readFileSync(file, 'utf8'), { luaVersion: '5.1' });
    console.log(`lua  ok   ${path.relative(root, file)}`);
  } catch (err) {
    failures++;
    console.error(`lua  FAIL ${path.relative(root, file)}\n     ${err.message}`);
  }
}

const jsFiles = [...walk(path.join(root, 'src'), (n) => n.endsWith('.mjs')),
  ...walk(path.join(root, 'scripts'), (n) => n.endsWith('.mjs'))];
for (const file of jsFiles) {
  try {
    execFileSync(process.execPath, ['--check', file], { stdio: 'pipe' });
    console.log(`js   ok   ${path.relative(root, file)}`);
  } catch (err) {
    failures++;
    console.error(`js   FAIL ${path.relative(root, file)}\n     ${err.stderr}`);
  }
}

// The JSON module has no Lightroom dependencies, so exercise it for real when
// a Lua interpreter is available (Lightroom itself runs Lua 5.1).
const lua = ['lua5.1', 'lua5.4', 'lua', 'luajit'].find((bin) => {
  try {
    execFileSync(bin, ['-v'], { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
});
if (lua) {
  try {
    execFileSync(lua, ['scripts/test-json.lua'], { cwd: root, stdio: 'inherit' });
    console.log(`lua  ok   scripts/test-json.lua (via ${lua})`);
  } catch {
    failures++;
    console.error('lua  FAIL scripts/test-json.lua');
  }
} else {
  console.log('lua  skip scripts/test-json.lua (no Lua interpreter found)');
}

console.log(failures ? `\n${failures} file(s) failed` : '\nAll files parse cleanly.');
process.exit(failures ? 1 : 0);
