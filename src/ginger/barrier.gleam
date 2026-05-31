import gleam/erlang/process.{type Subject}
import gleam/list

/// The outcome a waiter receives when the barrier resolves.
pub type Outcome {
  /// The gatekeeper signalled success — proceed.
  Released
  /// The gatekeeper signalled failure — abort.
  Aborted
}

type Message {
  Wait(reply: Subject(Outcome))
  Open
  Close
}

/// A barrier handle. The gatekeeper (primary role) calls `open`/`close`; other
/// roles call `wait` and block until the gatekeeper resolves it. Late waiters
/// (after resolution) return the settled outcome immediately.
pub opaque type Barrier {
  Barrier(channel: Subject(Message))
}

/// Spawn a barrier process. The process owns its own subject so it can receive;
/// the handle returned lets other processes message it.
pub fn new() -> Barrier {
  let init = process.new_subject()
  process.spawn(fn() {
    let self = process.new_subject()
    process.send(init, self)
    loop(self, NotSettled, [])
  })
  let assert Ok(channel) = process.receive(init, 1000)
  Barrier(channel)
}

type State {
  NotSettled
  Settled(Outcome)
}

fn loop(
  self: Subject(Message),
  state: State,
  pending: List(Subject(Outcome)),
) -> Nil {
  case process.receive_forever(self) {
    Wait(reply) ->
      case state {
        Settled(outcome) -> {
          process.send(reply, outcome)
          loop(self, state, pending)
        }
        NotSettled -> loop(self, state, [reply, ..pending])
      }
    Open -> {
      list.each(pending, fn(reply) { process.send(reply, Released) })
      loop(self, Settled(Released), [])
    }
    Close -> {
      list.each(pending, fn(reply) { process.send(reply, Aborted) })
      loop(self, Settled(Aborted), [])
    }
  }
}

/// Release all current and future waiters (primary is healthy).
pub fn open(barrier: Barrier) -> Nil {
  process.send(barrier.channel, Open)
}

/// Abort all current and future waiters (primary failed).
pub fn close(barrier: Barrier) -> Nil {
  process.send(barrier.channel, Close)
}

/// Block until the barrier is opened or closed.
pub fn wait(barrier: Barrier) -> Outcome {
  let reply = process.new_subject()
  process.send(barrier.channel, Wait(reply))
  process.receive_forever(reply)
}
