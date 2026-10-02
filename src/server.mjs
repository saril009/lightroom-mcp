#!/usr/bin/env node
// lightroom-classic-mcp - MCP server + local bridge for Adobe Lightroom Classic.
//
// Protocol: stdio (MCP) + a loopback HTTP server the Lightroom plug-in polls.
// All logging goes to stderr: stdout belongs to the MCP transport.

import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { Bridge } from './bridge.mjs';
import { buildTools } from './tools.mjs';

const READ_ONLY = new Set([
  'status', 'list_photos', 'get_selected_photos', 'get_photo_details', 'render_preview',
  'get_develop_settings', 'list_presets', 'list_collections',
]);

function parsePort() {
  const raw = process.env.LIGHTROOM_MCP_PORT;
  if (!raw) return 8790;
  const port = Number(raw);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    console.error(`[lightroom-mcp] ignoring invalid LIGHTROOM_MCP_PORT "${raw}"`);
    return 8790;
  }
  return port;
}

async function main() {
  const bridge = new Bridge({ port: parsePort() });
  try {
    await bridge.start();
  } catch (err) {
    // Not fatal: tools will report the problem instead of crashing the client.
    console.error(`[lightroom-mcp] could not start the bridge: ${err.message}`);
  }

  const server = new McpServer({
    name: 'lightroom',
    version: '0.1.0',
  });

  for (const tool of buildTools(bridge)) {
    server.registerTool(
      tool.name,
      {
        title: tool.title,
        description: tool.description,
        inputSchema: tool.inputSchema,
        annotations: {
          readOnlyHint: READ_ONLY.has(tool.name),
          destructiveHint: !READ_ONLY.has(tool.name),
          idempotentHint: tool.name !== 'create_collection' && tool.name !== 'snapshots',
          openWorldHint: false,
        },
      },
      async (args) => {
        try {
          return await tool.handler(args ?? {});
        } catch (err) {
          console.error(`[lightroom-mcp] ${tool.name} failed: ${err.stack || err}`);
          return {
            isError: true,
            content: [{ type: 'text', text: `Error: ${err.message || err}` }],
          };
        }
      },
    );
  }

  const transport = new StdioServerTransport();
  // The SDK's stdio transport calls onclose() from inside close(), so closing
  // the transport re-enters this handler. Guard it: without a flag, one SIGTERM
  // produced a thousand recursive shutdowns and a stack overflow.
  let shuttingDown = false;
  const shutdown = (reason) => {
    if (shuttingDown) return;
    shuttingDown = true;
    console.error(`[lightroom-mcp] shutting down (${reason})`);
    bridge.close();
    server.close?.().catch(() => {});
    process.exit(0);
  };
  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  transport.onclose = () => shutdown('client disconnected');
  // The transport never emits close on its own when the client hangs up
  // (it only listens for data and errors), so watch for stdin reaching EOF -
  // otherwise a session that closes the pipe leaves a server running forever.
  process.stdin.on('end', () => shutdown('stdin closed'));
  process.stdin.on('close', () => shutdown('stdin closed'));

  await server.connect(transport);
}

main().catch((err) => {
  console.error(`[lightroom-mcp] fatal: ${err.stack || err}`);
  process.exit(1);
});
