import {
  ChartNoAxesCombined,
  CircleGauge,
  LayoutGrid,
  Settings,
} from "lucide-react";

const navigationIcons = {
  stats: ChartNoAxesCombined,
  quotaManagement: CircleGauge,
  applications: LayoutGrid,
  settings: Settings,
};

export type NavigationPage = keyof typeof navigationIcons;

export function NavigationIcon({
  page,
  className = "size-[18px]",
}: {
  page: NavigationPage;
  className?: string;
}) {
  const Icon = navigationIcons[page];
  return <Icon className={className} aria-hidden="true" />;
}
