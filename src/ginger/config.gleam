import gleam/list
import gleam/option.{type Option, None, Some}
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
    // Set to deploy a hand-written Nomad job spec instead of ginger's generated
    // one. Only meaningful with `runner: nomad`. See `NomadJob`.
    nomad_job: Option(NomadJob),
    // This service has no source to build — its image comes from elsewhere
    // (an upstream registry, another pipeline). `Build`/`Push` are dropped from
    // every pipeline, exactly as `--skip-push` does, so `ginger deploy` means
    // "roll out the image that is already in the registry".
    //
    // Without this, a deploy-only service either fails in `docker buildx` (no
    // build context) or forces the operator to hand-write a pipeline just to
    // omit two steps.
    deploy_only: Bool,
    // The image lives in the target host's Docker daemon and is not in any
    // registry — it was built there directly (e.g. `DOCKER_HOST=ssh://host
    // docker build -t app:v1 .`). Implies `deploy_only`, and additionally
    // suppresses every registry interaction: no `docker login`, no pre-pull,
    // and no auth embedded in the Nomad task config.
    //
    // `deploy_only` alone is NOT enough: it only drops Build/Push, while
    // `boot-app` still logs in and pre-pulls, both of which fail with no
    // registry behind the image. The two flags mean different things —
    // `deploy_only` is "already in the registry", `local_image` is "never in
    // a registry at all".
    //
    // The motivating case is bootstrapping a registry itself: it cannot pull
    // its own image from itself. Build locally, deploy with `local_image`,
    // then switch to the normal registry flow once it is serving.
    //
    // `registry:` becomes optional when this is set.
    local_image: Bool,
  )
}

/// Job-template mode: deploy a hand-written Nomad job spec instead of the one
/// ginger generates.
///
/// ginger's generated spec covers a single container with dynamic ports and a
/// fixed shape. Real jobs often need static ports, `template` blocks reading
/// `nomadVar`, multiple tasks, host volumes — things a passthrough field set
/// can never fully cover. In job-template mode the operator owns the HCL and
/// ginger owns only the lifecycle: substitute the image reference, submit the
/// job, and health-gate the deployment.
///
/// This deliberately keeps ginger's health gate, which is what a
/// `hook: nomad job run ...` loses — a hook reports success as soon as the
/// command exits, so a job whose allocations crash-loop still "deploys".
///
/// `job_file` is a path **on the deploy host**. `image_var` names the HCL2
/// variable ginger passes the image reference to, so the spec must declare:
///
/// ```hcl
/// variable "image" { type = string }
/// ...
/// config { image = var.image }
/// ```
///
/// Passing the image as a variable also sidesteps the `:latest` no-op trap:
/// a sha-tagged image ref changes the job definition every deploy, so Nomad
/// actually rolls it out instead of treating the submission as unchanged.
pub type NomadJob {
  NomadJob(job_file: String, job_id: Option(String), image_var: String)
}

/// Nomad task resource reservation.
///
/// `memory` is the guaranteed reservation (Nomad `MemoryMB`). `memory_max`
/// opts the task into memory over-provisioning: when greater than `memory`
/// it becomes Nomad's `MemoryMaxMB`, letting the task burst above its
/// reservation up to this ceiling on a host that has spare memory (requires
/// the cluster's memory oversubscription to be enabled). `0` disables it —
/// the task is capped at its reservation.
pub type Resources {
  Resources(cpu: Int, memory: Int, memory_max: Int)
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

/// The Nomad job ID to address for status / logs / deployment polling.
///
/// Generated specs are named `<service>-<role>`; a hand-written spec has
/// whatever `job "..."` the operator wrote, so job-template mode may override
/// it. Defaults to the service name, which is the common case.
pub fn nomad_job_id(config: Config, role_name: String) -> String {
  case config.nomad_job {
    Some(job) -> option.unwrap(job.job_id, config.service)
    None -> container_prefix(config, role_name)
  }
}

/// The full `repository:tag` reference for the built image.
pub fn image_ref(config: Config, version: String) -> String {
  config.image <> ":" <> version
}
