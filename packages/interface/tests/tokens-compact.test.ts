import { expect, it } from "vitest";
import { formatTokensCompact } from "@/lib/display";

it.each([
  [9_999, "9,999", "9,999.00"],
  [10_000, "10K", "10.00K"],
  [48_210, "48.2K", "48.21K"],
  [189_400, "189K", "189.40K"],
  [999_960, "1M", "1.00M"],
  [18_200_000, "18.2M", "18.20M"],
  [2_340_000_000, "2.34B", "2.34B"],
])(
  "formats %i using shared units with default or fixed precision",
  (value, expected, fixed) => {
    expect(formatTokensCompact(value)).toBe(expected);
    expect(formatTokensCompact(value, 2)).toBe(fixed);
  },
);

it("promotes rounded thousand units without using three decimal places", () => {
  expect(formatTokensCompact(999_499)).toBe("999K");
  expect(formatTokensCompact(999_500)).toBe("1M");
  expect(formatTokensCompact(999_960_000)).toBe("1B");
});
