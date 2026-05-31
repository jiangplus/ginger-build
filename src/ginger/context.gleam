import ginger/command.{type Command}
import ginger/config.{type Config}
import ginger/error.{type GingerError}
import ginger/secrets
import gleam/dict.{type Dict}
import gleam/list

/// The execution capability threaded through every step. The real
/// implementation (see `ginger/runner`) talks to SSH and the local shell; tests
/// inject a fake that records commands. This is ginger's analogue of Kamal's
/// SSHKit test backend.
pub type Runner {
  Runner(
    /// Run a built command on a host over SSH; non-zero exit is an error.
    remote: fn(String, Command) -> Result(String, GingerError),
    /// Run a command on a host tolerating failure: `#(output, exit_status)`.
    probe: fn(String, Command) -> #(String, Int),
    /// Run a built command on the operator machine.
    local: fn(Command) -> Result(String, GingerError),
    /// Run a raw shell string on the operator machine (local hooks).
    local_shell: fn(String) -> Result(String, GingerError),
  )
}

/// Everything a pipeline step needs. Carried by value and threaded through the
/// interpreter via `try_fold`.
pub type Context {
  Context(
    config: Config,
    version: String,
    secrets: Dict(String, String),
    runner: Runner,
    log: fn(String) -> Nil,
  )
}

/// The env pairs to inject into containers: plain `env` plus matched secrets.
pub fn container_env(context: Context) -> List(#(String, String)) {
  let injected =
    secrets.injected(context.secrets, context.config.secrets.inject)
  list.append(context.config.env, injected)
}
