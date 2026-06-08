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
    /// Run a built command locally, streaming output to stdout in real time.
    local_streamed: fn(Command) -> Result(String, GingerError),
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

/// Plain (non-secret) env pairs from the config — passed inline as `--env`.
pub fn plain_env(context: Context) -> List(#(String, String)) {
  context.config.env
}

/// Secret env pairs resolved from the merged secret map — written to an
/// env-file on the host so they never appear in `docker run` process args.
pub fn secret_env(context: Context) -> List(#(String, String)) {
  secrets.injected(context.secrets, context.config.secrets.inject)
}

/// All container env (plain + secrets). Used by tests and the old code path.
pub fn container_env(context: Context) -> List(#(String, String)) {
  list.append(plain_env(context), secret_env(context))
}
