import { useCallback, useEffect, useRef } from "react";

export function useGeneration() {
  const generation = useRef(0);
  const next = useCallback(() => ++generation.current, []);
  const isCurrent = useCallback(
    (value: number) => generation.current === value,
    [],
  );
  useEffect(
    () => () => {
      generation.current += 1;
    },
    [],
  );
  return { next, isCurrent };
}
