import ginger/config.{Count, Percent}
import ginger/rolling

pub fn resolve_count_test() {
  assert rolling.resolve_limit(Count(1), 3) == 1
  assert rolling.resolve_limit(Count(2), 3) == 2
  assert rolling.resolve_limit(Count(5), 3) == 3
  assert rolling.resolve_limit(Count(0), 3) == 1
}

pub fn resolve_percent_test() {
  assert rolling.resolve_limit(Percent(25), 4) == 1
  assert rolling.resolve_limit(Percent(50), 3) == 2
  assert rolling.resolve_limit(Percent(100), 3) == 3
  assert rolling.resolve_limit(Percent(1), 3) == 1
}

pub fn batches_count_test() {
  assert rolling.batches(["a", "b", "c"], Count(1)) == [["a"], ["b"], ["c"]]
  assert rolling.batches(["a", "b", "c", "d"], Count(2))
    == [["a", "b"], ["c", "d"]]
  assert rolling.batches(["a"], Count(1)) == [["a"]]
}

pub fn batches_percent_test() {
  assert rolling.batches(["a", "b", "c", "d"], Percent(50))
    == [["a", "b"], ["c", "d"]]
}
