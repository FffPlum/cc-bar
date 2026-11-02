import { useEffect, useState } from "react";
import type {
  BrandColorPatch,
  BrandColorSetting,
} from "@ccbar/host-api/window";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from "@/components/ui/popover";
import { useTranslation } from "@/lib/i18n";

export function BrandColorEditor({
  brand,
  recent,
  presets,
  disabled,
  onApply,
}: {
  brand: BrandColorSetting;
  recent: string[];
  presets: BrandColorSetting[];
  disabled: boolean;
  onApply: (patch: BrandColorPatch) => void;
}) {
  const t = useTranslation();
  const [open, setOpen] = useState(false);
  const [hex, setHex] = useState(brand.customHex ?? brand.defaultLightHex);
  useEffect(() => {
    setHex(brand.customHex ?? brand.defaultLightHex);
  }, [brand.customHex, brand.defaultLightHex, open]);
  const valid = /^#[0-9a-fA-F]{6}$/.test(hex);
  const colors = [
    ...new Set([...recent, ...presets.map((item) => item.defaultLightHex)]),
  ];
  const apply = () => {
    if (valid) {
      onApply({ brand: brand.brand, mode: "custom", customHex: hex });
      setOpen(false);
    }
  };
  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger
        render={<Button size="sm" variant="outline" disabled={disabled} />}
      >
        {brand.mode === "brand" ? t("Brand", "品牌色") : brand.customHex}
      </PopoverTrigger>
      <PopoverContent className="w-64 space-y-3">
        <p className="text-[12px] font-medium">
          {t("Service color", "服务颜色")}
        </p>
        <div className="grid grid-cols-6 gap-2">
          {colors.map((color) => (
            <button
              key={color}
              type="button"
              aria-label={color}
              onClick={() => setHex(color)}
              className="size-7 rounded-md border border-black/10 focus-visible:ring-2"
              style={{ backgroundColor: color }}
            />
          ))}
        </div>
        <form
          onSubmit={(event) => {
            event.preventDefault();
            apply();
          }}
          className="space-y-3"
        >
          <div className="flex gap-2">
            <input
              aria-label={t("Choose color", "选择颜色")}
              type="color"
              className="h-8 w-10 rounded border"
              value={valid ? hex : brand.defaultLightHex}
              onChange={(event) => setHex(event.target.value)}
            />
            <Input
              aria-label={t("Hex color", "十六进制颜色")}
              value={hex}
              onChange={(event) => setHex(event.target.value)}
              maxLength={7}
              spellCheck={false}
            />
          </div>
          {!valid && (
            <p className="text-xs text-red-600">
              {t(
                "Use a six-digit color such as #4D6BFE.",
                "请输入六位颜色，如 #4D6BFE。",
              )}
            </p>
          )}
          <div className="flex justify-between gap-2">
            <Button
              type="button"
              size="sm"
              variant="outline"
              onClick={() => {
                onApply({ brand: brand.brand, mode: "brand" });
                setOpen(false);
              }}
            >
              {t("Brand color", "品牌色")}
            </Button>
            <Button type="submit" size="sm" disabled={!valid || disabled}>
              {t("Apply", "应用")}
            </Button>
          </div>
        </form>
      </PopoverContent>
    </Popover>
  );
}
