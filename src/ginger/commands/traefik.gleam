import ginger/command.{type Command}
import ginger/config.{type Config, type Proxy, type Role, container_prefix}
import gleam/int
import gleam/list
import gleam/string

/// The name and image of the Traefik container ginger boots when none exists.
pub const container = "ginger-traefik"

pub const image = "traefik:v3"

/// Detect a running Traefik container — any container whose image contains
/// "traefik". Prints the container name, or nothing if none is found.
pub fn detect() -> Command {
  command.raw(
    "docker ps --format '{{.Names}} {{.Image}}' | awk '$2 ~ /traefik/ {print $1; exit}'",
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

/// `docker run` ginger's own Traefik, publishing 80/443 and mounting the Docker
/// socket. Only used when no Traefik is already running on the host.
/// The container joins `network` so it can reach app containers on that network.
pub fn run(network: String) -> Command {
  command.docker([
    "run",
    "--name",
    container,
    "--detach",
    "--restart",
    "unless-stopped",
    "--network",
    network,
    "--publish",
    "80:80",
    "--publish",
    "443:443",
    "--volume",
    "/var/run/docker.sock:/var/run/docker.sock:ro",
    "--volume",
    "ginger-traefik-data:/data",
    image,
    "--providers.docker=true",
    "--providers.docker.exposedbydefault=false",
    "--providers.docker.network=" <> network,
    "--entrypoints.web.address=:80",
    "--entrypoints.websecure.address=:443",
    "--certificatesresolvers.letsencrypt.acme.httpchallenge=true",
    "--certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web",
    "--certificatesresolvers.letsencrypt.acme.storage=/data/acme.json",
  ])
}

/// `docker container start ginger-traefik`
pub fn start() -> Command {
  command.docker(["container", "start", container])
}

/// Start ginger's own Traefik if it exists, otherwise create it: `start || run`.
pub fn start_or_run(network: String) -> Command {
  command.or([start(), run(network)])
}

/// Traefik routing labels for a Docker container. Traefik auto-discovers
/// containers with `traefik.enable=true` via the Docker provider; no separate
/// register step is needed — start the container with these labels and Traefik
/// picks it up immediately.
///
/// For SSL, a second HTTPS router is added alongside the plaintext one.
pub fn labels(
  config: Config,
  role: Role,
  proxy: Proxy,
) -> List(#(String, String)) {
  let svc = container_prefix(config, role.name)
  let rule =
    proxy.hosts
    |> list.map(fn(h) { "Host(`" <> h <> "`)" })
    |> string.join(" || ")
  let port = int.to_string(proxy.app_port)
  // A single service shared by both routers. When a container exposes more than
  // one Traefik service, routers can't be auto-linked and must name their
  // service explicitly — so every router carries a `.service` label.
  let base = [
    #("traefik.enable", "true"),
    #("traefik.http.routers." <> svc <> ".rule", rule),
    #("traefik.http.routers." <> svc <> ".entrypoints", "web"),
    #("traefik.http.routers." <> svc <> ".service", svc),
    #(
      "traefik.http.services." <> svc <> ".loadbalancer.server.port",
      port,
    ),
  ]
  case proxy.ssl {
    False -> base
    True ->
      list.append(base, [
        #("traefik.http.routers." <> svc <> "-tls.rule", rule),
        #(
          "traefik.http.routers." <> svc <> "-tls.entrypoints",
          "websecure",
        ),
        #("traefik.http.routers." <> svc <> "-tls.service", svc),
        #("traefik.http.routers." <> svc <> "-tls.tls", "true"),
        #(
          "traefik.http.routers." <> svc <> "-tls.tls.certresolver",
          "letsencrypt",
        ),
      ])
  }
}

