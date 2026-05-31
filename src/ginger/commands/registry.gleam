import ginger/command.{type Command}
import ginger/config.{type Registry}

/// `docker login <server> -u <user> -p <password>` — for local use where
/// process visibility is less of a concern (operator machine, build step).
pub fn login(registry: Registry, password: String) -> Command {
  command.docker([
    "login",
    registry.server,
    "-u",
    command.quote(registry.username),
    "-p",
    command.quote(password),
  ])
}

/// Login on a remote host using `--password-stdin` so the password is piped
/// via stdin rather than appearing in process args / `ps aux`.
/// Format: `printf '%s' '<password>' | docker login <server> -u <user> --password-stdin`
pub fn login_stdin(registry: Registry, password: String) -> Command {
  command.raw(
    "printf '%s' "
    <> command.quote(password)
    <> " | docker login "
    <> registry.server
    <> " -u "
    <> command.quote(registry.username)
    <> " --password-stdin",
  )
}

/// `docker logout <server>`
pub fn logout(registry: Registry) -> Command {
  command.docker(["logout", registry.server])
}
