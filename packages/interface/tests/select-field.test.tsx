import { useState } from "react";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { expect, it, vi } from "vitest";
import { SelectField } from "@/components/select-field";

it.each([
  ["openai", "OpenAI"],
  ["system", "跟随系统"],
  ["m1", "1 分钟"],
])("shows the option label before opening a %s select", (value, label) => {
  render(
    <SelectField
      value={value}
      options={[{ value, label }]}
      onChange={() => {}}
      ariaLabel="Choice"
    />,
  );
  expect(
    screen.getByRole("combobox", { name: "Choice" }).textContent,
  ).toContain(label);
});

it("shows translated labels while preserving the raw value on selection", async () => {
  const onChange = vi.fn();
  function Form() {
    const [value, setValue] = useState("openai");
    return (
      <SelectField
        value={value}
        options={[
          { value: "openai", label: "OpenAI" },
          { value: "anthropic", label: "Anthropic" },
        ]}
        onChange={(next) => {
          setValue(next);
          onChange(next);
        }}
        ariaLabel="Provider"
      />
    );
  }
  render(<Form />);
  const trigger = screen.getByRole("combobox", { name: "Provider" });
  expect(trigger.textContent).toContain("OpenAI");
  fireEvent.click(trigger);
  const option = await screen.findByRole("option", { name: "Anthropic" });
  fireEvent.pointerDown(option, { pointerType: "mouse", button: 0 });
  fireEvent.click(option, { detail: 1 });
  await waitFor(() => expect(trigger.textContent).toContain("Anthropic"));
  expect(onChange).toHaveBeenCalledWith("anthropic");
});

it("updates a selected label when the application language changes", () => {
  const { rerender } = render(
    <SelectField
      value="system"
      options={[{ value: "system", label: "Follow System" }]}
      onChange={() => {}}
      ariaLabel="Language"
    />,
  );
  expect(screen.getByRole("combobox").textContent).toContain("Follow System");
  rerender(
    <SelectField
      value="system"
      options={[{ value: "system", label: "跟随系统" }]}
      onChange={() => {}}
      ariaLabel="Language"
    />,
  );
  expect(screen.getByRole("combobox").textContent).toContain("跟随系统");
});
