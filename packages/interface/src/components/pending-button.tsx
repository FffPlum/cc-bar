import { LoaderCircle } from "lucide-react";
import type { ComponentProps } from "react";
import { Button } from "@/components/ui/button";

export function PendingButton({
  pending,
  children,
  disabled,
  ...props
}: ComponentProps<typeof Button> & { pending: boolean }) {
  return (
    <Button {...props} disabled={disabled || pending} aria-busy={pending}>
      {pending && (
        <LoaderCircle className="size-3.5 animate-spin" aria-hidden="true" />
      )}
      {children}
    </Button>
  );
}
