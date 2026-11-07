import { render, screen, within } from "@testing-library/react";
import { expect, it } from "vitest";
import {
  createDataTableColumnHelper,
  DataTable,
} from "@/components/ui/data-table";

type Item = { id: string; name: string; tokens: number };
const helper = createDataTableColumnHelper<Item>();
const columns = helper.columns([
  helper.accessor("name", { id: "name", header: "Name" }),
  helper.accessor("tokens", { id: "tokens", header: "Tokens" }),
]);
const getRowId = (row: Item) => row.id;
const table = (data: Item[]) => (
  <DataTable
    columns={columns}
    data={data}
    getRowId={getRowId}
    ariaLabel="Project usage"
    emptyMessage="No data"
  />
);

it("follows refreshed host values and row order without applying a local sort", () => {
  const first = { id: "b", name: "Beta", tokens: 800 };
  const second = { id: "a", name: "Alpha", tokens: 100 };
  const view = render(table([first, second]));
  const values = () =>
    within(screen.getByRole("table", { name: "Project usage" }))
      .getAllByRole("row")
      .slice(1)
      .map((row) =>
        within(row)
          .getAllByRole("cell")
          .map((cell) => cell.textContent),
      );
  expect(values()).toEqual([
    ["Beta", "800"],
    ["Alpha", "100"],
  ]);
  view.rerender(table([{ ...second, tokens: 900 }, first]));
  expect(values()).toEqual([
    ["Alpha", "900"],
    ["Beta", "800"],
  ]);
});

it("clears old rows when the selected project has no data", () => {
  const view = render(table([{ id: "old", name: "Old project", tokens: 800 }]));
  view.rerender(table([]));
  expect(screen.queryByText("Old project")).toBeNull();
  expect(
    screen.getByRole("cell", { name: "No data" }).getAttribute("colspan"),
  ).toBe("2");
});
