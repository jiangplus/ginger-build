import ginger/command.{type Command}
import ginger/config.{type Registry}

/// `docker login <server> -u <user> -p <password>`
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

/// `docker logout <server>`
pub fn logout(registry: Registry) -> Command {
  command.docker(["logout", registry.server])
}
