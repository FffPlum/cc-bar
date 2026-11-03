// Match the rendered Sky swatches at https://ui.shadcn.com/colors (2026-11-03).
// These values differ slightly from the installed Tailwind default palette.
const skyColors = [
  "oklch(0.98 0.01 237)", // sky-50
  "oklch(0.95 0.03 237)", // sky-100
  "oklch(0.90 0.06 231)", // sky-200
  "oklch(0.83 0.10 230)", // sky-300
  "oklch(0.75 0.14 233)", // sky-400
  "oklch(0.68 0.15 237)", // sky-500
  "oklch(0.59 0.14 242)", // sky-600
  "oklch(0.50 0.12 243)", // sky-700
  "oklch(0.44 0.10 241)", // sky-800
  "oklch(0.39 0.08 241)", // sky-900
  "oklch(0.29 0.06 243)", // sky-950
] as const;

// Fixed 100K–1B bounds keep colors comparable across filters and loaded years.
export function heatmapTokenIntensity(tokens: number): number {
  if (!(tokens > 0)) return 0;
  return Math.max(0, Math.min(1, (Math.log10(tokens) - 5) / 4));
}

export function heatmapColorAtIntensity(intensity: number): string {
  const clamped = intensity > 0 ? Math.min(1, intensity) : 0;
  const position = clamped * (skyColors.length - 1);
  const index = Math.floor(position);
  const start = skyColors[index]!;
  const fraction = position - index;
  if (fraction === 0) return start;

  // Interpolate only adjacent swatches so every official shade is preserved.
  return `color-mix(in oklab, ${start}, ${skyColors[index + 1]!} ${fraction * 100}%)`;
}
