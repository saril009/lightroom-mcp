// End-to-end smoke test:
//   1. auto-enhance heuristics on synthetic JPEGs
//   2. MCP server over stdio (tool listing, status, error paths)
//   3. the HTTP bridge, driven by a simulated Lightroom plug-in
//   4. the full auto_enhance loop: render -> analyse -> apply
//
// Run:  node scripts/smoke.mjs

import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { encode } from 'jpeg-js';

import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { autoEnhance } from '../src/enhance.mjs';
import { Bridge, portFilePath } from '../src/bridge.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const PORT = 8793;
const stateDir = mkdtempSync(path.join(os.tmpdir(), 'lr-mcp-test-'));
// Any Bridge created inside this test process must use the scratch state dir,
// never the real one a running Lightroom session would be using.
process.env.LIGHTROOM_MCP_STATE_DIR = stateDir;

let passed = 0;
const failures = [];

async function step(label, fn) {
  try {
    await fn();
    passed += 1;
    console.log(`ok    ${label}`);
  } catch (err) {
    failures.push(label);
    console.error(`FAIL  ${label}\n      ${err.message}`);
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitFor(predicate, timeoutMs, what) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await sleep(25);
  }
  throw new Error(`timed out waiting for ${what}`);
}

/** Builds a flat RGBA buffer from a per-pixel callback. */
function makeImage(width, height, fn) {
  const data = new Uint8Array(width * height * 4);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const [r, g, b] = fn(x, y);
      const o = (y * width + x) * 4;
      data[o] = r; data[o + 1] = g; data[o + 2] = b; data[o + 3] = 255;
    }
  }
  return encode({ width, height, data }, 96).data;
}

// ---------------------------------------------------------------------------
// 1. auto-enhance heuristics
// ---------------------------------------------------------------------------

const darkJpeg = makeImage(64, 64, () => [42, 44, 46]); // dark, flat, dull
const blownJpeg = makeImage(64, 64, (x) => (x < 32 ? [255, 255, 255] : [90, 90, 90]));
const vividJpeg = makeImage(64, 64, () => [210, 70, 30]); // already saturated

await step('auto_enhance brightens a dark image', () => {
  const result = autoEnhance(darkJpeg, { profile: 'natural' });
  assert.equal(result.changed, true, 'expected changes');
  assert.ok(result.settings.exposure > 0.3, `exposure=${result.settings.exposure}`);
  assert.ok(result.settings.whites > 40, `whites=${result.settings.whites}`);
  assert.equal(result.settings.vibrance === undefined
    || result.settings.vibrance <= 15, true,
  `natural vibrance must stay subtle, got ${result.settings.vibrance}`);
  assert.ok(result.reason.includes('median luma'), 'explains its measurements');
});

await step('auto_enhance recovers blown highlights', () => {
  const result = autoEnhance(blownJpeg, { profile: 'natural' });
  assert.ok(result.settings.exposure < -0.3, `exposure=${result.settings.exposure}`);
  assert.ok(result.settings.highlights <= -20, `highlights=${result.settings.highlights}`);
  assert.equal(result.settings.highlights < 0, true, 'highlights must be negative');
});

await step('auto_enhance leaves saturated colours alone', () => {
  const result = autoEnhance(vividJpeg, { profile: 'natural' });
  assert.equal(result.settings.vibrance, undefined, `vibrance=${result.settings.vibrance}`);
});

await step('auto_enhance strength 0 does nothing', () => {
  const result = autoEnhance(darkJpeg, { strength: 0 });
  assert.equal(result.changed, false, `proposed ${JSON.stringify(result.settings)}`);
});

await step('auto_enhance punchy profile adds presence', () => {
  const result = autoEnhance(darkJpeg, { profile: 'punchy' });
  assert.equal(result.changed, true);
  assert.ok(result.settings.clarity !== undefined, 'punchy should propose clarity');
});

// ---------------------------------------------------------------------------
// 2 + 3 + 4. MCP server, bridge, simulated plug-in
// ---------------------------------------------------------------------------

const applied = []; // develop settings the fake plug-in received

/** Stands in for the Lightroom plug-in: polls the bridge and answers jobs. */
function startFakePlugin(token) {
  const base = `http://127.0.0.1:${PORT}`;
  const headers = { 'X-Lightroom-MCP-Token': token, 'Content-Type': 'application/json' };
  let running = true;
  let seen = 0;

  // Real plug-ins publish their token on start; do the same so the server's
  // shared-secret check gets exercised.
  writeFileSync(path.join(stateDir, 'token'), token, 'utf8');

  async function handle(job) {
    seen += 1;
    const { tool, args } = job;
    if (tool === 'status') {
      return {
        connected: true, running: true, serverReachable: true, port: PORT,
        polls: seen, jobsCompleted: applied.length, module: 'develop',
        catalogPath: '/photos/test.lrcat', selectedCount: 1,
        selectedUuids: ['uuid-1'], lastError: null, currentJob: null,
      };
    }
    if (tool === 'list_photos') {
      return {
        total: 1, returned: 1, truncated: false,
        photos: [{
          uuid: 'uuid-1', fileName: 'IMG_0001.jpg', path: '/photos/IMG_0001.jpg',
          folder: '2026/Beach', fileFormat: 'JPEG', width: 6000, height: 4000,
          rating: 3, pick: 'flagged', colorLabel: 'none',
          capturedAt: '2026-09-20T10:00:00', isVirtualCopy: false, isVideo: false,
          keywords: ['beach'], title: '', caption: '',
        }],
      };
    }
    if (tool === 'render_preview') {
      // Writes the same file Lightroom would, then reports its path.
      const file = path.join(args.destDir, `preview_${args.photos[0]}.jpg`);
      writeFileSync(file, darkJpeg);
      return { path: file, bytes: darkJpeg.length, uuid: args.photos[0],
        requestedEdge: args.longEdge ?? 1200 };
    }
    if (tool === 'set_develop_settings') {
      applied.push({ photos: args.photos, settings: args.settings });
      return {
        applied: (args.photos ?? []).length, requested: (args.photos ?? []).length,
        skipped: 0, settings: args.settings, clamped: [], missing: [], error: null,
      };
    }
    throw new Error(`fake plug-in has no handler for ${tool}`);
  }

  (async () => {
    while (running) {
      try {
        const res = await fetch(`${base}/poll`, { headers, signal: AbortSignal.timeout(1500) });
        const body = await res.json();
        if (body.job) {
          try {
            const data = await handle(body.job);
            await fetch(`${base}/result`, {
              method: 'POST', headers,
              body: JSON.stringify({ id: body.job.id, ok: true, data }),
            });
          } catch (err) {
            await fetch(`${base}/result`, {
              method: 'POST', headers,
              body: JSON.stringify({ id: body.job.id, ok: false, error: err.message }),
            });
          }
        }
      } catch {
        /* server not up yet - keep trying */
      }
      await sleep(60);
    }
  })();

  return { stop: () => { running = false; } };
}

const client = new Client({ name: 'smoke-test', version: '0.0.0' });
let fake = null;
let transport = null;

await step('server starts and connects over stdio', async () => {
  transport = new StdioClientTransport({
    command: process.execPath,
    args: [path.join(root, 'src', 'server.mjs')],
    env: {
      ...process.env,
      LIGHTROOM_MCP_PORT: String(PORT),
      LIGHTROOM_MCP_STATE_DIR: stateDir,
    },
    stderr: 'ignore',
  });
  await client.connect(transport);
});

await step('tools/list exposes every tool', async () => {
  const { tools } = await client.listTools();
  const names = tools.map((t) => t.name).sort();
  const expected = [
    'add_to_collection', 'apply_preset', 'auto_enhance', 'auto_tone',
    'copy_develop_settings', 'create_collection', 'export_photos',
    'get_develop_settings', 'get_photo_details', 'get_selected_photos',
    'list_collections', 'list_photos', 'list_presets', 'render_preview',
    'reset_develop_settings', 'set_develop_settings', 'set_keywords',
    'set_marks', 'snapshots', 'status',
  ];
  assert.deepEqual(names, expected.sort());
  for (const tool of tools) {
    assert.ok(tool.description && tool.description.length > 40,
      `${tool.name} needs a useful description`);
    assert.ok(tool.inputSchema, `${tool.name} has no inputSchema`);
  }
});

await step('status fails helpfully with no plug-in connected', async () => {
  const result = await client.callTool({ name: 'status', arguments: {} });
  const payload = JSON.parse(result.content[0].text);
  assert.equal(payload.lightroom, null, 'lightroom should be null');
  assert.ok(payload.error.includes('not connected'), `error=${payload.error}`);
  assert.ok(payload.help.includes(`http://127.0.0.1:${PORT}/poll`),
    `help should name the plug-in port: ${payload.help}`);
  assert.ok(payload.server.plugInPort === PORT, 'plugInPort should match ours');
  assert.equal(payload.server.port, PORT);
  assert.equal(result.isError ?? false, false, 'status never hard-errors');
});

await step('bridge serves /health and auto-publishes its port', async () => {
  const res = await fetch(`http://127.0.0.1:${PORT}/health`);
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.name, 'lightroom-classic-mcp');
  assert.equal(readFileSync(path.join(stateDir, 'port'), 'utf8'), String(PORT));
});

// --- now bring up the simulated plug-in -------------------------------------

await step('status reports Lightroom once the plug-in polls', async () => {
  fake = startFakePlugin('test-token');
  await sleep(300);
  const result = await client.callTool({ name: 'status', arguments: {} });
  const payload = JSON.parse(result.content[0].text);
  assert.equal(payload.lightroom.module, 'develop');
  assert.equal(payload.lightroom.catalogPath, '/photos/test.lrcat');
  assert.equal(payload.server.pluginConnected, true);
  assert.equal(payload.server.tokenEnforced, true, 'token should be enforced');
});

await step('list_photos round-trips through the bridge', async () => {
  const result = await client.callTool({
    name: 'list_photos', arguments: { minRating: 3, limit: 10 },
  });
  const payload = JSON.parse(result.content[0].text);
  assert.equal(payload.total, 1);
  assert.equal(payload.photos[0].uuid, 'uuid-1');
});

await step('a failing tool call surfaces the plug-in error', async () => {
  const result = await client.callTool({
    name: 'snapshots', arguments: { photos: 'uuid-1', action: 'list' },
  });
  assert.equal(result.isError, true, 'expected an isError result');
  assert.ok(result.content[0].text.includes('no handler for snapshots'));
});

await step('render_preview returns an image plus its path', async () => {
  const result = await client.callTool({
    name: 'render_preview', arguments: { photos: 'uuid-1', longEdge: 640 },
  });
  assert.equal(result.isError ?? false, false, result.content?.[0]?.text);
  const image = result.content.find((c) => c.type === 'image');
  assert.ok(image, 'no image block returned');
  assert.equal(image.mimeType, 'image/jpeg');
  const decoded = Buffer.from(image.data, 'base64');
  assert.equal(decoded[0], 0xff, 'not a JPEG');
  assert.ok(result.content[0].text.includes('.jpg'), 'path text missing');
  const written = result.content[0].text.match(/Rendered preview: (\S+)/)[1];
  assert.ok(existsSync(written), `preview file missing: ${written}`);
});

await step('auto_enhance analyses and applies settings end-to-end', async () => {
  const before = applied.length;
  const result = await client.callTool({
    name: 'auto_enhance',
    arguments: { photos: ['uuid-1'], profile: 'natural' },
  });
  assert.equal(result.isError ?? false, false, result.content?.[0]?.text);
  const payload = JSON.parse(result.content[0].text);
  assert.equal(payload.count, 1);
  assert.equal(payload.applied, 1, JSON.stringify(payload));
  assert.equal(applied.length, before + 1, 'plug-in never received the settings');
  assert.equal(applied[before].settings.exposure > 0, true,
    `dark test image should get positive exposure, got ${JSON.stringify(applied[before].settings)}`);
  assert.ok(payload.results[0].reason.includes('median luma'));
});

await step('auto_enhance dryRun does not touch Lightroom', async () => {
  const before = applied.length;
  const result = await client.callTool({
    name: 'auto_enhance', arguments: { photos: ['uuid-1'], dryRun: true },
  });
  const payload = JSON.parse(result.content[0].text);
  assert.equal(payload.applied, 0);
  assert.equal(payload.dryRun, true);
  assert.equal(applied.length, before, 'settings were applied during a dry run');
});

// ---------------------------------------------------------------------------
// multiple sessions: a second instance forwards through the port owner
// ---------------------------------------------------------------------------

await step('a second session proxies through the instance that owns the port', async () => {
  const second = new Client({ name: 'smoke-test-2', version: '0.0.0' });
  const secondTransport = new StdioClientTransport({
    command: process.execPath,
    args: [path.join(root, 'src', 'server.mjs')],
    env: {
      ...process.env,
      LIGHTROOM_MCP_PORT: String(PORT),
      LIGHTROOM_MCP_STATE_DIR: stateDir,
    },
    stderr: 'ignore',
  });
  try {
    await second.connect(secondTransport);

    // The tool call itself must reach Lightroom and come back untouched.
    const result = await second.callTool({ name: 'list_photos', arguments: { limit: 5 } });
    assert.equal(result.isError ?? false, false, result.content?.[0]?.text);
    const payload = JSON.parse(result.content[0].text);
    assert.equal(payload.photos[0].uuid, 'uuid-1', 'proxied result was wrong');

    // ...and its status must admit it does not own the port.
    const status = await second.callTool({ name: 'status', arguments: {} });
    const statusPayload = JSON.parse(status.content[0].text);
    const server = statusPayload.server;
    assert.equal(server.ownsPort, false, 'second instance should not own the port');
    assert.equal(server.listening, false, 'second instance should not be listening');
    assert.equal(server.portConflict, true, 'should have detected the conflict');
    assert.equal(server.plugInPort, PORT, 'should report the port the plug-in polls');
    assert.equal(statusPayload.lightroom?.module, 'develop',
      'status should still reach Lightroom through the proxy');

    // Lightroom errors must travel back across the proxy too.
    const bad = await second.callTool({
      name: 'snapshots', arguments: { photos: 'uuid-1', action: 'list' },
    });
    assert.equal(bad.isError, true, 'plug-in failure should survive the proxy');
    assert.ok(bad.content[0].text.includes('no handler for snapshots'),
      `got: ${bad.content[0].text}`);

    // auto_enhance gates each photo on "is the plug-in polling?" - on this
    // instance lastPollAt never moves, so a purely local check would wrongly
    // abort with "Lightroom disconnected part-way through the batch".
    const enhance = await second.callTool({
      name: 'auto_enhance', arguments: { photos: ['uuid-1'], dryRun: true },
    });
    assert.equal(enhance.isError ?? false, false,
      `proxied auto_enhance failed: ${enhance.content?.[0]?.text}`);
    const enhanced = JSON.parse(enhance.content[0].text);
    assert.equal(enhanced.count, 1, JSON.stringify(enhanced));
    assert.equal(enhanced.applied, 0, 'dry run must not apply');
  } finally {
    await second.close().catch(() => {});
  }
});

await step('the proxy refuses to loop back on itself', async () => {
  const res = await fetch(`http://127.0.0.1:${PORT}/dispatch`, {
    method: 'POST',
    headers: { 'X-Lightroom-MCP-Token': 'test-token', 'Content-Type': 'application/json' },
    body: JSON.stringify({ tool: 'list_photos', args: {}, hop: 3 }),
  });
  assert.equal(res.status, 400);
  const body = await res.json();
  assert.ok(body.error.includes('too many proxy hops'), `got: ${body.error}`);
});

await step('a foreign program on the port is rejected, not proxied to', async () => {
  const foreign = createServer((_req, res) => {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true, name: 'some-other-app' }));
  });
  await new Promise((r) => foreign.listen(8795, '127.0.0.1', r));
  writeFileSync(portFilePath(), '8795', 'utf8');
  try {
    const probe = new Bridge({ port: 8795 });
    await assert.rejects(() => probe.start(), /EADDRINUSE/, 'should fail to bind');
    assert.equal(probe.portConflict, false, 'must not claim a foreign port');
    await assert.rejects(
      () => probe.call('list_photos', {}),
      /already in use/,
      `got an unhelpful error`,
    );
  } finally {
    writeFileSync(portFilePath(), String(PORT), 'utf8');
    await new Promise((r) => foreign.close(r));
  }
});

await step('server exits exactly once on SIGTERM', async () => {
  const child = spawn(process.execPath, [path.join(root, 'src', 'server.mjs')], {
    env: {
      ...process.env,
      LIGHTROOM_MCP_PORT: '8794',
      LIGHTROOM_MCP_STATE_DIR: stateDir,
    },
    // stdin is held open, so SIGTERM is the only way out. The SDK's stdio
    // transport re-fires onclose() from inside close(), which used to make one
    // SIGTERM log ~1400 shutdown lines and blow the stack.
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  let stderr = '';
  child.stderr.on('data', (chunk) => { stderr += chunk; });
  try {
    try {
      await waitFor(() => stderr.includes('bridge listening'), 8000, 'the bridge to start');
    } catch (err) {
      throw new Error(`${err.message}\nstderr:\n${stderr}`);
    }

    child.kill('SIGTERM');
    const code = await new Promise((resolve) => {
      const timer = setTimeout(() => resolve('timeout'), 5000);
      child.once('exit', (c) => { clearTimeout(timer); resolve(c); });
    });

    assert.equal(code, 0, `expected exit code 0, got ${code}\nstderr:\n${stderr}`);
    const shutdowns = (stderr.match(/shutting down/g) || []).length;
    assert.equal(shutdowns, 1, `expected exactly 1 shutdown log, got ${shutdowns}`);
    assert.ok(!stderr.includes('RangeError'), `stack overflowed:\n${stderr}`);
    assert.equal(existsSync(portFilePath()), false, 'port file left behind');
  } finally {
    if (child.exitCode === null) child.kill('SIGKILL');
    // This instance owned (then removed) the port file; give it back to the
    // main server the rest of the suite depends on.
    writeFileSync(portFilePath(), String(PORT), 'utf8');
  }
});

// ---------------------------------------------------------------------------
// shutdown
// ---------------------------------------------------------------------------

await step('server shuts down cleanly', async () => {
  if (fake) fake.stop();
  await client.close();
});

await step('state dir is cleaned up by close()', async () => {
  await sleep(200);
  assert.equal(existsSync(path.join(stateDir, 'port')), false, 'port file left behind');
});

rmSync(stateDir, { recursive: true, force: true });

console.log(`\n${passed} passed, ${failures.length} failed`);
if (failures.length) {
  console.log(`failed: ${failures.join(', ')}`);
  process.exit(1);
}
process.exit(0);
