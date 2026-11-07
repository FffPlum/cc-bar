export function moveBefore<T extends string>(
  order: readonly T[],
  source: T,
  target: T,
): T[] | null {
  if (source === target || !order.includes(source) || !order.includes(target))
    return null;
  const result = order.filter((item) => item !== source);
  result.splice(result.indexOf(target), 0, source);
  return result.every((item, index) => item === order[index]) ? null : result;
}
export function moveAdjacent<T extends string>(
  order: readonly T[],
  source: T,
  direction: -1 | 1,
): T[] | null {
  const from = order.indexOf(source);
  const to = from + direction;
  if (from < 0 || to < 0 || to >= order.length) return null;
  const result = [...order];
  result[from] = order[to]!;
  result[to] = source;
  return result;
}

export function moveAfter<T extends string>(
  order: readonly T[],
  source: T,
  target: T,
): T[] | null {
  if (source === target || !order.includes(source) || !order.includes(target))
    return null;
  const result = order.filter((item) => item !== source);
  result.splice(result.indexOf(target) + 1, 0, source);
  return result.every((item, index) => item === order[index]) ? null : result;
}
export function replaceGroup<T extends string>(
  order: readonly T[],
  group: readonly T[],
): T[] {
  let position = 0;
  return order.map((item) =>
    group.includes(item) ? group[position++]! : item,
  );
}
