import gleam/option.{type Option}

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
pub type Proxy {
  Proxy(
    host: String,
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
  case config.servers {
    [] -> Error(Nil)
    roles -> find_role(roles, name)
  }
}

fn find_role(roles: List(Role), name: String) -> Result(Role, Nil) {
  case roles {
    [] -> Error(Nil)
    [r, ..rest] ->
      case r.name == name {
        True -> Ok(r)
        False -> find_role(rest, name)
      }
  }
}

/// The first host of the primary role — where the deploy lock is held.
pub fn primary_host(config: Config) -> Result(String, Nil) {
  case primary_role(config) {
    Ok(role) ->
      case role.hosts {
        [host, ..] -> Ok(host)
        [] -> Error(Nil)
      }
    Error(_) -> Error(Nil)
  }
}

/// The primary role, if one is marked.
pub fn primary_role(config: Config) -> Result(Role, Nil) {
  case list_find(config.servers, fn(r) { r.primary }) {
    Ok(r) -> Ok(r)
    Error(_) ->
      // fall back to the first role
      case config.servers {
        [first, ..] -> Ok(first)
        [] -> Error(Nil)
      }
  }
}

fn list_find(items: List(a), pred: fn(a) -> Bool) -> Result(a, Nil) {
  case items {
    [] -> Error(Nil)
    [x, ..rest] ->
      case pred(x) {
        True -> Ok(x)
        False -> list_find(rest, pred)
      }
  }
}

/// All unique hosts across all roles.
pub fn all_hosts(config: Config) -> List(String) {
  config.servers
  |> fold_hosts([])
}

fn fold_hosts(roles: List(Role), acc: List(String)) -> List(String) {
  case roles {
    [] -> acc
    [r, ..rest] -> fold_hosts(rest, append_unique(acc, r.hosts))
  }
}

fn append_unique(acc: List(String), items: List(String)) -> List(String) {
  case items {
    [] -> acc
    [x, ..rest] ->
      case contains(acc, x) {
        True -> append_unique(acc, rest)
        False -> append_unique(list_append(acc, x), rest)
      }
  }
}

fn contains(items: List(String), target: String) -> Bool {
  case items {
    [] -> False
    [x, ..rest] ->
      case x == target {
        True -> True
        False -> contains(rest, target)
      }
  }
}

fn list_append(items: List(String), item: String) -> List(String) {
  case items {
    [] -> [item]
    [x, ..rest] -> [x, ..list_append(rest, item)]
  }
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
