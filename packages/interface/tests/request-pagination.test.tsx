import { fireEvent, render, screen } from "@testing-library/react";
import { expect, it, vi } from "vitest";
import { RequestPagination } from "@/features/stats/request-pagination";
import { LanguageProvider } from "@/lib/i18n";

const setup = (totalCount: number | null = 80, page = 2) => {
  const onPageChange = vi.fn();
  render(
    <LanguageProvider language="en">
      <RequestPagination
        totalCount={totalCount}
        page={page}
        pageSize={12}
        disabled={false}
        onPageChange={onPageChange}
        onPageSizeChange={vi.fn()}
      />
    </LanguageProvider>,
  );
  return {
    input: screen.getByRole("textbox", {
      name: "Current page",
    }) as HTMLInputElement,
    onPageChange,
  };
};

it("commits a typed page once on Enter and clamps it to the available range", () => {
  const { input, onPageChange } = setup();
  input.focus();
  fireEvent.change(input, { target: { value: "99" } });
  fireEvent.keyDown(input, { key: "Enter" });
  expect(onPageChange).toHaveBeenCalledExactlyOnceWith(7);
  expect(input.value).toBe("7");
});

it.each(["", "abc", "2.5", "-1", "9007199254740992"])(
  "restores the current page for invalid input %s",
  (value) => {
    const { input, onPageChange } = setup();
    fireEvent.change(input, { target: { value } });
    fireEvent.blur(input);
    expect(input.value).toBe("2");
    expect(onPageChange).not.toHaveBeenCalled();
  },
);

it("cancels editing with Escape without changing pages", () => {
  const { input, onPageChange } = setup();
  fireEvent.change(input, { target: { value: "4" } });
  fireEvent.keyDown(input, { key: "Escape" });
  fireEvent.blur(input);
  expect(input.value).toBe("2");
  expect(onPageChange).not.toHaveBeenCalled();
});

it("keeps the footer visible for zero records and disables navigation at both ends", () => {
  const { input } = setup(0, 1);
  expect(screen.getByText("0 records")).toBeTruthy();
  expect(screen.getByText("/ 1")).toBeTruthy();
  expect(input.value).toBe("1");
  for (const name of ["Previous", "Next"])
    expect(
      (screen.getByRole("button", { name }) as HTMLButtonElement).disabled,
    ).toBe(true);
});

it("does not present a loading count as zero", () => {
  const { input } = setup(null, 1);
  expect(screen.getByText("— records")).toBeTruthy();
  expect(screen.getByText("/ —")).toBeTruthy();
  expect(input.disabled).toBe(true);
});
