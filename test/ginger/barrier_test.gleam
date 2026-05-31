import ginger/barrier
import gleam/erlang/process

pub fn open_releases_waiters_test() {
  let gate = barrier.new()
  let sink = process.new_subject()
  // a waiter blocks until the gate opens
  process.spawn(fn() { process.send(sink, barrier.wait(gate)) })
  barrier.open(gate)
  let assert Ok(outcome) = process.receive(sink, 1000)
  assert outcome == barrier.Released
}

pub fn close_aborts_waiters_test() {
  let gate = barrier.new()
  let sink = process.new_subject()
  process.spawn(fn() { process.send(sink, barrier.wait(gate)) })
  barrier.close(gate)
  let assert Ok(outcome) = process.receive(sink, 1000)
  assert outcome == barrier.Aborted
}

pub fn late_waiter_gets_settled_outcome_test() {
  let gate = barrier.new()
  // open first, then wait — should return immediately with Released
  barrier.open(gate)
  assert barrier.wait(gate) == barrier.Released
}
