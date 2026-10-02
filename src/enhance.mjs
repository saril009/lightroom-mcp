// Histogram analysis + the auto-enhance heuristics.
//
// Lightroom's own Auto Tone only works on the active photo in the Develop
// module; this runs anywhere, on any number of photos, by decoding the JPEG
// preview the plug-in renders for us. It only ever proposes tone/presence
// adjustments - the same knobs a human would reach for first.

import { decode } from 'jpeg-js';

const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
const round = (v, places = 0) => {
  const f = 10 ** places;
  return Math.sign(v) * Math.round(Math.abs(v) * f) / f;
};

/** Decodes a JPEG and returns luminance/colour statistics. */
export function analyze(buffer) {
  const { width, height, data } = decode(buffer, { useTArray: true });

  const histogram = new Uint32Array(256);
  const totalPixels = width * height;
  // Stride keeps huge previews cheap; still ~1M+ samples for a typical one.
  const step = totalPixels > 2_000_000 ? 2 : 1;

  let samples = 0;
  let sum = 0;
  let sumSq = 0;
  let satSum = 0;
  let clippedHigh = 0;
  let clippedLow = 0;

  for (let i = 0; i < totalPixels; i += step) {
    const o = i * 4;
    const r = data[o];
    const g = data[o + 1];
    const b = data[o + 2];

    const luma = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    const bin = luma < 0 ? 0 : luma > 255 ? 255 : luma | 0;
    histogram[bin] += 1;
    samples += 1;
    sum += luma;
    sumSq += luma * luma;

    const max = Math.max(r, g, b);
    const min = Math.min(r, g, b);
    satSum += max === 0 ? 0 : (max - min) / max;

    if (bin >= 253) clippedHigh += 1;
    if (bin <= 2) clippedLow += 1;
  }

  const mean = sum / samples;
  const std = Math.sqrt(Math.max(0, sumSq / samples - mean * mean));

  const percentile = (p) => {
    const target = p * samples;
    let acc = 0;
    for (let bin = 0; bin < 256; bin++) {
      acc += histogram[bin];
      if (acc >= target) return bin / 255;
    }
    return 1;
  };

  return {
    width,
    height,
    meanLuma: mean / 255,
    stdLuma: std / 255,
    meanSaturation: satSum / samples,
    clippedHigh: clippedHigh / samples,
    clippedLow: clippedLow / samples,
    p01: percentile(0.01),
    p25: percentile(0.25),
    p50: percentile(0.5),
    p75: percentile(0.75),
    p99: percentile(0.99),
  };
}

const PROFILES = {
  // Tone plus a *subtle* vibrance trim - the safe default.
  natural: { tone: 1, presence: 0.4, vibranceCap: 15, clarity: false, dehaze: false },
  // More bite: adds clarity, full vibrance and a haze check.
  punchy: { tone: 1, presence: 1, vibranceCap: 35, clarity: true, dehaze: true },
  // Gentle: exposure and endpoint recovery only, no shadow lifting.
  soft: { tone: 0.7, presence: 0, vibranceCap: 0, clarity: false, dehaze: false, gentle: true },
};

/**
 * Turns statistics into Lightroom-ready develop settings.
 * Returns { settings, reason } where settings is {} when nothing is needed.
 * strength 0 always yields no settings at all.
 */
export function suggestSettings(stats, { profile = 'natural', strength = 1 } = {}) {
  const cfg = PROFILES[profile] ?? PROFILES.natural;
  const s = clamp(Number(strength) || 0, 0, 1.5);
  const settings = {};

  // --- exposure: move the median toward mid-grey --------------------------
  // Never brighten an image that is already clipping badly - a blown sky plus
  // a dark foreground has a dark median, but pushing exposure up would only
  // eat more highlight detail. Above 5% clipping the correction turns
  // negative, and the more that is clipped, the more we pull back.
  const median = Math.max(stats.p50, 0.004);
  let exposureEv = Math.log2(0.46 / median);
  if (stats.clippedHigh > 0.05) {
    exposureEv = Math.min(exposureEv, (0.05 - stats.clippedHigh) * 5);
  }
  exposureEv = clamp(round(exposureEv * s, 2), -1, 1);
  if (Math.abs(exposureEv) >= 0.03) settings.exposure = exposureEv;

  // --- endpoints: set the white and black points from the 1st/99th pct ----
  const whites = clamp(round((0.97 - stats.p99) * 150 * cfg.tone * s), -100, 100);
  if (Math.abs(whites) >= 2) settings.whites = whites;

  const blacks = clamp(round((0.03 - stats.p01) * 150 * cfg.tone * s), -100, 100);
  if (Math.abs(blacks) >= 2) settings.blacks = blacks;

  // --- highlights: recover clipped detail ---------------------------------
  const highlights = clamp(round(-stats.clippedHigh * 400 * cfg.tone * s), -80, 0);
  if (Math.abs(highlights) >= 3) settings.highlights = highlights;

  // --- shadows: open up a dark lower quartile ----------------------------
  if (!cfg.gentle) {
    const shadows = clamp(round((0.22 - stats.p25) * 120 * cfg.tone * s), -40, 70);
    if (Math.abs(shadows) >= 4) settings.shadows = shadows;
  }

  // --- contrast: only lift flat images, never flatten contrasty ones ------
  if (!cfg.gentle && stats.stdLuma < 0.27) {
    const contrast = clamp(round((0.27 - stats.stdLuma) * 90 * cfg.tone * s), 0, 35);
    if (contrast >= 3) settings.contrast = contrast;
  }

  // --- presence ------------------------------------------------------------
  if (cfg.clarity && !cfg.gentle) {
    const clarity = clamp(round((0.27 - stats.stdLuma) * 60 * s + 8 * s), 0, 40);
    if (clarity >= 3) settings.clarity = clarity;
  }
  if (cfg.presence > 0 && cfg.vibranceCap > 0) {
    const vibrance = clamp(
      round((0.3 - stats.meanSaturation) * 120 * cfg.presence * s), 0, cfg.vibranceCap,
    );
    if (vibrance >= 3) settings.vibrance = vibrance;
  }
  if (cfg.dehaze && stats.stdLuma < 0.19 && stats.meanLuma > 0.5) {
    const dehaze = clamp(round((0.19 - stats.stdLuma) * 90 * s), 0, 25);
    if (dehaze >= 3) settings.dehaze = dehaze;
  }

  const changed = Object.keys(settings).length > 0;
  return {
    settings,
    changed,
    // The exposure decision, in stops. Returned so callers can report what was
    // actually decided rather than re-deriving it from the median - the old
    // `exposureStops: stats.p50` field just duplicated medianLuma under a
    // misleading name.
    exposureEv,
    reason: changed
      ? `median luma ${(stats.p50 * 100).toFixed(0)}%, contrast (std) `
        + `${(stats.stdLuma * 100).toFixed(0)}%, clipped highlights `
        + `${(stats.clippedHigh * 100).toFixed(1)}%, mean saturation `
        + `${(stats.meanSaturation * 100).toFixed(0)}%`
      : 'already well balanced - no tone changes proposed',
  };
}

export function autoEnhance(buffer, options = {}) {
  const stats = analyze(buffer);
  const suggestion = suggestSettings(stats, options);
  return { ...suggestion, stats };
}
