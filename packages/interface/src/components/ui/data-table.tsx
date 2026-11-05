"use client";

import type { ComponentProps, ReactNode } from "react";
import {
  createColumnHelper,
  tableFeatures,
  useTable,
  type ColumnDef,
  type RowData,
} from "@tanstack/react-table";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";

// Use only the core row model so the host's row order stays authoritative.
const features = tableFeatures({});
export type DataTableFeatures = typeof features;
export type DataTableColumnDef<
  TData extends RowData,
  TValue = unknown,
> = ColumnDef<DataTableFeatures, TData, TValue>;

export function createDataTableColumnHelper<TData extends RowData>() {
  return createColumnHelper<DataTableFeatures, TData>();
}

export interface DataTableProps<TData extends RowData> {
  columns: readonly DataTableColumnDef<TData>[];
  data: readonly TData[];
  getRowId: (row: TData, index: number) => string;
  ariaLabel: string;
  emptyMessage: ReactNode;
  tableClassName?: string;
  getRowProps?: (row: TData) => ComponentProps<"tr">;
}

export function DataTable<TData extends RowData>({
  columns,
  data,
  getRowId,
  ariaLabel,
  emptyMessage,
  tableClassName,
  getRowProps,
}: DataTableProps<TData>) {
  const table = useTable({ features, columns, data, getRowId });
  const rows = table.getRowModel().rows;
  return (
    <div className="min-w-0 overflow-hidden rounded-md border">
      <Table aria-label={ariaLabel} className={tableClassName}>
        <TableHeader>
          {table.getHeaderGroups().map((headerGroup) => (
            <TableRow key={headerGroup.id}>
              {headerGroup.headers.map((header) => (
                <TableHead
                  key={header.id}
                  colSpan={header.colSpan}
                  scope={header.colSpan > 1 ? "colgroup" : "col"}
                >
                  {header.isPlaceholder ? null : (
                    <table.FlexRender header={header} />
                  )}
                </TableHead>
              ))}
            </TableRow>
          ))}
        </TableHeader>
        <TableBody>
          {rows.length > 0 ? (
            rows.map((row) => (
              <TableRow key={row.id} {...getRowProps?.(row.original)}>
                {row.getAllCells().map((cell) => (
                  <TableCell key={cell.id}>
                    <table.FlexRender cell={cell} />
                  </TableCell>
                ))}
              </TableRow>
            ))
          ) : (
            <TableRow>
              <TableCell
                colSpan={Math.max(1, table.getAllLeafColumns().length)}
                className="h-24 text-center text-muted-foreground"
              >
                {emptyMessage}
              </TableCell>
            </TableRow>
          )}
        </TableBody>
      </Table>
    </div>
  );
}
