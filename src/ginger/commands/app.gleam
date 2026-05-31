import ginger/command.{type Command}
import ginger/config.{type Config, type Role, container_name, image_ref}
import gleam/list
import gleam/option.{None, Some}
import gleam/string

/// The default docker network ginger uses when it boots its own proxy. When an
/// existing proxy is reused, the app joins that proxy's network instead.
pub const network = "ginger"

/// `docker run --detach ...` for a role's container at a version. `env_pairs`
/// are the plain + injected secret env vars to set on the container; `network`
/// is the docker network to join (the proxy's network).
pub fn run(
  config: Config,
  role: Role,
  host: String,
  version: String,
  env_pairs: List(#(String, String)),
  network: String,
) -> Command {
  let name = container_name(config, role.name, version)
  let image = image_ref(config, version)
  command.docker(
    list.flatten([
      ["run", "--detach", "--restart", "unless-stopped"],
      ["--name", name, "--network", network],
      command.flag_pairs("--env", [
        #("GINGER_CONTAINER_NAME", name),
        #("GINGER_VERSION", version),
        #("GINGER_HOST", host),
      ]),
      command.flag_pairs("--env", env_pairs),
      command.flag_pairs("--label", [
        #("service", config.service),
        #("role", role.name),
        #("version", version),
      ]),
      [image],
      role_cmd_tokens(role),
    ]),
  )
}

fn role_cmd_tokens(role: Role) -> List(String) {
  case role.cmd {
    None -> []
    Some(cmd) -> string.split(cmd, " ")
  }
}

/// `docker container start <name>`
pub fn start(config: Config, role_name: String, version: String) -> Command {
  command.docker([
    "container",
    "start",
    container_name(config, role_name, version),
  ])
}

/// `docker container stop <name>`
pub fn stop(config: Config, role_name: String, version: String) -> Command {
  command.docker([
    "container",
    "stop",
    container_name(config, role_name, version),
  ])
}

/// `docker container rm <name>`
pub fn remove(config: Config, role_name: String, version: String) -> Command {
  command.docker([
    "container",
    "rm",
    container_name(config, role_name, version),
  ])
}

/// `docker rename <service-role-old> <service-role-new>`
pub fn rename(
  config: Config,
  role_name: String,
  from_version: String,
  to_version: String,
) -> Command {
  command.docker([
    "rename",
    container_name(config, role_name, from_version),
    container_name(config, role_name, to_version),
  ])
}

/// Stop all containers for a role (any version) via label filter.
pub fn stop_all(config: Config, role_name: String) -> Command {
  command.raw(
    "docker ps -q --filter label=service="
    <> config.service
    <> " --filter label=role="
    <> role_name
    <> " | xargs -r docker container stop",
  )
}

/// Remove all containers (running or stopped) for a role via label filter.
pub fn remove_all(config: Config, role_name: String) -> Command {
  command.raw(
    "docker ps -aq --filter label=service="
    <> config.service
    <> " --filter label=role="
    <> role_name
    <> " | xargs -r docker container rm",
  )
}

/// Quiet container id lookup for a specific version (empty output if absent).
pub fn container_id(
  config: Config,
  role_name: String,
  version: String,
) -> Command {
  let name = container_name(config, role_name, version)
  command.docker([
    "container",
    "ls",
    "--all",
    "--filter",
    "name=^" <> name <> "$",
    "--quiet",
  ])
}

/// Names of running containers for a role, newest first — the boot logic
/// parses the version suffix off these to find the currently-live version.
pub fn running_names(config: Config, role_name: String) -> Command {
  command.docker([
    "ps",
    "--filter",
    "label=service=" <> config.service,
    "--filter",
    "label=role=" <> role_name,
    "--format",
    "{{.Names}}",
  ])
}

/// Health/status string for a version's container via `docker inspect`.
pub fn status(config: Config, role_name: String, version: String) -> Command {
  let format =
    "{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}"
  command.docker([
    "inspect",
    "--format",
    command.quote(format),
    container_name(config, role_name, version),
  ])
}
