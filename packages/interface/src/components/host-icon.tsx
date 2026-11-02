import { useEffect, useState } from "react";
import type { BrandIcon } from "@ccbar/host-api/window";
import { ServiceIcon } from "@/components/service-icon";
import { cn } from "@/lib/utils";

export function HostIcon({
  icon,
  name,
  dark,
  size = 22,
  className,
}: {
  icon: BrandIcon;
  name: string;
  dark: boolean;
  size?: number;
  className?: string;
}) {
  const [failed, setFailed] = useState(false);
  useEffect(() => setFailed(false), [icon.dataURI]);
  const color = dark ? icon.darkHex : icon.lightHex;
  const dataURI = icon.dataURI?.startsWith("data:image/") ? icon.dataURI : null;
  if (!dataURI || failed)
    return (
      <ServiceIcon
        name={name}
        color={color}
        size={size}
        className={className}
      />
    );
  return (
    <span
      className={cn(
        "inline-flex shrink-0 items-center justify-center overflow-hidden",
        className,
      )}
      style={{
        width: size,
        height: size,
        borderRadius: Math.max(3, size * 0.27),
        backgroundColor: icon.kind === "favicon" ? "#fff" : color,
        boxShadow: "inset 0 0 0 0.5px rgba(0,0,0,0.12)",
      }}
    >
      <img
        src={dataURI}
        alt=""
        className={cn(
          "block",
          icon.fillsTile
            ? "size-full object-cover"
            : "size-full object-contain p-[16%]",
        )}
        onError={() => setFailed(true)}
        draggable={false}
      />
    </span>
  );
}
