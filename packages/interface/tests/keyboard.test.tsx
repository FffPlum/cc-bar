import { fireEvent, render, screen } from "@testing-library/react";
import { expect, it, vi } from "vitest";
import { useListKeyboard } from "@/hooks/list-keyboard";
it("keeps arrow navigation out of text fields and scrolls opaque row IDs", () => {
  const onSelect = vi.fn();
  const scroll = vi.spyOn(Element.prototype, "scrollIntoView");
  function List() {
    const keyboard = useListKeyboard(
      ["local:one", "local:two"],
      "local:one",
      onSelect,
    );
    return (
      <section onKeyDown={keyboard} data-testid="list" tabIndex={0}>
        <input aria-label="Search" />
        <button id="selectable-local:two">Second</button>
      </section>
    );
  }
  render(<List />);
  fireEvent.keyDown(screen.getByLabelText("Search"), { key: "ArrowDown" });
  expect(onSelect).not.toHaveBeenCalled();
  fireEvent.keyDown(screen.getByTestId("list"), { key: "ArrowDown" });
  expect(onSelect).toHaveBeenCalledWith("local:two");
  expect(scroll).toHaveBeenCalled();
});
