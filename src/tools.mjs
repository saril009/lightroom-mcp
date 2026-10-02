// MCP tool definitions. Everything except auto_enhance is a thin, pass-through
// wrapper around one Lightroom plug-in handler; auto_enhance is orchestrated
// here because it needs to decode JPEG pixels (which Lua cannot do).

import { readFileSync } from 'node:fs';
import { z } from 'zod';
import { previewDir } from './bridge.mjs';
import { autoEnhance } from './enhance.mjs';

const PHOTOS_DESC =
  'Photo uuid(s) returned by list_photos / get_selected_photos. Accepts a single '
  + 'string or an array. Omit to use the photos currently selected in Lightroom.';

const json = (data) => ({
  content: [{ type: 'text', text: JSON.stringify(data, null, 2) }],
});

const fail = (err) => ({
  isError: true,
  content: [{ type: 'text', text: `Error: ${err.message || err}` }],
});

const uuidList = () =>
  z.union([z.string(), z.array(z.string())]).optional().describe(PHOTOS_DESC);

/**
 * Renders one preview and returns { buffer, path, bytes }.
 * Set includeBase64 to also get the base64 payload - only render_preview needs
 * it, so auto_enhance's per-photo loop no longer pays for a large string it
 * never reads.
 */
async function readPreview(bridge, { uuid, longEdge = 1200, destDir = previewDir(), includeBase64 = false }) {
  const result = await bridge.call('render_preview', { photos: [uuid], longEdge, destDir });
  const buffer = readFileSync(result.path);
  return {
    buffer,
    path: result.path,
    bytes: result.bytes,
    ...(includeBase64 ? { base64: buffer.toString('base64') } : {}),
  };
}

/** Reads the pixel dimensions out of a JPEG header (no decoding needed). */
function jpegSize(buffer) {
  if (buffer.length < 4 || buffer[0] !== 0xff || buffer[1] !== 0xd8) return null;
  let i = 2;
  while (i + 9 < buffer.length) {
    if (buffer[i] !== 0xff) { i += 1; continue; }
    const marker = buffer[i + 1];
    if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
      i += 2; continue;
    }
    const length = buffer.readUInt16BE(i + 2);
    // SOF0-SOF15, excluding DHT (c4), JPG (c8) and DAC (cc)
    if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
      return { height: buffer.readUInt16BE(i + 5), width: buffer.readUInt16BE(i + 7) };
    }
    i += 2 + length;
  }
  return null;
}

export function buildTools(bridge) {
  return [
    // ---------------------------------------------------------------------
    {
      name: 'status',
      title: 'Lightroom connection status',
      description:
        'Check whether Lightroom Classic is connected, which catalog is open, what module '
        + '(Library/Develop) is active, the current selection, and the bridge port. Call this '
        + 'first if any other tool reports that Lightroom is not connected.',
      inputSchema: {},
      handler: async () => {
        const server = bridge.status();
        try {
          const lightroom = await bridge.call('status', {}, { timeoutMs: 15_000 });
          return json({ server, lightroom });
        } catch (err) {
          // The error says which problem it is: Lightroom being closed, or this
          // session failing to reach the instance that owns the plug-in port.
          const lightroomDown = err.message.includes('not connected');
          return json({
            server,
            lightroom: null,
            error: err.message,
            help: lightroomDown
              ? 'Start Lightroom Classic and check File > Plug-in Manager > '
                + 'Lightroom MCP Bridge. The plug-in polls '
                + `http://127.0.0.1:${server.plugInPort}/poll.`
              : 'This session could not reach the lightroom-classic-mcp instance '
                + 'that owns the plug-in port. See server.portConflictMessage; '
                + 'restarting this session will re-probe it.',
          });
        }
      },
    },

    // ---------------------------------------------------------------------
    {
      name: 'list_photos',
      title: 'Search the Lightroom catalog',
      description:
        'Search the catalog and return photo summaries (uuid, filename, path, rating, pick '
        + 'flag, colour label, dimensions, capture time, keywords). With no filters it returns '
        + 'the current selection, or every photo in the catalog if nothing is selected. '
        + 'Use the returned uuids for every '
        + 'other tool. Filters are ANDed together.',
      inputSchema: {
        query: z.string().optional().describe('Free-text search across all indexed metadata.'),
        filename: z.string().optional().describe('Substring of the file name.'),
        keywords: z.union([z.string(), z.array(z.string())]).optional()
          .describe('Match photos containing any of these keywords.'),
        minRating: z.number().min(0).max(5).optional(),
        maxRating: z.number().min(0).max(5).optional(),
        pick: z.enum(['flagged', 'unflagged', 'rejected']).optional(),
        colorLabel: z.enum(['red', 'yellow', 'green', 'blue', 'purple', 'none']).optional(),
        fileFormat: z.enum(['dng', 'raw', 'jpg', 'tiff', 'png', 'psd', 'video']).optional(),
        folder: z.string().optional().describe('Substring of the folder path.'),
        collection: z.string().optional().describe('Substring of a collection name.'),
        dateAfter: z.string().optional().describe('Captured after YYYY-MM-DD.'),
        dateBefore: z.string().optional().describe('Captured before YYYY-MM-DD.'),
        lastDays: z.number().optional().describe('Captured in the last N days.'),
        edited: z.boolean().optional().describe('true = has develop adjustments.'),
        treatment: z.enum(['grayscale', 'color']).optional(),
        aspect: z.enum(['portrait', 'landscape', 'square']).optional(),
        camera: z.string().optional().describe('Exact camera make/model string.'),
        lens: z.string().optional().describe('Exact lens string.'),
        isoMin: z.number().optional(),
        isoMax: z.number().optional(),
        sort: z.enum(['captureTime', 'fileName', 'extension']).optional()
          .describe('Default captureTime.'),
        ascending: z.boolean().optional().describe('Default false (newest first).'),
        limit: z.number().min(1).max(500).optional().describe('Default 50, max 500.'),
      },
      handler: async (args) => json(await bridge.call('list_photos', args)),
    },

    {
      name: 'get_selected_photos',
      title: 'Photos selected in Lightroom',
      description:
        'Return summaries for the photos currently selected in Lightroom. Returns an empty '
        + 'list (not an error) when nothing is selected.',
      inputSchema: {
        limit: z.number().min(1).max(500).optional().describe('Default 200.'),
      },
      handler: async (args) => json(await bridge.call('get_selected_photos', args)),
    },

    {
      name: 'get_photo_details',
      title: 'Full details for one photo',
      description:
        'Full metadata plus the complete develop settings table for a single photo. Use this '
        + 'to see exactly what is set before/after an edit.',
      inputSchema: {
        photos: uuidList(),
        includeDevelop: z.boolean().optional()
          .describe('Set false to skip the develop settings table. Default true.'),
      },
      handler: async (args) => json(await bridge.call('get_photo_details', args)),
    },

    // ---------------------------------------------------------------------
    {
      name: 'render_preview',
      title: 'Render a JPEG of a photo (with current edits)',
      description:
        'Renders the photo as it currently looks in Lightroom - including all develop '
        + 'settings - and returns it as an image plus its file path. This is the way to SEE a '
        + 'photo: read the returned path with your image-reading tool to inspect it, decide on '
        + 'edits, apply them, then render again to verify. Larger values give more detail but '
        + 'take longer to render.',
      inputSchema: {
        photos: uuidList(),
        longEdge: z.number().min(64).max(4096).optional()
          .describe('Requested long edge in pixels. Default 1200; Lightroom may return a '
            + 'larger existing preview.'),
      },
      handler: async (args) => {
        try {
          const photos = typeof args.photos === 'string' ? [args.photos] : args.photos;
          const uuid = photos?.[0];
          if (!uuid) {
            return fail(new Error('photos is required for render_preview '
              + '(it renders exactly one photo).'));
          }
          const preview = await readPreview(bridge, {
            uuid,
            longEdge: args.longEdge ?? 1200,
            includeBase64: true,
          });
          const size = jpegSize(preview.buffer);
          return {
            content: [
              {
                type: 'text',
                text: `Rendered preview: ${preview.path}\n`
                  + `Pixels: ${size ? `${size.width}x${size.height}` : 'unknown'}\n`
                  + `File: ${preview.bytes} bytes\n`
                  + 'Read this file to view the photo (it reflects the current develop '
                  + 'settings), then apply edits and render again to compare.',
              },
              { type: 'image', data: preview.base64, mimeType: 'image/jpeg' },
            ],
          };
        } catch (err) {
          return fail(err);
        }
      },
    },

    // ---------------------------------------------------------------------
    {
      name: 'get_develop_settings',
      title: 'Read develop settings',
      description: 'Return the develop settings table exactly as Lightroom stores it.',
      inputSchema: { photos: uuidList() },
      handler: async (args) => json(await bridge.call('get_develop_settings', args)),
    },

    {
      name: 'set_develop_settings',
      title: 'Apply develop adjustments',
      description:
        'Apply develop adjustments to one or more photos (merged with existing settings - '
        + 'only the keys you pass change). Friendly names are accepted: exposure (-5..5 in '
        + 'stops), contrast, highlights, shadows, whites, blacks, clarity, texture, dehaze, '
        + 'vibrance, saturation, temperature, tint, whitebalance (asShot|auto|custom|...), '
        + 'grayscale, sharpness, noise_reduction, color_noise_reduction, vignette, grain, '
        + 'tone_shadows|darks|lights|highlights, hue_*, sat_*, lum_* (e.g. hue_blue). '
        + 'Raw Lightroom keys (Exposure2012, PostCropVignetteAmount...) also work. Out-of-range '
        + 'values are clamped and reported back. Setting temperature/tint automatically switches '
        + 'white balance to custom.',
      inputSchema: {
        photos: uuidList(),
        settings: z.record(z.any())
          .describe('Object of adjustments, e.g. {"exposure": 0.35, "shadows": 25}.'),
        historyLabel: z.string().optional()
          .describe('Undo history label for this change.'),
      },
      handler: async (args) => json(await bridge.call('set_develop_settings', args)),
    },

    {
      name: 'auto_enhance',
      title: 'Auto-analyse and enhance photos',
      description:
        'Analyses a rendered preview of each photo (exposure, contrast, clipping, saturation) '
        + 'and applies conservative corrective tone/presence adjustments. Works on any number '
        + 'of photos from any Lightroom module - unlike auto_tone, it never touches the UI or '
        + 'the selection. Returns the measurements and the exact settings applied per photo. '
        + 'Profiles: "natural" (default: tone plus a subtle vibrance trim), '
        + '"punchy" (adds clarity, full vibrance, dehaze), '
        + '"soft" (exposure and endpoints only).',
      inputSchema: {
        photos: uuidList(),
        profile: z.enum(['natural', 'punchy', 'soft']).optional()
          .describe('Default "natural".'),
        strength: z.number().min(0).max(1.5).optional()
          .describe('0 = do nothing, 1 = full strength (default).'),
        verify: z.boolean().optional()
          .describe('Re-render each photo after editing so you can inspect the result.'),
        dryRun: z.boolean().optional()
          .describe('Analyse and report the proposed settings without applying them.'),
      },
      handler: async (args) => {
        try {
          let uuids = args.photos;
          if (typeof uuids === 'string') uuids = [uuids];
          if (!uuids || uuids.length === 0) {
            const selection = await bridge.call('get_selected_photos', {}, { timeoutMs: 15_000 });
            uuids = (selection.photos || []).map((p) => p.uuid);
          }
          if (uuids.length === 0) {
            return fail(new Error('No photos to enhance: nothing is selected and no uuids '
              + 'were given.'));
          }
          if (uuids.length > 50) {
            return fail(new Error(`That is ${uuids.length} photos; do at most 50 per call to `
              + 'keep the Lightroom UI responsive. Loop over batches instead.'));
          }

          const profile = args.profile ?? 'natural';
          const strength = args.strength ?? 1;
          const dryRun = args.dryRun === true;
          const results = [];

          for (const uuid of uuids) {
            if (!(await bridge.pluginConnectedAsync())) {
              return fail(new Error('Lightroom disconnected part-way through the batch.'));
            }
            const preview = await readPreview(bridge, { uuid, longEdge: 640 });
            const analysis = autoEnhance(preview.buffer, { profile, strength });

            const entry = {
              uuid,
              preview: preview.path,
              measurements: {
                medianLuma: Number(analysis.stats.p50.toFixed(3)),
                contrast: Number(analysis.stats.stdLuma.toFixed(3)),
                clippedHighlightsPct: Number((analysis.stats.clippedHigh * 100).toFixed(2)),
                meanSaturation: Number(analysis.stats.meanSaturation.toFixed(3)),
                // Stops of exposure the heuristic decided on (negative = pull
                // back). Was previously the median luma under this name.
                exposureStops: Number((analysis.exposureEv ?? 0).toFixed(2)),
              },
              proposed: analysis.settings,
              reason: analysis.reason,
            };

            if (analysis.changed && !dryRun) {
              const applied = await bridge.call('set_develop_settings', {
                photos: [uuid],
                settings: analysis.settings,
                historyLabel: `auto_enhance (${profile})`,
              });
              entry.applied = applied.applied === 1;
              entry.settingsAfter = applied.settings;
              if (applied.clamped?.length) entry.clamped = applied.clamped;
            } else {
              entry.applied = false;
            }

            if (args.verify === true && entry.applied && !dryRun) {
              const after = await readPreview(bridge, { uuid, longEdge: 640 });
              entry.previewAfter = after.path;
            }

            results.push(entry);
          }

          return json({
            profile,
            strength,
            dryRun,
            count: results.length,
            applied: results.filter((r) => r.applied).length,
            results,
            note: dryRun
              ? 'Nothing was changed (dryRun). Re-run without dryRun to apply.'
              : 'Render a preview again to visually verify the result.',
          });
        } catch (err) {
          return fail(err);
        }
      },
    },

    {
      name: 'auto_tone',
      title: "Lightroom's Auto Tone",
      description:
        "Uses Adobe's own Auto Tone (and optionally Auto White Balance) - a stronger, more "
        + 'photographic result than auto_enhance. Limitation: Lightroom only applies it to the '
        + 'photo currently shown in the Develop module, so this tool switches module and changes '
        + 'the selection while it runs (and restores the module afterwards). Requires '
        + 'switchToDevelop=true if you are not already in Develop.',
      inputSchema: {
        photos: uuidList(),
        switchToDevelop: z.boolean().optional()
          .describe('Switch to the Develop module if needed. Default false.'),
        whiteBalance: z.boolean().optional()
          .describe('Also run Auto White Balance. Default false.'),
        settleSeconds: z.number().min(0.1).max(5).optional()
          .describe('Wait after selecting each photo so Develop can load it. Default 0.6.'),
      },
      handler: async (args) => json(await bridge.call('auto_tone', args)),
    },

    {
      name: 'reset_develop_settings',
      title: 'Reset adjustments to neutral',
      description:
        'Resets tone, presence, white balance and the parametric tone curve to their defaults. '
        + 'The colour curve, masks, local adjustments, spot removal and sharpening/noise are '
        + 'left untouched (pass resetCrop / resetEffects to clear crop, vignette and grain too) '
        + '- so this is safe to run before trying a new look.',
      inputSchema: {
        photos: uuidList(),
        resetCrop: z.boolean().optional(),
        resetEffects: z.boolean().optional()
          .describe('Also reset vignette, grain and split toning saturation.'),
      },
      handler: async (args) => json(await bridge.call('reset_develop_settings', args)),
    },

    {
      name: 'copy_develop_settings',
      title: 'Copy settings photo to photo',
      description:
        'Copy the complete develop settings from a source photo onto other photos (the '
        + 'equivalent of Ctrl+Shift+C / Ctrl+Shift+V).',
      inputSchema: {
        source: z.union([z.string(), z.array(z.string())])
          .describe('The photo to copy FROM (uuid).'),
        photos: uuidList(),
      },
      handler: async (args) => json(await bridge.call('copy_develop_settings', args)),
    },

    // ---------------------------------------------------------------------
    {
      name: 'list_presets',
      title: 'List develop presets',
      description:
        'List the develop presets installed in Lightroom, with the folder each lives in. '
        + 'Identify a preset by its path (unique) or exact name for apply_preset.',
      inputSchema: {
        query: z.string().optional().describe('Substring filter on preset or folder name.'),
        limit: z.number().min(1).max(1000).optional().describe('Default 300.'),
      },
      handler: async (args) => json(await bridge.call('list_presets', args)),
    },

    {
      name: 'apply_preset',
      title: 'Apply a develop preset',
      description:
        'Apply an installed develop preset to one or more photos. Use list_presets first to '
        + 'get the name/path. Preset amount 0-200 (100 = as authored).',
      inputSchema: {
        photos: uuidList(),
        preset: z.string().describe('Preset name or path from list_presets.'),
        amount: z.number().min(0).max(200).optional().describe('Default 100 (full strength).'),
      },
      handler: async (args) => json(await bridge.call('apply_preset', args)),
    },

    {
      name: 'snapshots',
      title: 'Develop snapshots (undo points)',
      description:
        'Create, list or restore develop snapshots - named undo points. Take a snapshot before '
        + 'experimenting on a photo, then action=apply to roll back if the result is worse.',
      inputSchema: {
        photos: uuidList(),
        action: z.enum(['list', 'create', 'apply']).describe('Default "list".'),
        name: z.string().optional().describe('Snapshot name (create/apply).'),
        id: z.string().optional().describe('Snapshot id (apply).'),
        updateExisting: z.boolean().optional()
          .describe('Overwrite a snapshot with the same name on create.'),
      },
      handler: async (args) => json(await bridge.call('snapshots', args)),
    },

    // ---------------------------------------------------------------------
    {
      name: 'set_marks',
      title: 'Rate / flag / label photos',
      description:
        'Set rating (0-5 stars), pick flag (flagged / unflagged / rejected), colour label, '
        + 'title or caption on photos. Provide any combination of the fields.',
      inputSchema: {
        photos: uuidList(),
        rating: z.number().min(0).max(5).optional(),
        pick: z.enum(['flagged', 'unflagged', 'rejected']).optional(),
        colorLabel: z.enum(['red', 'yellow', 'green', 'blue', 'purple', 'none']).optional(),
        title: z.string().optional(),
        caption: z.string().optional(),
      },
      handler: async (args) => json(await bridge.call('set_marks', args)),
    },

    {
      name: 'set_keywords',
      title: 'Add or remove keywords',
      description:
        'Add and/or remove keywords on photos. Missing keywords are created (at the keyword '
        + 'root, export-visible); existing ones are reused, including nested ones.',
      inputSchema: {
        photos: uuidList(),
        add: z.union([z.string(), z.array(z.string())]).optional()
          .describe('Keyword(s) to add.'),
        remove: z.union([z.string(), z.array(z.string())]).optional()
          .describe('Keyword(s) to remove.'),
      },
      handler: async (args) => json(await bridge.call('set_keywords', args)),
    },

    {
      name: 'list_collections',
      title: 'List collections',
      description: 'List collections and collection sets (add includeCounts=true for sizes).',
      inputSchema: {
        query: z.string().optional().describe('Substring filter on the name.'),
        includeCounts: z.boolean().optional(),
        limit: z.number().min(1).max(1000).optional().describe('Default 300.'),
      },
      handler: async (args) => json(await bridge.call('list_collections', args)),
    },

    {
      name: 'create_collection',
      title: 'Create a collection',
      description: 'Create a collection (optionally inside an existing collection set).',
      inputSchema: {
        name: z.string().describe('New collection name.'),
        parent: z.string().optional().describe('Name of an existing collection set.'),
      },
      handler: async (args) => json(await bridge.call('create_collection', args)),
    },

    {
      name: 'add_to_collection',
      title: 'Add photos to a collection',
      description: 'Add (or remove) photos from a collection - a non-destructive grouping.',
      inputSchema: {
        photos: uuidList(),
        collection: z.string().describe('Collection name from list_collections.'),
        remove: z.boolean().optional().describe('Remove instead of add.'),
      },
      handler: async (args) => json(await bridge.call('add_to_collection', args)),
    },

    // ---------------------------------------------------------------------
    {
      name: 'export_photos',
      title: 'Export photos to disk',
      description:
        'Export photos with Lightroom\'s own exporter (full quality, with develop settings '
        + 'baked in) and return the resulting file paths. Use longEdge to resize, quality 0-1 '
        + 'for JPEG.',
      inputSchema: {
        photos: uuidList(),
        destination: z.string().describe('Absolute output folder; created if missing.'),
        format: z.enum(['jpeg', 'tiff', 'png', 'dng', 'psd']).optional()
          .describe('Default jpeg.'),
        quality: z.number().min(0).max(1).optional().describe('JPEG quality, default 0.9.'),
        longEdge: z.number().optional().describe('Constrain the long edge in pixels.'),
        colorSpace: z.enum(['sRGB', 'adobeRGB']).optional().describe('Default sRGB.'),
        bitDepth: z.number().optional().describe('8 or 16, for tiff/psd. Default 8.'),
        includeWatermark: z.boolean().optional(),
        collision: z.enum(['overwrite', 'skip', 'rename', 'ask']).optional()
          .describe('What to do if the file already exists. Default "overwrite". '
            + '"ask" makes Lightroom show a dialog and waits for you, so avoid it.'),
      },
      handler: async (args) => json(await bridge.call('export_photos', args)),
    },
  ];
}
