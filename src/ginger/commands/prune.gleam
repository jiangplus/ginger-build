import ginger/command.{type Command}
import ginger/config.{type Config}

/// Remove stopped containers belonging to this service.
pub fn containers(config: Config) -> Command {
  command.docker([
    "container",
    "prune",
    "--force",
    "--filter",
    "label=service=" <> config.service,
  ])
}

/// Remove dangling images belonging to this service.
pub fn images(config: Config) -> Command {
  command.docker([
    "image",
    "prune",
    "--force",
    "--filter",
    "label=service=" <> config.service,
  ])
}

/// Prune containers then images: `prune containers && prune images`.
pub fn all(config: Config) -> Command {
  command.and([containers(config), images(config)])
}
