// Live check: exercise the real MCP tool handlers against the RUNNING
// Lightroom Classic and assert the shape of each response.
//
// Why this exists: check.mjs is a syntax gate. `LrFileUtils.writeFile` is
// valid Lua that does not exist in the SDK, so luaparse passes it happily and
// 49/49 green while render_preview and auto_enhance are dead on arrival. Only
// a real call against a real catalog catches that class of error.
//
// This drives buildTools()' handlers rather than POSTing to /dispatch, so it
// exercises the same path an agent takes - including the JS orchestration in
// auto_enhance, which no /dispatch call could ever reach.
//
// READ-ONLY. auto_enhance runs with dryRun: true. Adding a write handler here
// means adding an explicit --write flag and a confirmation, deliberately.
//
// Usage:
//   node scripts/live-check.mjs            # human-readable
//   node scripts/live-check.mjs --json     # machine-readable

import { readFileSync } from 'node:fs';
import { publishedPort, Bridge, previewDir } from '../src/bridge.mjs';
import { buildTools } from '../src/tools.mjs';

const wantJson = new Set(process.argv.slice(2)).has('--json');

const UUID_TOKEN = '$UUID';

const CHECKS = [
  {
    tool: 'status',
    args: {},
    expect: (d) => {
      // status returns { server, lightroom } when the plug-in answers, and
      // { server, lightroom: null, error, help } when it cannot. Both are
      // valid; assert the server half and report the plug-in half as-is.
      need(d, 'server', 'object');
      if (d.lightroom === null) {
        if (!d.error) throw new Error('lightroom is null but no error was given');
        return;
      }
      need(d, 'lightroom', 'object');
      need(d.lightroom, 'connected', 'boolean');
      need(d.lightroom, 'catalogPath', 'string');
    },
  },
  {
    tool: 'list_photos',
    args: { limit: 3 },
    expect: (d) => {
      needArray(d, 'photos');
      for (const p of d.photos ?? []) need(p, 'uuid', 'string');
    },
  },
  {
    tool: 'get_selected_photos',
    args: {},
    expect: (d) => needArray(d, 'photos'),
  },
  {
    tool: 'get_photo_details',
    args: { photos: [UUID_TOKEN] },
    expect: (d) => {
      need(d, 'photo', 'object');
      need(d.photo, 'uuid', 'string');
    },
  },
  {
    tool: 'get_develop_settings',
    args: { photos: [UUID_TOKEN] },
    expect: (d) => need(d, 'settings', 'object'),
  },
  { tool: 'list_presets', args: {}, expect: () => {} },
  { tool: 'list_collections', args: {}, expect: () => {} },
  {
    // The handler that shipped broken. Renders for real AND writes a real
    // file, so it is the single most valuable check in this file.
    tool: 'render_preview',
    args: { photos: [UUID_TOKEN], longEdge: 256 },
    expect: (d, res) => {
      // render_preview returns image content, not JSON text. Check the file it
      // claims to have written actually exists and is a non-empty JPEG.
      const text = (res.content ?? []).filter((c) => c.type === 'text').map((c) => c.text).join('\n');
      const m = text.match(/Rendered preview: (.+)/);
      if (!m) throw new Error(`no preview path in response: ${text.slice(0, 120)}`);
      const buf = readFileSync(m[1].trim());
      if (buf.length < 512) throw new Error(`preview file is ${buf.length} bytes - suspiciously small`);
      if (buf[0] !== 0xff || buf[1] !== 0xd8) throw new Error('preview file is not a JPEG (bad SOI marker)');
      const hasImage = (res.content ?? []).some((c) => c.type === 'image' && c.data?.length > 0);
      if (!hasImage) throw new Error('no image content block returned');
    },
  },
  {
    tool: 'auto_enhance',
    // dryRun: true - analyses and renders, applies nothing.
    args: { photos: [UUID_TOKEN], dryRun: true, profile: 'natural' },
    expect: (d) => {
      need(d, 'count', 'number');
      needArray(d, 'results');
      for (const r of d.results ?? []) {
        need(r, 'measurements', 'object');
        need(r, 'proposed', 'object');
        const m = r.measurements ?? {};
        need(m, 'medianLuma', 'number');
        if (typeof m.exposureStops !== 'number') {
          throw new Error('measurements.exposureStops missing or not a number');
        }
        // medianLuma is 0..1; exposureStops is a stop count, typically small.
        // Guard the regression where exposureStops was just p50 under a
        // misleading name.
        if (m.exposureStops === m.medianLuma) {
          throw new Error('exposureStops is identical to medianLuma - the label bug is back');
        }
        if (r.applied !== false) {
          throw new Error(`dryRun must never apply, got applied=${r.applied}`);
        }
      }
    },
  },
];

function need(obj, key, type) {
  if (!obj || typeof obj !== 'object') throw new Error('payload is not an object');
  if (typeof obj[key] !== type) {
    throw new Error(`expected ${key}:${type}, got ${JSON.stringify(obj[key])?.slice(0, 80)}`);
  }
}

function needArray(obj, key) {
  if (!obj || typeof obj !== 'object') throw new Error('payload is not an object');
  if (!Array.isArray(obj[key])) {
    throw new Error(`expected ${key}:array, got ${typeof obj[key]} - `
      + `${JSON.stringify(obj[key])?.slice(0, 80)}`);
  }
}

// ---------------------------------------------------------------------------

function makeBridge(port) {
  // Deliberately leave bridge.server null: this process is a CLIENT of the
  // instance that owns the plug-in port, not a second server. With no server
  // object, ownsPublishedPort() is false and call() transparently proxies
  // through /dispatch - the same path the real MCP tools take when a second
  // harness is running.
  return new Bridge({ port });
}

async function main() {
  const port = publishedPort() ?? 8790;
  const bridge = makeBridge(port);
  const handlers = new Map(buildTools(bridge).map((t) => [t.name, t.handler]));

  const results = [];
  let uuid = null;

  for (const check of CHECKS) {
    const t0 = Date.now();
    try {
      const handler = handlers.get(check.tool);
      if (!handler) throw new Error(`no handler named ${check.tool}`);

      if (uuid === null && check.args.photos) {
        // Take a uuid from the catalog, not from the selection: the user may
        // have nothing selected, and a live check that skips whenever the
        // Develop module happens to be empty is useless.
        const res = await handlers.get('list_photos')({ limit: 5 });
        const data = JSON.parse(res.content[0].text);
        uuid = data.photos?.[0]?.uuid ?? null;
        if (!uuid) {
          results.push({ tool: check.tool, status: 'skip', ms: Date.now() - t0, note: 'catalog is empty' });
          continue;
        }
      }

      const args = JSON.parse(JSON.stringify(check.args)
        .replaceAll(`"${UUID_TOKEN}"`, JSON.stringify(uuid)));
      const res = await handler(args);
      if (res.isError) {
        throw new Error(`tool returned isError: ${res.content?.[0]?.text ?? 'unknown'}`);
      }
      const data = res.content?.[0]?.type === 'text' ? JSON.parse(res.content[0].text) : null;
      check.expect(data, res);
      results.push({ tool: check.tool, status: 'pass', ms: Date.now() - t0 });
    } catch (err) {
      results.push({ tool: check.tool, status: 'FAIL', ms: Date.now() - t0, error: String(err.message ?? err) });
    }
  }

  const passed = results.filter((r) => r.status === 'pass');
  const failed = results.filter((r) => r.status === 'FAIL');
  const skipped = results.filter((r) => r.status === 'skip');

  if (wantJson) {
    console.log(JSON.stringify({ port, uuid, previewDir: previewDir(), results, passed: passed.length, failed: failed.length }, null, 2));
  } else {
    console.log(`live-check against 127.0.0.1:${port}`);
    if (uuid) console.log(`photo: ${uuid}`);
    for (const r of results) {
      const mark = r.status === 'pass' ? 'ok  ' : r.status === 'skip' ? 'skip' : 'FAIL';
      console.log(`  ${mark}  ${r.tool.padEnd(20)} ${String(r.ms).padStart(6)}ms  ${r.error ?? r.note ?? ''}`);
    }
    console.log(`\n${passed.length} passed, ${failed.length} failed, ${skipped.length} skipped (read-only)`);
  }

  process.exit(failed.length > 0 ? 1 : 0);
}

main().catch((err) => {
  console.error(`live-check could not run: ${err.stack || err}`);
  process.exit(2);
});
