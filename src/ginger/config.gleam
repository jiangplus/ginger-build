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
    network: String,
    // How Traefik discovers this service's routing config:
    // "docker" (default) emits Docker container labels (Traefik Docker provider);
    // "nomad" emits Nomad service tags (Traefik Nomad provider). Only relevant
    // for runner: nomad + egress: traefik.
    traefik_provider: String,
    // Always re-pull the image on deploy. Nomad's docker driver defaults to
    // false, so a rebuilt image pushed under the SAME tag (e.g. an uncommitted
    // change) is NOT re-pulled and the stale local image keeps running. Set true
    // to force a fresh pull every deploy.
    force_pull: Bool,
    // Container plumbing passthroughs, applied to both runtimes:
    // volumes ("host:container"), extra_hosts ("name:ip"), and free-form
    // labels stamped on containers (docker) / task config + job Meta (nomad).
    volumes: List(String),
    extra_hosts: List(String),
    labels: List(#(String, String)),
    // Nomad task resources (MHz / MB). Docker runtime ignores these.
    resources: Resources,
    // Default timeout (seconds) for remote SSH commands and hooks. Individual
    // hooks can override with their own `timeout:`.
    ssh_timeout: Int,
    // Paths to other ginger config files this service depends on, relative to
    // this config file's directory. Used by multi-config deploys to order
    // services; a dep that isn't part of the deploy set is ignored.
    deps: List(String),
  )
}

/// Nomad task resource reservation.
pub type Resources {
  Resources(cpu: Int, memory: Int)
}

/// Registry-cache export policy for `docker buildx build`.
/// `CacheMin` (default) exports only final-stage layers; `CacheMax` exports
/// all intermediate layers (slow to export, best hit rate); `CacheNone`
/// disables the registry cache entirely.
pub type CacheMode {
  CacheNone
  CacheMin
  CacheMax
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
  Builder(
    arch: String,
    remote: Option(String),
    // Build context directory (default "."). Relative paths are resolved
    // from the operator's cwd, so configs living outside the repo can point
    // back at it. The version git-sha is also resolved from this directory.
    context: String,
    // Dockerfile path relative to the context (docker build -f). Absent →
    // the context's default Dockerfile.
    dockerfile: Option(String),
    // Extra tags pushed alongside the version tag (e.g. ["latest"]), so
    // `:latest`-pinned runtime specs and versioned rollback history coexist.
    tags: List(String),
    // Registry build-cache policy (see CacheMode). Default: min.
    cache: CacheMode,
    // Emit provenance attestations + SBOM (buildx defaults them on, which
    // slows the export and bloats simple registries with extra manifests).
    // ginger defaults them OFF; set true to restore buildx behaviour.
    provenance: Bool,
    // Extra `--build-arg KEY=VALUE` pairs passed to `docker buildx build`.
    // Useful for e.g. HTTP_PROXY/HTTPS_PROXY so RUN steps (npm/gem installs)
    // can reach the internet through a proxy on the build host.
    build_args: List(#(String, String)),
    // Optional separate registry host to build/push to, when it differs from the
    // runtime image host. The image's repository path is preserved; only the
    // host segment of `image` is swapped. Used when builds push to a fast
    // intermediary registry that shares a backend with the runtime registry, so
    // the runtime host can still pull the same image (e.g. push to an overseas
    // mirror, pull from an in-region registry sharing one object store + DB).
    push_registry: Option(String),
  )
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
/// the command over SSH on each targeted host. `timeout` (seconds) overrides
/// the config-level `ssh.command_timeout` for remote hooks.
pub type HookSpec {
  HookSpec(run: String, local: Bool, timeout: Option(Int))
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
