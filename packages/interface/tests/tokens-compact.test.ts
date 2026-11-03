import { expect, it } from "vitest";
import { formatTokensCompact } from "@/lib/display";

it.each([
  [9_999, "9,999"],
  [10_000, "10K"],
  [48_210, "48.2K"],
  [189_400, "189K"],
  [999_960, "1M"],
  [18_200_000, "18.2M"],
  [2_340_000_000, "2.34B"],
])("formats %i with at most three significant digits", (value, expected) => {
  expect(formatTokensCompact(value)).toBe(expected);
});

it("promotes rounded thousand units without using three decimal places", () => {
  expect(formatTokensCompact(999_499)).toBe("999K");
  expect(formatTokensCompact(999_500)).toBe("1M");
  expect(formatTokensCompact(999_960_000)).toBe("1B");
});
