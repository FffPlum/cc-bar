import type { ReactNode } from "react";
import {
  NavigationIcon,
  type NavigationPage,
} from "@/components/navigation-icon";

export function PageHeader({
  page,
  title,
  titleAccessory,
  actions,
}: {
  page: NavigationPage;
  title: string;
  titleAccessory?: ReactNode;
  actions?: ReactNode;
}) {
  return (
    <header className="flex w-full shrink-0 items-center gap-3 border-b px-5 py-3.5">
      <NavigationIcon page={page} className="size-4 shrink-0" />
      <h1 className="shrink-0 text-[17px] font-bold tracking-[-0.4px]">
        {title}
      </h1>
      {titleAccessory}
      <span className="flex-1" />
      <div className="flex min-h-8 shrink-0 items-center gap-3">{actions}</div>
    </header>
  );
}
