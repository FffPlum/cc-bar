import { cn } from "@/lib/utils";

export function ServiceIcon({
  name,
  color,
  size = 22,
  className,
}: {
  name: string;
  color: string;
  size?: number;
  className?: string;
}) {
  return (
    <span
      aria-hidden="true"
      className={cn(
        "inline-flex shrink-0 items-center justify-center overflow-hidden font-semibold",
        className,
      )}
      style={{
        width: size,
        height: size,
        borderRadius: Math.max(3, size * 0.27),
        backgroundColor: color,
        color: contrastingText(color),
        fontSize: Math.max(9, size * 0.48),
        boxShadow:
          "inset 0 0 0 0.5px color-mix(in srgb, currentColor 12%, transparent)",
      }}
    >
      {name.trim().charAt(0).toUpperCase() || "?"}
    </span>
  );
}

export function ServiceMark({
  color,
  size = 8,
}: {
  color: string;
  size?: number;
}) {
  return (
    <span
      aria-hidden="true"
      className="inline-block shrink-0 rounded-[2px]"
      style={{ width: size, height: size, backgroundColor: color }}
    />
  );
}

function contrastingText(hex: string): string {
  const value = hex.replace("#", "");
  if (!/^[\da-f]{6}$/i.test(value)) return "#fff";
  const red = Number.parseInt(value.slice(0, 2), 16);
  const green = Number.parseInt(value.slice(2, 4), 16);
  const blue = Number.parseInt(value.slice(4, 6), 16);
  return red * 0.299 + green * 0.587 + blue * 0.114 > 160 ? "#1d1d1f" : "#fff";
}
