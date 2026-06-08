import ginger/command.{type Command}
import ginger/commands/app
import ginger/config.{
  type Config, type Proxy, type Role, container_name, container_prefix,
}
import gleam/int
import gleam/list

/// The name and image of the proxy ginger boots when no proxy already exists.
pub const container = "ginger-proxy"

pub const image = "ghcr.io/basecamp/kamal-proxy:latest"

/// Print the name of an already-running kamal-proxy container on the host, or
/// nothing if none exists. Matches any container whose image contains
/// `kamal-proxy` (covers a hand-rolled `kamal-proxy` and ginger's own).
pub fn detect() -> Command {
  command.raw(
    "docker ps --format '{{.Names}} {{.Image}}' | awk '$2 ~ /kamal-proxy/ {print $1; exit}'",
  )
}

/// Print the first docker network a container is attached to.
pub fn network_of(name: String) -> Command {
  command.raw(
    "docker inspect --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "
    <> name
    <> " | awk '{print $1}'",
  )
}

/// Create a docker network if it does not already exist.
pub fn ensure_network(name: String) -> Command {
  command.raw("docker network create " <> name <> " 2>/dev/null || true")
}

/// `docker run` ginger's own kamal-proxy, publishing 80/443 on the ginger
/// network. Only used when no proxy is already running on the host.
pub fn run() -> Command {
  command.docker([
    "run", "--name", container, "--network", app.network, "--detach",
    "--restart", "unless-stopped", "--publish", "80:80", "--publish", "443:443",
    "--volume", "ginger-proxy-config:/home/kamal-proxy/.config/kamal-proxy",
    image,
  ])
}

/// `docker container start ginger-proxy`
pub fn start() -> Command {
  command.docker(["container", "start", container])
}

/// Start ginger's own proxy if it exists, otherwise create it: `start || run`.
pub fn start_or_run() -> Command {
  command.or([start(), run()])
}

/// Register/switch traffic for a role to its new container, executing inside
/// `proxy_container` (the detected or ginger-owned proxy). This is the
/// zero-downtime traffic switch — kamal-proxy health-checks the new target
/// before moving traffic.
pub fn deploy(
  config: Config,
  role: Role,
  proxy: Proxy,
  version: String,
  proxy_container: String,
) -> Command {
  let prefix = container_prefix(config, role.name)
  let target =
    container_name(config, role.name, version)
    <> ":"
    <> int.to_string(proxy.app_port)
  let host_args = list.flat_map(proxy.hosts, fn(h) { ["--host", h] })
  let tls_args = case proxy.ssl {
    True -> ["--tls"]
    False -> []
  }
  proxy_exec(
    proxy_container,
    list.flatten([
      ["deploy", prefix, "--target", target],
      host_args,
      tls_args,
      [
        "--deploy-timeout",
        int.to_string(proxy.deploy_timeout) <> "s",
        "--drain-timeout",
        int.to_string(proxy.drain_timeout) <> "s",
        "--health-check-path",
        proxy.health_check_path,
      ],
    ]),
  )
}

/// Deregister a role from the proxy: `kamal-proxy remove <prefix>`.
pub fn remove(config: Config, role: Role, proxy_container: String) -> Command {
  proxy_exec(proxy_container, ["remove", container_prefix(config, role.name)])
}

fn proxy_exec(proxy_container: String, args: List(String)) -> Command {
  command.docker(["exec", proxy_container, "kamal-proxy", ..args])
}
