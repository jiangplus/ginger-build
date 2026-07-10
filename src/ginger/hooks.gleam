import ginger/command
import ginger/config.{type HookSpec}
import ginger/context.{type Context}
import ginger/error.{type GingerError}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

/// Run an inline hook. Local hooks run on the operator machine; remote hooks
/// run over SSH on every host. The hook command is prefixed with ginger
/// context as environment variables (GINGER_VERSION, GINGER_SERVICE,
/// GINGER_HOSTS), mirroring Kamal's KAMAL_* hook env.
///
/// Hook output is always shown: local hooks print on completion; remote hooks
/// print per host with a `[host]` prefix. A per-hook `timeout` (seconds)
/// overrides the config's `ssh.command_timeout` for remote execution.
pub fn run(context: Context, spec: HookSpec) -> Result(Context, GingerError) {
  let prefixed = env_prefix(context) <> " " <> spec.run
  case spec.local {
    True -> {
      use output <- result.try(context.runner.local_shell(prefixed))
      print_output(context, "", output)
      Ok(context)
    }
    False -> {
      let timeout_ms = case spec.timeout {
        Some(seconds) -> seconds * 1000
        None -> context.config.ssh_timeout * 1000
      }
      use _ <- result.try(
        list.try_fold(config.all_hosts(context.config), Nil, fn(_, host) {
          use output <- result.try(context.runner.remote_timed(
            host,
            command.raw(prefixed),
            timeout_ms,
          ))
          print_output(context, "[" <> host <> "] ", output)
          Ok(Nil)
        }),
      )
      Ok(context)
    }
  }
}

fn print_output(context: Context, prefix: String, output: String) -> Nil {
  case string.trim(output) {
    "" -> Nil
    trimmed ->
      trimmed
      |> string.split("\n")
      |> list.each(fn(line) { context.log(prefix <> line) })
  }
}

fn env_prefix(context: Context) -> String {
  let hosts = string.join(config.all_hosts(context.config), ",")
  "GINGER_VERSION="
  <> command.quote(context.version)
  <> " GINGER_SERVICE="
  <> command.quote(context.config.service)
  <> " GINGER_HOSTS="
  <> command.quote(hosts)
}
