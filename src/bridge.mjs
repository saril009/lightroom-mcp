// Local HTTP bridge between the MCP server (this process, stdio) and the
// Lightroom plug-in (which polls us on the loopback interface).
//
//   GET  /poll    -> { job: null } | { job: { id, tool, args } }
//   POST /result  <- { id, ok, data } | { id, ok, error }
//   GET  /health  -> liveness probe used for port-conflict detection
//
// Only 127.0.0.1 is ever bound. The plug-in writes a shared-secret token to
// the system temp folder; if we can read it we enforce it, and if we cannot
// (paths differ on some systems) we degrade to loopback-only access rather
// than failing to work at all.

import { createServer } from 'node:http';
import { existsSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import os from 'node:os';
import path from 'node:path';

export const PLUGIN_NAME = 'lightroom-classic-mcp';
const MAX_BODY_BYTES = 32 * 1024 * 1024;
// A live instance rewrites its port file on start, so anything older than this
// belongs to a process that is gone. See publishedPort().
const STALE_PORT_FILE_MS = 24 * 60 * 60 * 1000;

export function stateDir() {
  // Overridable so tests (and unusual temp setups) never collide with a real
  // running instance's published port/token.
  if (process.env.LIGHTROOM_MCP_STATE_DIR) return process.env.LIGHTROOM_MCP_STATE_DIR;
  return path.join(os.tmpdir(), PLUGIN_NAME);
}

/**
 * Where the plug-in discovers which port we are listening on. Both sides read
 * this file, so changing LIGHTROOM_MCP_PORT needs no plug-in reconfiguration.
 */
export function portFilePath() {
  return path.join(stateDir(), 'port');
}

/**
 * The port the plug-in is actually polling, or null if nothing published one.
 * Exported so scripts can find the owning instance without duplicating the
 * staleness rules.
 */
export function publishedPort() {
  try {
    const file = portFilePath();
    // A crashed or SIGKILLed instance never runs close(), so its port file
    // outlives it. Treat a stale file as absent: otherwise a fresh instance
    // reads the dead one's port, concludes it does not own the port, and
    // proxies to a peer that is not there.
    const ageMs = Date.now() - statSync(file).mtimeMs;
    if (ageMs > STALE_PORT_FILE_MS) return null;
    const raw = readFileSync(file, 'utf8').trim();
    const port = Number(raw);
    return Number.isInteger(port) && port > 0 && port <= 65535 ? port : null;
  } catch {
    return null;
  }
}

/** Default per-call deadlines, in milliseconds. */
const DEFAULT_TIMEOUTS = {
  render_preview: 120_000,
  export_photos: 600_000,
  auto_enhance: 600_000,
  auto_tone: 180_000,
  status: 15_000,
};

export function timeoutFor(tool) {
  return DEFAULT_TIMEOUTS[tool] ?? 60_000;
}

export function previewDir() {
  return path.join(stateDir(), 'previews');
}

export class Bridge {
  constructor({ port = 8790, host = '127.0.0.1' } = {}) {
    this.port = port;
    this.host = host;
    this.queue = []; // jobs waiting to be picked up by the plug-in
    this.inFlight = new Map(); // id -> job
    this.lastPollAt = null;
    this.polls = 0;
    this.jobsCompleted = 0;
    this.portConflict = false;
    this.portConflictMessage = null;
    this.startedAt = Date.now();
    this.server = null;
    this.tokenPath = path.join(stateDir(), 'token');
    this.upstream = { at: 0, base: null };
    // NB: must not be called `probe` - that is an existing method name.
    this.remoteConnected = { at: 0, value: false };
  }

  /** Reads the plug-in's shared secret, if it has written one yet. */
  readToken() {
    try {
      if (!existsSync(this.tokenPath)) return null;
      const token = readFileSync(this.tokenPath, 'utf8').trim();
      return token.length > 0 ? token : null;
    } catch {
      return null;
    }
  }

  tokenOk(req) {
    const expected = this.readToken();
    if (!expected) return true; // no token published: loopback-only is enough
    const got = req.headers['x-lightroom-mcp-token'];
    return typeof got === 'string' && got === expected;
  }

  status() {
    return {
      port: this.port,
      host: this.host,
      listening: Boolean(this.server),
      ownsPort: this.ownsPublishedPort(),
      // The port the plug-in actually polls - ours, or another session's.
      plugInPort: publishedPort() ?? this.port,
      portConflict: this.portConflict,
      portConflictMessage: this.portConflictMessage,
      polls: this.polls,
      lastPollAt: this.lastPollAt ? new Date(this.lastPollAt).toISOString() : null,
      pluginConnected: this.pluginConnected(),
      pendingJobs: this.queue.length,
      inFlightJobs: this.inFlight.size,
      jobsCompleted: this.jobsCompleted,
      tokenFile: this.tokenPath,
      tokenEnforced: this.readToken() !== null,
      uptimeSeconds: Math.round((Date.now() - this.startedAt) / 1000),
    };
  }

  /** True when the plug-in polled within the last 15 seconds. */
  pluginConnected() {
    return this.lastPollAt !== null && Date.now() - this.lastPollAt < 15_000;
  }

  /**
   * Proxy-aware form of pluginConnected(), for callers that gate work on it.
   *
   * When another session owns the port, our own lastPollAt never moves, so the
   * local check would report "disconnected" forever and multi-step tools such
   * as auto_enhance would refuse to start even though Lightroom is fine. Ask
   * the owning instance instead - its /health endpoint carries the same flag -
   * and cache the answer briefly so per-photo checks stay cheap.
   *
   * If nobody answers we optimistically return true: the next call() then
   * fails with the precise reason (port conflict, dead upstream, plug-in not
   * polling) instead of a misleading "Lightroom disconnected".
   */
  async pluginConnectedAsync() {
    if (this.ownsPublishedPort()) return this.pluginConnected();
    const now = Date.now();
    if (now - this.remoteConnected.at < 2000) return this.remoteConnected.value;
    let value = true;
    const port = publishedPort() ?? this.port;
    try {
      const res = await fetch(`http://${this.host}:${port}/health`, {
        signal: AbortSignal.timeout(1500),
      });
      if (res.ok) {
        const body = await res.json();
        if (body && body.name === PLUGIN_NAME) value = Boolean(body.pluginConnected);
      }
    } catch {
      /* nothing answering: leave it to call() to explain why */
    }
    this.remoteConnected = { at: now, value };
    return value;
  }

  hasTokenFile() {
    return existsSync(this.tokenPath);
  }

  /**
   * Sends a tool call to Lightroom and resolves with its result.
   *
   * Normally we own the port the plug-in polls, so the job goes on our own
   * queue. When a second session of this MCP server is running (another agent
   * harness, or a second OpenCode session), one instance ends up owning the
   * port and the other does not - in that case we forward the call to the
   * owning instance via POST /dispatch, so both harnesses work at once.
   *
   * Rejects fast when no plug-in is polling so the agent gets a useful error.
   */
  async call(tool, args = {}, { timeoutMs = timeoutFor(tool), hop = 0 } = {}) {
    if (!this.ownsPublishedPort()) {
      const upstream = await this.resolveUpstream();
      if (upstream) return this.callRemote(upstream, tool, args, timeoutMs, hop);
    }
    if (!this.server) {
      throw new Error(this.portConflictMessage
        ?? 'The local bridge HTTP server is not running.');
    }

    const age = this.lastPollAt ? Date.now() - this.lastPollAt : Infinity;
    if (age > 15_000) {
      throw new Error(
        'Lightroom Classic is not connected. Open Lightroom Classic and make sure the '
        + '"Lightroom MCP Bridge" plug-in is running (File > Plug-in Manager, or '
        + 'Library > Plug-in Extras > Toggle MCP Bridge). '
        + `The plug-in polls http://127.0.0.1:${this.port}/poll `
        + (this.lastPollAt
          ? `but last checked in ${Math.round(age / 1000)}s ago.`
          : 'but has never connected.'),
      );
    }

    return new Promise((resolve, reject) => {
      const job = {
        id: randomUUID(),
        tool,
        args,
        enqueuedAt: Date.now(),
        resolve,
        reject,
        timer: setTimeout(() => {
          this.inFlight.delete(job.id);
          this.queue = this.queue.filter((j) => j !== job);
          reject(new Error(
            `Lightroom did not answer "${tool}" within ${Math.round(timeoutMs / 1000)}s. `
            + 'Lightroom may be busy (a big export or preview build blocks the plug-in), '
            + 'or the plug-in was stopped mid-job.',
          ));
        }, timeoutMs),
      };
      this.queue.push(job);
    });
  }

  /** True when our HTTP server is the one the plug-in is polling. */
  ownsPublishedPort() {
    return Boolean(this.server) && (publishedPort() ?? this.port) === this.port;
  }

  /**
   * Finds another instance of this same server that owns the port the plug-in
   * polls, or null when we should handle the call ourselves. Cached briefly so
   * a dead bridge does not add a probe delay to every tool call.
   */
  async resolveUpstream() {
    if (Date.now() - this.upstream.at < 10_000) return this.upstream.base;
    let base = null;
    const port = publishedPort() ?? this.port;
    if (!this.ownsPublishedPort()) {
      try {
        const res = await fetch(`http://${this.host}:${port}/health`, {
          signal: AbortSignal.timeout(1500),
        });
        if (res.ok) {
          const body = await res.json();
          const isUs = body && body.name === PLUGIN_NAME;
          const isSelf = this.server && port === this.port;
          if (isUs && !isSelf) base = `http://${this.host}:${port}`;
        }
      } catch {
        /* nothing listening there */
      }
    }
    this.upstream = { at: Date.now(), base };
    return base;
  }

  /** Forwards a tool call to the instance that owns the plug-in's port. */
  async callRemote(base, tool, args, timeoutMs, hop) {
    const token = this.readToken();
    let res;
    try {
      res = await fetch(`${base}/dispatch`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          ...(token ? { 'X-Lightroom-MCP-Token': token } : {}),
        },
        body: JSON.stringify({ tool, args, timeoutMs, hop: hop + 1 }),
        // Give the far side its own deadline plus room to reply after it.
        signal: AbortSignal.timeout(timeoutMs + 20_000),
      });
    } catch (err) {
      this.upstream = { at: 0, base: null };
      throw new Error(
        `Could not reach the lightroom-classic-mcp instance at ${base} `
        + `(${err.message}). It may have exited; restart this session.`,
      );
    }
    if (res.status === 403) {
      throw new Error(
        'The other lightroom-classic-mcp instance rejected our token. '
        + 'Restart this session so both sides read the same plug-in token.',
      );
    }
    let body;
    try {
      body = await res.json();
    } catch {
      throw new Error(`Unexpected reply from ${base} (HTTP ${res.status}).`);
    }
    if (!res.ok || body.ok !== true) {
      throw new Error(String(body?.error ?? `HTTP ${res.status} from ${base}`));
    }
    return body.data;
  }

  settle(id, ok, payload) {
    const job = this.inFlight.get(id);
    if (!job) return false;
    this.inFlight.delete(id);
    clearTimeout(job.timer);
    if (ok) job.resolve(payload);
    else job.reject(new Error(String(payload ?? 'unknown Lightroom error')));
    return true;
  }

  sendJson(res, status, body) {
    const data = Buffer.from(JSON.stringify(body), 'utf8');
    res.writeHead(status, {
      'Content-Type': 'application/json; charset=utf-8',
      'Content-Length': data.length,
      'Cache-Control': 'no-store',
    });
    res.end(data);
  }

  readBody(req) {
    return new Promise((resolve, reject) => {
      const chunks = [];
      let size = 0;
      req.on('data', (chunk) => {
        size += chunk.length;
        if (size > MAX_BODY_BYTES) {
          reject(new Error('body too large'));
          req.destroy();
          return;
        }
        chunks.push(chunk);
      });
      req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
      req.on('error', reject);
    });
  }

  async handle(req, res) {
    const url = new URL(req.url, `http://${this.host}:${this.port}`);

    if (req.method === 'GET' && url.pathname === '/health') {
      this.sendJson(res, 200, { ok: true, name: PLUGIN_NAME, ...this.status() });
      return;
    }

    if (req.method === 'GET' && url.pathname === '/poll') {
      if (!this.tokenOk(req)) {
        this.sendJson(res, 403, { error: 'token mismatch - restart the Lightroom plug-in' });
        return;
      }
      this.lastPollAt = Date.now();
      this.polls += 1;
      const job = this.queue.shift();
      if (!job) {
        this.sendJson(res, 200, { job: null });
        return;
      }
      this.inFlight.set(job.id, job);
      this.sendJson(res, 200, {
        job: { id: job.id, tool: job.tool, args: job.args ?? {} },
      });
      return;
    }

    if (req.method === 'POST' && url.pathname === '/result') {
      if (!this.tokenOk(req)) {
        this.sendJson(res, 403, { error: 'token mismatch' });
        return;
      }
      let body;
      try {
        body = JSON.parse(await this.readBody(req));
      } catch (err) {
        this.sendJson(res, 400, { error: `bad JSON: ${err.message}` });
        return;
      }
      const accepted = this.settle(body.id, body.ok === true, body.ok ? body.data : body.error);
      this.sendJson(res, 200, accepted
        ? { accepted: true }
        : { accepted: false, error: 'no such job id (it may have already timed out)' });
      return;
    }

    if (req.method === 'POST' && url.pathname === '/dispatch') {
      if (!this.tokenOk(req)) {
        this.sendJson(res, 403, { error: 'token mismatch' });
        return;
      }
      let body;
      try {
        body = JSON.parse(await this.readBody(req));
      } catch (err) {
        this.sendJson(res, 400, { error: `bad JSON: ${err.message}` });
        return;
      }
      if (typeof body.tool !== 'string' || body.tool.length === 0) {
        this.sendJson(res, 400, { error: 'tool is required' });
        return;
      }
      const hop = Number(body.hop) || 0;
      if (hop >= 3) {
        this.sendJson(res, 400, { error: 'too many proxy hops - two instances are pointing at each other' });
        return;
      }
      const requested = Number(body.timeoutMs);
      const timeoutMs = Number.isFinite(requested) && requested > 0 && requested <= 900_000
        ? requested
        : timeoutFor(body.tool);
      try {
        const data = await this.call(
          body.tool,
          body.args && typeof body.args === 'object' ? body.args : {},
          { timeoutMs, hop },
        );
        this.sendJson(res, 200, { ok: true, data });
      } catch (err) {
        // Application-level failure: HTTP 200 so the caller can read the reason.
        this.sendJson(res, 200, { ok: false, error: String(err?.message ?? err) });
      }
      return;
    }

    this.sendJson(res, 404, { error: 'not found' });
  }

  async start() {
    const server = createServer((req, res) => {
      this.handle(req, res).catch((err) => {
        try {
          this.sendJson(res, 500, { error: String(err && err.message) });
        } catch {
          /* headers already sent */
        }
      });
    });
    // /dispatch waits for Lightroom to finish a job before replying (up to 10
    // minutes for an export), so a request deadline must not cut it off.
    server.requestTimeout = 0;

    await new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(this.port, this.host, () => {
        server.removeListener('error', reject);
        resolve();
      });
    }).catch(async (err) => {
      if (err.code !== 'EADDRINUSE') throw err;
      // Another instance may already be serving this port - probe it.
      const theirs = await this.probe();
      this.portConflict = Boolean(theirs && theirs.name === PLUGIN_NAME);
      this.portConflictMessage = `Port ${this.port} is already in use`
        + (this.portConflict
          ? ' by another lightroom-classic-mcp instance (another agent session?).'
          : ` by another program (set LIGHTROOM_MCP_PORT to something else, and change the port in the plug-in's settings).`);
      console.error(`[lightroom-mcp] ${this.portConflictMessage}`);
      if (!this.portConflict) throw err;
    });

    if (server.listening) {
      this.server = server;
      try {
        mkdirSync(previewDir(), { recursive: true });
        writeFileSync(portFilePath(), String(this.port), 'utf8');
      } catch (err) {
        console.error(`[lightroom-mcp] could not publish state dir: ${err.message}`);
      }
      console.error(`[lightroom-mcp] bridge listening on http://${this.host}:${this.port}`);
    }
    return this;
  }

  async probe() {
    try {
      const res = await fetch(`http://${this.host}:${this.port}/health`, {
        signal: AbortSignal.timeout(1500),
      });
      if (!res.ok) return null;
      return await res.json();
    } catch {
      return null;
    }
  }

  close() {
    for (const job of this.queue) {
      clearTimeout(job.timer);
      job.reject(new Error('MCP server is shutting down'));
    }
    for (const job of this.inFlight.values()) {
      clearTimeout(job.timer);
      job.reject(new Error('MCP server is shutting down'));
    }
    this.queue = [];
    this.inFlight.clear();
    if (this.server) {
      this.server.close();
      this.server.closeAllConnections?.();
      this.server = null;
      // Only clear the published port if it is still ours.
      try {
        if (existsSync(portFilePath())
          && readFileSync(portFilePath(), 'utf8').trim() === String(this.port)) {
          rmSync(portFilePath(), { force: true });
        }
      } catch {
        /* best effort */
      }
    }
  }
}
