# lightroom-classic-mcp

An MCP server that lets AI agents search, **auto-edit**, and export photos in
**Adobe Lightroom Classic** — for OpenCode, Claude Code, Codex, Cursor, or any
other MCP-capable harness.

Local only, no cloud, no accounts. Your catalog stays on your machine.

```
agent (OpenCode / Claude Code / ...)
   │  MCP over stdio
   ▼
src/server.mjs  ── HTTP on 127.0.0.1:8790 ──▶  LightroomMCPBridge.lrplugin
   (this repo)                                    (inside Lightroom Classic)
```

Lightroom has no public API for external processes, so a small Lua plug-in
inside Lightroom polls the server for work, applies it through Adobe's own SDK,
and posts the result back. Nothing is ever bound to a non-loopback interface.

---

## What you get

20 tools, grouped:

| Group | Tools |
| --- | --- |
| Introspect | `status`, `list_photos`, `get_selected_photos`, `get_photo_details`, `render_preview` |
| **Auto edit** | `auto_enhance`, `auto_tone` |
| Adjust | `get_develop_settings`, `set_develop_settings`, `reset_develop_settings`, `copy_develop_settings` |
| Presets | `list_presets`, `apply_preset`, `snapshots` |
| Organise | `set_marks`, `set_keywords`, `list_collections`, `create_collection`, `add_to_collection` |
| Output | `export_photos` |

`render_preview` returns an actual image, so an agent can **look** at the photo,
decide what to change, apply it, and render again to check its work.

---

## Setup

### 1. Install dependencies

```sh
cd /Users/saril/jay/lightroom-mcp
npm install
```

### 2. Install the Lightroom plug-in

```sh
npm run install-plugin
```

This copies `plugin/LightroomMCPBridge.lrplugin` into
`~/Library/Application Support/Adobe/Lightroom/Modules` and prints the one-time
enable steps:

1. **File ▸ Plug-in Manager…**
2. **Add Plug-in…** and choose the path it printed.
3. Leave it enabled and close the manager.

The bridge then starts automatically every time Lightroom launches.

> **Developing the plug-in?** Skip `install-plugin` and add
> `plugin/LightroomMCPBridge.lrplugin` straight from this repo instead, so edits
> are picked up by **File ▸ Plug-in Manager ▸ Reload Plug-in**.

### 3. Register the MCP server with your harness

**OpenCode** (preferred — uses the CLI so your other config is preserved):

```sh
opencode mcp add lightroom -- node /Users/saril/jay/lightroom-mcp/src/server.mjs
opencode mcp list      # expect: lightroom  connected
```

Add `--global` to make it available in every project.

Or write it by hand in `opencode.json(c)`:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "servers": {
      "lightroom": {
        "type": "local",
        "command": ["node", "src/server.mjs"],
        "cwd": "/Users/saril/jay/lightroom-mcp"
      }
    }
  }
}
```

Useful optional fields: `"codemode": false` to expose the 20 tools directly on
the model's native tool list instead of grouping them under Code Mode, and
`"timeout": { "execution": 600000 }` if you run very large exports.

**Claude Code**

```sh
claude mcp add lightroom -- node /Users/saril/jay/lightroom-mcp/src/server.mjs
```

**Codex** (`~/.codex/config.toml`)

```toml
[mcp_servers.lightroom]
command = "node"
args = ["/Users/saril/jay/lightroom-mcp/src/server.mjs"]
```

**Cursor / Claude Desktop** (`.cursor/mcp.json` or `claude_desktop_config.json`)

```json
{
  "mcpServers": {
    "lightroom": {
      "command": "node",
      "args": ["/Users/saril/jay/lightroom-mcp/src/server.mjs"]
    }
  }
}
```

*Config shapes are current as of early 2026; check your harness's docs if its
syntax has moved.*

---

## Using it

Start Lightroom and open a catalog, then ask your agent things like:

```text
Status check on Lightroom, then find everything I shot in the last week
that's rated 3 stars or better and isn't edited yet.

Auto-enhance the first ten of them, render a preview of each so you can
see the result, and put the keepers in a collection called "Sept selects".

Export the final selection as 2000px sRGB JPEGs to ~/Desktop/sept-selects.
```

Every tool takes `photos` as Lightroom `uuid`s (a string or an array) — get
them from `list_photos` or `get_selected_photos`. **Omit `photos` entirely to
operate on whatever is selected in Lightroom.**

### `auto_enhance` — the headline tool

Renders a preview of each photo, measures it in Node (Lightroom's Lua can't
decode pixels), computes a correction, and applies it through Lightroom. Works
on **any** number of photos from **any** Lightroom module, and never touches
the UI or your selection.

Measured per photo: median luma, 1/25/75/99th percentile luminance, clipped
highlight and shadow fraction, contrast (std-dev), mean saturation, and the
saturation histogram.

| Profile | Behaviour |
| --- | --- |
| `natural` (default) | Exposure toward mid-grey, endpoint recovery, contrast, a subtle vibrance trim (capped at +15). |
| `punchy` | All of the above at full strength, plus clarity, full vibrance (capped at +35), and a dehaze check. |
| `soft` | Exposure and endpoints only — no shadow lifting, no presence. |

```jsonc
{ "photos": ["<uuid>"], "profile": "punchy", "strength": 0.8 }
```

* `strength` — `0` to `1.5`; `0` proposes nothing at all.
* `dryRun: true` — analyse and report the settings it *would* apply.
* `verify: true` — re-render each photo after editing so you can compare.

It deliberately **never** brightens into a blown-out image: once more than ~5%
of pixels are clipped, the exposure correction turns negative instead, so a
dark foreground under a blown sky doesn't get pushed further. Colour,
saturation, white balance, masks, curves, crops, and local adjustments are left
alone — this is corrective tone work, not a creative grade.

Example response:

```jsonc
{
  "count": 3, "applied": 3, "dryRun": false, "profile": "natural",
  "results": [{
    "uuid": "…", "ok": true,
    "reason": "median luma 0.157 (target 0.460), p99 0.231, 0.0% clipped high …",
    "applied": { "exposure": 1, "whites": 100, "blacks": -17, "shadows": 8, "contrast": 20 }
  }]
}
```

### `auto_tone` — Lightroom's own Auto

Calls `LrDevelopController.setAutoTone()`, which is Adobe's algorithm. It only
works on the photo shown in the Develop module, so it may switch module and
temporarily change your selection — **it restores both** and says so in the
response. Pass `switchToDevelop: true` to allow the switch; otherwise it tells
you to use `auto_enhance` instead.

### Setting adjustments directly

`set_develop_settings` merges what you pass into each photo's existing
settings; only the keys you send change. Friendly names are accepted:

```jsonc
{
  "photos": ["<uuid>"],
  "settings": { "exposure": 0.35, "highlights": -40, "shadows": 25,
                "clarity": 15, "hue_blue": -12 },
  "historyLabel": "agent: cool the blues"
}
```

`exposure` is in stops (−5..5); most sliders are −100..100. Out-of-range values
are clamped and reported back rather than silently truncated. Common names:
`exposure`, `contrast`, `highlights`, `shadows`, `whites`, `blacks`,
`clarity`, `texture`, `dehaze`, `vibrance`, `saturation`, `brightness`,
`temperature`/`temp`, `tint`, `whitebalance`, `grayscale`, `sharpness`,
`noise_reduction`, `color_noise_reduction`, `vignette`, `grain`,
`tone_shadows`, `tone_darks`, `tone_lights`, `tone_highlights`, `hue_*`,
`sat_*`, `lum_*`
(e.g. `hue_blue`, `sat_orange`), plus raw Lightroom keys (`Exposure2012`,
`PostCropVignetteAmount`, …) for anything else. The key actually written is
resolved from the photo's own settings table, so Lightroom's inconsistent
spellings are handled for you.

### Seeing the photo

```jsonc
{ "photos": ["<uuid>"], "longEdge": 1600 }
```

Returns both an image content block and the path to the JPEG it wrote under
`<tmp>/lightroom-classic-mcp/previews/`. Read the file (or the image block) to
inspect the photo as it currently looks.

---

## More than one harness at a time

Lightroom's plug-in polls a single port, so exactly one instance of this server
owns it. If a second session starts — a second OpenCode session, or Claude Code
while OpenCode is already running — it detects the owner and **forwards its
calls to it** instead of failing. Both harnesses work at once; you do not need
to change any configuration.

The second session reports `server.ownsPort: false` from `status`. If the owning
session exits, the second one retries the probe (cached for 10s) and then errors
with a clear message.

A *different* program on the port is never proxied to — that is reported as a
port conflict instead.

---

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `LIGHTROOM_MCP_PORT` | `8790` | Loopback port to listen on. Both sides read the published port file, so changing it needs no plug-in reconfiguration. |
| `LIGHTROOM_MCP_STATE_DIR` | `<tmp>/lightroom-classic-mcp` | Where `port`, `token`, and `previews/` live. Overridable for tests or unusual temp setups. |

Per-tool timeouts (the agent waits this long before getting a "Lightroom didn't
answer" error): `render_preview` 120s, `export_photos` / `auto_enhance` 600s,
`auto_tone` 180s, `status` 15s, everything else 60s. When no plug-in has polled
for 15s, calls fail immediately with connection instructions rather than
hanging.

npm scripts:

```sh
npm start            # run the MCP server on stdio (your harness does this)
npm run install-plugin
npm run check        # Lua 5.1 parse check + JSON unit tests + JS syntax
npm test             # check + the end-to-end smoke test
```

---

## Troubleshooting

**"Lightroom Classic is not connected."**
Lightroom isn't running, or the plug-in is stopped. Open Lightroom, then
**File ▸ Plug-in Manager ▸ Lightroom MCP Bridge** (check it's enabled), or
**Library ▸ Plug-in Extras ▸ Toggle MCP Bridge**. The `status` tool reports the
same thing with the port and the last poll time.

**The plug-in says the bridge is unreachable.**
The MCP server must be *started by your harness* before the plug-in can talk to
it — the plug-in polls, so nothing is there until a session opens. Start a
session in OpenCode/Claude Code and the plug-in will connect within half a
second. You can also run `npm start` in a terminal to bring it up by hand (it
will sit idle waiting for MCP input).

**Port already in use by another program.**
Set `LIGHTROOM_MCP_PORT` to something else (e.g. `8791`). No plug-in change is
needed — the port file handles it.

**Edits don't seem to happen.**
Try `auto_enhance` with `dryRun: true` first to see the proposed settings and
the measurements behind them. Check `get_photo_details` afterwards to confirm
what Lightroom recorded. If `set_develop_settings` reports missing or clamped
keys, the response names them.

**Token mismatch.**
The plug-in regenerates its shared secret on every Lightroom start. If it ever
appears, restart your MCP session so both sides re-read the token file. This is
defence in depth: everything is loopback-only regardless.

---

## Safety

* **Loopback only** — `127.0.0.1`, never a public interface.
* **Shared secret** — the plug-in writes an MD5 token to the state dir; the
  server enforces it when readable, and degrades to loopback-only when not.
* **Non-destructive** — edits are develop parameters in Lightroom's own
  catalog, fully undoable. Original files are never modified; `export_photos`
  writes copies.
* **Scoped writes** — catalogue changes go through `catalog:withWriteAccessDo`,
  so an agent's edits are one undo step and roll back as a unit.
* **Read-only tools are marked** — `readOnlyHint` is set on the 8 read tools so
  a harness can gate them separately.

---

## Development

```sh
npm test
```

runs three layers:

1. **`scripts/check.mjs`** — every `.lua` file parsed as Lua 5.1 (luaparse) and
   `node --check` on every `.mjs`, plus `scripts/test-json.lua` when a Lua
   interpreter is installed (49 assertions: escapes, surrogate pairs, round
   trips, error cases, 100-level nesting).
2. **`scripts/smoke.mjs`** — 21 end-to-end steps: spawns the real MCP server
   over stdio, drives it with the MCP SDK client, runs a simulated plug-in
   against the real HTTP bridge, and exercises auto-enhance against synthetic
   JPEGs (dark image → brightened, blown image → recovered, saturated image →
   left alone, `strength: 0` → no change), the render-preview image path, the
   multi-session proxy, and the port-conflict path.

Layout:

```
src/
  server.mjs          MCP entry point (stdio), tool registration, lifecycle
  bridge.mjs          loopback HTTP server, job queue, proxy, port/token files
  tools.mjs           the 20 tool definitions + auto_enhance orchestration
  enhance.mjs         histogram analysis and suggestSettings heuristics
  install-plugin.mjs  copies the plug-in into Lightroom's Modules folder
plugin/LightroomMCPBridge.lrplugin/
  Info.lua            manifest (auto-start, menus, shutdown)
  Bridge.lua          poll loop, token, job dispatch
  Handlers.lua        one function per MCP tool (the Lightroom side)
  Json.lua            dependency-free JSON codec (unit-tested)
  Config.lua          port auto-discovery
scripts/              check, smoke, JSON unit tests
```

The plug-in loads in Lightroom as soon as it launches (`LrForceInitPlugin`)
and publishes its token immediately, so the connection works even before you
open the Plug-in Manager.

---

## Limitations

* **Lightroom Classic only** — not Lightroom (cloud), not Adobe Camera Raw.
* **Non-destructive parameter edits**, not generative or pixel-level work. There
  is no inpainting, object removal, or sky replacement here — Lightroom's SDK
  has no such capability.
* **`applyDevelopSettings` is an experimental Adobe API.** The definitive list
  of keys is the one Lightroom's UI shows; Adobe may change it. This project
  resolves keys per photo and reports anything it could not apply.
* **Crop and rotation** are read but not settable through a settings table
  (there is no documented way to place an arbitrary crop); use Lightroom's own
  crop tool. `reset_develop_settings` with `resetCrop` does clear it.
* **One catalog at a time** — whatever catalog Lightroom has open.
* **Export runs inside Lightroom** and can block the plug-in for minutes on a
  large batch; the tool accounts for that with a 10-minute timeout.

## License

UNLICENSED — private, local use.
