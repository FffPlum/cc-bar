import { useCallback } from "react";

export function useListKeyboard(
  ids: readonly string[],
  selected: string | null,
  onSelect: (id: string) => void,
) {
  return useCallback(
    (event: React.KeyboardEvent) => {
      const target = event.target as HTMLElement;
      if (
        target.closest(
          "input, textarea, select, [contenteditable=true], [role=combobox]",
        )
      )
        return;
      if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
      if (ids.length === 0) return;
      event.preventDefault();
      const current = selected === null ? -1 : ids.indexOf(selected);
      const offset = event.key === "ArrowDown" ? 1 : -1;
      const next = Math.max(0, Math.min(ids.length - 1, current + offset));
      const id = ids[next];
      if (id !== undefined) {
        onSelect(id);
        document
          .getElementById(`selectable-${id}`)
          ?.scrollIntoView({ block: "nearest" });
      }
    },
    [ids, onSelect, selected],
  );
}
