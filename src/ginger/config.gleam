import gleam/list
import gleam/option.{type Option}
import gleam/result

/// Container runtime used on the servers.
/// `docker` (default) manages containers directly with Docker.
/// `nomad` submits Nomad jobs (requires `egress: traefik`).
pub type RuntimeBackend {
  DockerRuntime
  NomadRuntime
}

/// Egress/reverse-proxy backend for traffic routing.
/// `kamal-proxy` (default) uses kamal-proxy for zero-downtime switching.
/// `traefik` uses Traefik, which auto-discovers containers via Docker labels.
pub type EgressBackend {
  KamalProxyEgress
  TraefikEgress
}

/// The fully parsed `ginger.yml`. Required sections (service, image, servers,
/// registry) are non-optional; everything else carries a sensible default when
/// absent from the file (see `config/decode`).
pub type Config {
  Config(
    service: String,
    image: String,
    servers: List(Role),
    registry: Registry,
    proxy: Option(Proxy),
    builder: Builder,
    env: List(#(String, String)),
    secrets: Secrets,
    rolling: Rolling,
    retain_containers: Int,
    ssh_user: String,
    pipelines: List(Pipeline),
    runtime: RuntimeBackend,
    egress: EgressBackend,
  )
}

/// A group of servers that run the same container. The `primary` role is the
/// barrier gatekeeper — other roles wait for it to become healthy.
pub type Role {
  Role(name: String, hosts: List(String), primary: Bool, cmd: Option(String))
}

pub type Registry {
  Registry(server: String, username: String, password: String)
}

/// kamal-proxy configuration. Absent → the role is not web-facing.
/// `hosts` holds one or more virtual-host domain names the proxy routes for
/// this service. In YAML, either `host: "a.com"` or `hosts: [a.com, b.com]`
/// is accepted; both normalise to this list.
pub type Proxy {
  Proxy(
    hosts: List(String),
    app_port: Int,
    ssl: Bool,
    health_check_path: String,
    deploy_timeout: Int,
    drain_timeout: Int,
  )
}

/// Image builder. `remote` set → build on a remote Docker host over SSH;
/// absent → build locally with `docker buildx`.
pub type Builder {
  Builder(arch: String, remote: Option(String))
}

/// Auto-env secret handling. `load` lists dotenv files to merge with the
/// process environment; `inject` names (or globs) select which keys are
/// injected into containers as `--env`.
pub type Secrets {
  Secrets(load: List(String), inject: List(String))
}

/// Rolling-update policy.
pub type Rolling {
  Rolling(limit: Limit, wait: Int, parallel_roles: Bool)
}

/// Hosts-per-batch: an absolute count or a percentage of a role's hosts.
pub type Limit {
  Count(Int)
  Percent(Int)
}

/// A named, explicit action sequence (the YAML `pipelines:` block).
pub type Pipeline {
  Pipeline(name: String, steps: List(Step))
}

/// A single step in a pipeline: either a built-in primitive or an inline hook.
pub type Step {
  Build
  Push
  BootProxy
  Prune
  Healthcheck
  BootApp(rolling: Bool, version: Option(String))
  RemoveApp
  Lock(action: LockAction)
  Hook(spec: HookSpec)
}

pub type LockAction {
  Acquire
  Release
  Status
}

/// An inline shell hook. `local` True runs on the operator machine; False runs
/// the command over SSH on each targeted host.
pub type HookSpec {
  HookSpec(run: String, local: Bool)
}

/// Look up a role by name.
pub fn role(config: Config, name: String) -> Result(Role, Nil) {
  list.find(config.servers, fn(r) { r.name == name })
}

/// The first host of the primary role — where the deploy lock is held.
pub fn primary_host(config: Config) -> Result(String, Nil) {
  use role <- result.try(primary_role(config))
  case role.hosts {
    [host, ..] -> Ok(host)
    [] -> Error(Nil)
  }
}

/// The primary role, if one is marked; falls back to the first role.
pub fn primary_role(config: Config) -> Result(Role, Nil) {
  list.find(config.servers, fn(r) { r.primary })
  |> result.lazy_or(fn() {
    case config.servers {
      [first, ..] -> Ok(first)
      [] -> Error(Nil)
    }
  })
}

/// All unique hosts across all roles, in declaration order.
pub fn all_hosts(config: Config) -> List(String) {
  config.servers
  |> list.flat_map(fn(role) { role.hosts })
  |> list.unique
}

/// The container name for a role at a version: `service-role-version`.
pub fn container_name(
  config: Config,
  role_name: String,
  version: String,
) -> String {
  container_prefix(config, role_name) <> "-" <> version
}

/// The container name prefix for a role: `service-role`. Used as the
/// kamal-proxy service identifier and for label filters.
pub fn container_prefix(config: Config, role_name: String) -> String {
  config.service <> "-" <> role_name
}

/// The full `repository:tag` reference for the built image.
pub fn image_ref(config: Config, version: String) -> String {
  config.image <> ":" <> version
}
