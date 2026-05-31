import ginger/command
import ginger/config.{type HookSpec}
import ginger/context.{type Context}
import ginger/error.{type GingerError}
import gleam/list
import gleam/result
import gleam/string

/// Run an inline hook. Local hooks run on the operator machine; remote hooks
/// run over SSH on every host. The hook command is prefixed with ginger
/// context as environment variables (GINGER_VERSION, GINGER_SERVICE,
/// GINGER_HOSTS), mirroring Kamal's KAMAL_* hook env.
pub fn run(context: Context, spec: HookSpec) -> Result(Context, GingerError) {
  let prefixed = env_prefix(context) <> " " <> spec.run
  case spec.local {
    True -> {
      use _ <- result.try(context.runner.local_shell(prefixed))
      Ok(context)
    }
    False -> {
      use _ <- result.try(
        list.try_fold(config.all_hosts(context.config), Nil, fn(_, host) {
          use _ <- result.try(context.runner.remote(host, command.raw(prefixed)))
          Ok(Nil)
        }),
      )
      Ok(context)
    }
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
