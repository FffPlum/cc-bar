export type TokenAxisMode = "linear" | "log";

/** A weekly Token axis whose labels and marks share the same value mapping. */
export function buildTokenAxisScale(
  values: readonly number[],
  mode: TokenAxisMode = "linear",
) {
  const peak = Math.max(0, ...values.filter(Number.isFinite));
  // Round up in 50-unit steps at the peak's magnitude:
  // 837.2M uses 50M steps (850M); 1.01B uses 0.5B steps (1.5B).
  // Keep tiny integer ranges readable (0 / 1 / 2 instead of 0 / 0.5 / 1).
  const step = 50 * 10 ** (Math.floor(Math.log10(peak || 1)) - 2);
  const maximum =
    peak < 10
      ? Math.max(2, Math.ceil(peak / 2) * 2)
      : Math.ceil(peak / step) * step;
  const logMaximum = Math.log1p(maximum);
  const normalize = (value: number) => {
    const clamped = Number.isFinite(value)
      ? Math.max(0, Math.min(maximum, value))
      : 0;
    // Equivalent to log10(1 + T) / log10(1 + maximum), including zero.
    return mode === "log"
      ? Math.log1p(clamped) / logMaximum
      : clamped / maximum;
  };

  let middle = maximum / 2;
  if (mode === "log") {
    // Keep three legible ticks in the compact chart. Choose a 1–2–5 value
    // near the visual midpoint rather than labelling a logarithm as Tokens.
    middle = 1;
    for (let magnitude = 1; magnitude < maximum; magnitude *= 10) {
      for (const multiplier of [1, 2, 5]) {
        const candidate = multiplier * magnitude;
        if (
          candidate < maximum &&
          Math.abs(normalize(candidate) - 0.5) <
            Math.abs(normalize(middle) - 0.5)
        ) {
          middle = candidate;
        }
      }
    }
  }

  return {
    maximum,
    normalize,
    ticks: [0, middle, maximum].map((value) => ({
      value,
      label: formatTokenAxisTick(value),
    })),
  };
}

function formatTokenAxisTick(value: number): string {
  const [divisor, suffix] =
    value >= 1_000_000_000
      ? ([1_000_000_000, "B"] as const)
      : value >= 1_000_000
        ? ([1_000_000, "M"] as const)
        : value >= 1_000
          ? ([1_000, "K"] as const)
          : ([1, ""] as const);
  // Preserve fractional midpoints, such as 12.5K below a 25K ceiling.
  return (
    new Intl.NumberFormat("en-US", {
      maximumFractionDigits: 3,
    }).format(value / divisor) + suffix
  );
}
