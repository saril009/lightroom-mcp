// Temporary diagnostic: reproduce the foreign-port step of the smoke test and
// report exactly what start() did. Not part of the suite.
import { createServer } from 'node:http';
import { mkdtempSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

process.env.LIGHTROOM_MCP_STATE_DIR = mkdtempSync(path.join(os.tmpdir(), 'lr-diag-'));
const { Bridge, portFilePath } = await import('../src/bridge.mjs');

const foreign = createServer((_req, res) => {
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ ok: true, name: 'some-other-app' }));
});
await new Promise((r) => foreign.listen(8795, '127.0.0.1', r));
writeFileSync(portFilePath(), '8795', 'utf8');
console.log('foreign listening on 8795');

const t0 = Date.now();
const probe = new Bridge({ port: 8795 });
try {
  await probe.start();
  console.log(`RESOLVED after ${Date.now() - t0}ms  portConflict=${probe.portConflict} `
    + `listening=${Boolean(probe.server?.listening)} msg=${probe.portConflictMessage}`);
} catch (err) {
  console.log(`REJECTED after ${Date.now() - t0}ms  code=${err.code} msg=${err.message}`);
}
await new Promise((r) => foreign.close(r));
process.exit(0);
