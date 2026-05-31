import ginger/config.{type Limit, Count, Percent}
import gleam/list

/// Resolve a rolling limit to an absolute batch size for `total` hosts.
/// Counts are clamped to `[1, total]`; percentages round up (so 25% of 4 = 1,
/// 50% of 3 = 2).
pub fn resolve_limit(limit: Limit, total: Int) -> Int {
  let raw = case limit {
    Count(n) -> n
    Percent(p) -> ceil_div(p * total, 100)
  }
  clamp(raw, total)
}

fn ceil_div(a: Int, b: Int) -> Int {
  case b {
    0 -> 0
    _ -> { a + b - 1 } / b
  }
}

fn clamp(n: Int, total: Int) -> Int {
  case n < 1, n > total {
    True, _ -> 1
    _, True -> total
    _, _ -> n
  }
}

/// Split items into rolling batches honoring the limit.
pub fn batches(items: List(a), limit: Limit) -> List(List(a)) {
  let size = resolve_limit(limit, list.length(items))
  list.sized_chunk(items, size)
}
