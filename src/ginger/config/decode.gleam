import ginger/config.{
  type Builder, type CacheMode, type Config, type EgressBackend, type Limit,
  type Pipeline, type Proxy, type Registry, type Role, type Rolling,
  type RuntimeBackend, type Secrets, type Step, Acquire, BootApp, BootProxy,
  Build, Builder, CacheMax, CacheMin, CacheNone, Config, Count, DockerRuntime,
  Healthcheck, Hook, HookSpec, KamalProxyEgress, Lock, NomadRuntime, Percent,
  Pipeline, Proxy, Prune, Push, Registry, Release, RemoveApp, Resources, Role,
  Rolling, Secrets, Status, TraefikEgress,
}
import ginger/error.{type GingerError, ConfigError, DecodeError}
import glaml
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// Parse a YAML string into a typed `Config`.
pub fn from_string(yaml: String) -> Result(Config, GingerError) {
  case glaml.parse_string(yaml) {
    Ok([doc, ..]) -> decode_root(glaml.document_root(doc))
    Ok([]) -> Error(DecodeError("empty YAML document"))
    Error(_) -> Error(DecodeError("invalid YAML syntax"))
  }
}

fn decode_root(root: glaml.Node) -> Result(Config, GingerError) {
  use service <- result.try(required_string(root, "service"))
  use image <- result.try(required_string(root, "image"))
  use servers <- result.try(decode_servers(root))
  use registry <- result.try(decode_registry(root))
  use proxy <- result.try(decode_proxy(root))
  use builder <- result.try(decode_builder(root))
  use env <- result.try(decode_env(root))
  use secrets <- result.try(decode_secrets(root))
  use rolling <- result.try(decode_rolling(root))
  use retain <- result.try(optional_int(root, "retain_containers", 5))
  let ssh_user = decode_ssh_user(root)
  use pipelines <- result.try(decode_pipelines(root))
  use #(runtime, egress) <- result.try(decode_runtime_egress(root))
  let network = optional_string_node(root, "network") |> option.unwrap("ginger")
  let traefik_provider =
    optional_string_node(root, "traefik_provider") |> option.unwrap("docker")
  let force_pull = optional_bool_node(root, "force_pull", False)
  use volumes <- result.try(optional_string_list(root, "volumes"))
  use extra_hosts <- result.try(optional_string_list(root, "extra_hosts"))
  use labels <- result.try(decode_string_map(root, "labels"))
  use resources <- result.try(decode_resources(root))
  use ssh_timeout <- result.try(decode_ssh_timeout(root))
  use deps <- result.try(optional_string_list(root, "deps"))

  Ok(Config(
    service: service,
    image: image,
    servers: servers,
    registry: registry,
    proxy: proxy,
    builder: builder,
    env: env,
    secrets: secrets,
    rolling: rolling,
    retain_containers: retain,
    ssh_user: ssh_user,
    pipelines: pipelines,
    runtime: runtime,
    egress: egress,
    network: network,
    traefik_provider: traefik_provider,
    force_pull: force_pull,
    volumes: volumes,
    extra_hosts: extra_hosts,
    labels: labels,
    resources: resources,
    ssh_timeout: ssh_timeout,
    deps: deps,
  ))
}

fn decode_ssh_user(root: glaml.Node) -> String {
  case field(root, "ssh") {
    Ok(ssh) -> optional_string_node(ssh, "user") |> option.unwrap("root")
    Error(_) -> "root"
  }
}

/// `ssh.command_timeout` in seconds — the default deadline for every remote
/// command and hook. 600 s by default (long enough for image pulls and most
/// on-server builds without hanging forever).
fn decode_ssh_timeout(root: glaml.Node) -> Result(Int, GingerError) {
  case field(root, "ssh") {
    Ok(ssh) -> optional_int(ssh, "command_timeout", 600)
    Error(_) -> Ok(600)
  }
}

fn decode_resources(root: glaml.Node) -> Result(config.Resources, GingerError) {
  case field(root, "resources") {
    Error(_) -> Ok(Resources(cpu: 256, memory: 512))
    Ok(r) -> {
      use cpu <- result.try(optional_int(r, "cpu", 256))
      use memory <- result.try(optional_int(r, "memory", 512))
      Ok(Resources(cpu: cpu, memory: memory))
    }
  }
}

fn optional_string_list(
  node: glaml.Node,
  key: String,
) -> Result(List(String), GingerError) {
  case field(node, key) {
    Error(_) -> Ok([])
    Ok(glaml.NodeSeq(items)) -> Ok(string_seq(items))
    Ok(_) -> Error(DecodeError(key <> " must be a list of strings"))
  }
}

fn decode_string_map(
  node: glaml.Node,
  key: String,
) -> Result(List(#(String, String)), GingerError) {
  case field(node, key) {
    Error(_) -> Ok([])
    Ok(glaml.NodeMap(pairs)) ->
      list.try_map(pairs, fn(pair) {
        let #(k, v) = pair
        use ks <- result.try(node_key_string(k))
        case scalar_string(v) {
          Ok(vs) -> Ok(#(ks, vs))
          Error(_) ->
            Error(DecodeError(key <> " value for " <> ks <> " must be a scalar"))
        }
      })
    Ok(_) -> Error(DecodeError(key <> " must be a map"))
  }
}

// --- servers / roles -------------------------------------------------------

fn decode_servers(root: glaml.Node) -> Result(List(Role), GingerError) {
  case field(root, "servers") {
    Error(_) -> Error(ConfigError("missing required key: servers"))
    Ok(glaml.NodeMap(pairs)) ->
      list.try_map(pairs, fn(pair) {
        let #(key, value) = pair
        use name <- result.try(node_key_string(key))
        decode_role(name, value)
      })
    Ok(_) -> Error(DecodeError("servers must be a map of role -> config"))
  }
}

fn decode_role(name: String, node: glaml.Node) -> Result(Role, GingerError) {
  use hosts <- result.try(decode_hosts(node))
  let primary = optional_bool_node(node, "primary", False)
  let cmd = optional_string_node(node, "cmd")
  Ok(Role(name: name, hosts: hosts, primary: primary, cmd: cmd))
}

fn decode_hosts(node: glaml.Node) -> Result(List(String), GingerError) {
  case field(node, "hosts") {
    Error(_) -> Error(ConfigError("role is missing 'hosts'"))
    Ok(glaml.NodeSeq(items)) ->
      list.try_map(items, fn(item) {
        scalar_string(item)
        |> result.replace_error(DecodeError("host must be a scalar"))
      })
    Ok(_) -> Error(DecodeError("hosts must be a list"))
  }
}

// --- registry --------------------------------------------------------------

fn decode_registry(root: glaml.Node) -> Result(Registry, GingerError) {
  case field(root, "registry") {
    Error(_) -> Error(ConfigError("missing required key: registry"))
    Ok(reg) -> {
      use server <- result.try(required_string(reg, "server"))
      let username = optional_string_node(reg, "username") |> option.unwrap("")
      let password = optional_string_node(reg, "password") |> option.unwrap("")
      Ok(Registry(server: server, username: username, password: password))
    }
  }
}

// --- proxy -----------------------------------------------------------------

fn decode_proxy(root: glaml.Node) -> Result(Option(Proxy), GingerError) {
  case field(root, "proxy") {
    Error(_) -> Ok(None)
    Ok(p) -> {
      use hosts <- result.try(decode_proxy_hosts(p))
      use app_port <- result.try(optional_int(p, "app_port", 80))
      let ssl = optional_bool_node(p, "ssl", False)
      let health =
        optional_string_node(p, "health_check_path") |> option.unwrap("/up")
      use deploy_timeout <- result.try(optional_int(p, "deploy_timeout", 30))
      use drain_timeout <- result.try(optional_int(p, "drain_timeout", 30))
      Ok(
        Some(Proxy(
          hosts: hosts,
          app_port: app_port,
          ssl: ssl,
          health_check_path: health,
          deploy_timeout: deploy_timeout,
          drain_timeout: drain_timeout,
        )),
      )
    }
  }
}

/// Accept `host: "a.com"` (scalar) or `hosts: [a.com, b.com]` (list).
/// An empty proxy block with neither field produces an empty list (no routing).
fn decode_proxy_hosts(p: glaml.Node) -> Result(List(String), GingerError) {
  case field(p, "hosts"), field(p, "host") {
    Ok(glaml.NodeSeq(items)), _ ->
      list.try_map(items, fn(item) {
        scalar_string(item)
        |> result.replace_error(DecodeError("proxy host must be a scalar"))
      })
    _, Ok(node) ->
      scalar_string(node)
      |> result.map(fn(h) { [h] })
      |> result.replace_error(DecodeError("proxy.host must be a string"))
    _, _ -> Ok([])
  }
}

// --- builder ---------------------------------------------------------------

fn decode_builder(root: glaml.Node) -> Result(Builder, GingerError) {
  case field(root, "builder") {
    Error(_) ->
      Ok(Builder(
        arch: "amd64",
        remote: None,
        context: ".",
        dockerfile: None,
        tags: [],
        cache: CacheMin,
        provenance: False,
        build_args: [],
        push_registry: None,
      ))
    Ok(b) -> {
      let arch = optional_string_node(b, "arch") |> option.unwrap("amd64")
      let remote = optional_string_node(b, "remote")
      let context = optional_string_node(b, "context") |> option.unwrap(".")
      let dockerfile = optional_string_node(b, "dockerfile")
      use tags <- result.try(optional_string_list(b, "tags"))
      use cache <- result.try(decode_cache(b))
      let provenance = optional_bool_node(b, "provenance", False)
      let push_registry = optional_string_node(b, "push_registry")
      use build_args <- result.try(case field(b, "build_args") {
        Error(_) -> Ok([])
        Ok(glaml.NodeMap(pairs)) ->
          list.try_map(pairs, fn(pair) {
            let #(key, value) = pair
            use k <- result.try(node_key_string(key))
            case scalar_string(value) {
              Ok(v) -> Ok(#(k, v))
              Error(_) ->
                Error(DecodeError(
                  "build_args value for " <> k <> " must be a scalar",
                ))
            }
          })
        Ok(_) -> Error(DecodeError("build_args must be a map"))
      })
      Ok(Builder(
        arch: arch,
        remote: remote,
        context: context,
        dockerfile: dockerfile,
        tags: tags,
        cache: cache,
        provenance: provenance,
        build_args: build_args,
        push_registry: push_registry,
      ))
    }
  }
}

/// `builder.cache: none|min|max` (also accepts `false` for none). Default min.
fn decode_cache(b: glaml.Node) -> Result(CacheMode, GingerError) {
  case field(b, "cache") {
    Error(_) -> Ok(CacheMin)
    Ok(glaml.NodeBool(False)) -> Ok(CacheNone)
    Ok(glaml.NodeBool(True)) -> Ok(CacheMin)
    Ok(glaml.NodeStr("none")) -> Ok(CacheNone)
    Ok(glaml.NodeStr("min")) -> Ok(CacheMin)
    Ok(glaml.NodeStr("max")) -> Ok(CacheMax)
    Ok(_) ->
      Error(DecodeError("builder.cache must be one of: none, min, max, false"))
  }
}

// --- env -------------------------------------------------------------------

fn decode_env(
  root: glaml.Node,
) -> Result(List(#(String, String)), GingerError) {
  case field(root, "env") {
    Error(_) -> Ok([])
    Ok(glaml.NodeMap(pairs)) ->
      list.try_map(pairs, fn(pair) {
        let #(key, value) = pair
        use k <- result.try(node_key_string(key))
        case scalar_string(value) {
          Ok(v) -> Ok(#(k, v))
          Error(_) ->
            Error(DecodeError("env value for " <> k <> " must be a scalar"))
        }
      })
    Ok(_) -> Error(DecodeError("env must be a map"))
  }
}

// --- secrets ---------------------------------------------------------------

fn decode_secrets(root: glaml.Node) -> Result(Secrets, GingerError) {
  case field(root, "secrets") {
    Error(_) -> Ok(Secrets(load: [".env"], inject: []))
    Ok(s) -> {
      let load = case field(s, "load") {
        Ok(glaml.NodeSeq(items)) -> string_seq(items)
        _ -> [".env"]
      }
      let inject = case field(s, "inject") {
        Ok(glaml.NodeSeq(items)) -> string_seq(items)
        _ -> []
      }
      Ok(Secrets(load: load, inject: inject))
    }
  }
}

// --- rolling ---------------------------------------------------------------

fn decode_rolling(root: glaml.Node) -> Result(Rolling, GingerError) {
  case field(root, "rolling") {
    Error(_) -> Ok(Rolling(limit: Count(1), wait: 0, parallel_roles: False))
    Ok(r) -> {
      use limit <- result.try(decode_limit(r))
      use wait <- result.try(optional_int(r, "wait", 0))
      let parallel = optional_bool_node(r, "parallel_roles", False)
      Ok(Rolling(limit: limit, wait: wait, parallel_roles: parallel))
    }
  }
}

fn decode_limit(node: glaml.Node) -> Result(Limit, GingerError) {
  case field(node, "limit") {
    Error(_) -> Ok(Count(1))
    Ok(glaml.NodeInt(n)) -> Ok(Count(n))
    Ok(glaml.NodeStr(s)) -> parse_limit_string(s)
    Ok(_) ->
      Error(DecodeError("rolling.limit must be an int or percentage string"))
  }
}

fn parse_limit_string(s: String) -> Result(Limit, GingerError) {
  case string.ends_with(s, "%") {
    True ->
      case int.parse(string.drop_end(s, 1)) {
        Ok(n) -> Ok(Percent(n))
        Error(_) ->
          Error(DecodeError("invalid percentage in rolling.limit: " <> s))
      }
    False ->
      case int.parse(s) {
        Ok(n) -> Ok(Count(n))
        Error(_) -> Error(DecodeError("invalid rolling.limit: " <> s))
      }
  }
}

// --- pipelines (the polymorphic part) --------------------------------------

fn decode_pipelines(root: glaml.Node) -> Result(List(Pipeline), GingerError) {
  case field(root, "pipelines") {
    Error(_) -> Ok([])
    Ok(glaml.NodeMap(pairs)) ->
      list.try_map(pairs, fn(pair) {
        let #(key, value) = pair
        use name <- result.try(node_key_string(key))
        use steps <- result.try(decode_steps(name, value))
        Ok(Pipeline(name: name, steps: steps))
      })
    Ok(_) -> Error(DecodeError("pipelines must be a map of name -> steps"))
  }
}

fn decode_steps(
  pipeline: String,
  node: glaml.Node,
) -> Result(List(Step), GingerError) {
  case node {
    glaml.NodeSeq(items) -> list.try_map(items, decode_step(pipeline, _))
    _ ->
      Error(DecodeError("pipeline " <> pipeline <> " must be a list of steps"))
  }
}

fn decode_step(
  pipeline: String,
  node: glaml.Node,
) -> Result(Step, GingerError) {
  case node {
    glaml.NodeStr(name) -> bare_step(pipeline, name)
    glaml.NodeMap([#(key, value)]) -> {
      use name <- result.try(node_key_string(key))
      keyed_step(pipeline, name, value)
    }
    glaml.NodeMap(_) ->
      Error(DecodeError("step in " <> pipeline <> " must have exactly one key"))
    _ -> Error(DecodeError("invalid step in pipeline " <> pipeline))
  }
}

fn bare_step(pipeline: String, name: String) -> Result(Step, GingerError) {
  case name {
    "build" -> Ok(Build)
    "push" -> Ok(Push)
    "boot-proxy" -> Ok(BootProxy)
    "boot-app" -> Ok(BootApp(rolling: False, version: None))
    "prune" -> Ok(Prune)
    "healthcheck" -> Ok(Healthcheck)
    "remove-app" -> Ok(RemoveApp)
    _ ->
      Error(DecodeError(
        "unknown step '"
        <> name
        <> "' in pipeline "
        <> pipeline
        <> " (valid: build, push, boot-proxy, boot-app, prune, healthcheck, lock, hook)",
      ))
  }
}

fn keyed_step(
  pipeline: String,
  name: String,
  value: glaml.Node,
) -> Result(Step, GingerError) {
  case name {
    "boot-app" -> {
      let rolling = optional_bool_node(value, "rolling", False)
      let version = optional_string_node(value, "version")
      Ok(BootApp(rolling: rolling, version: version))
    }
    "lock" -> {
      use action <- result.try(
        scalar_string(value)
        |> result.replace_error(DecodeError("lock action must be a string")),
      )
      case action {
        "acquire" -> Ok(Lock(Acquire))
        "release" -> Ok(Lock(Release))
        "status" -> Ok(Lock(Status))
        _ -> Error(DecodeError("unknown lock action: " <> action))
      }
    }
    "hook" -> decode_hook(value)
    _ ->
      Error(DecodeError(
        "unknown step '" <> name <> "' in pipeline " <> pipeline,
      ))
  }
}

fn decode_hook(value: glaml.Node) -> Result(Step, GingerError) {
  case value {
    // hook: ./bin/foo   → local shell
    glaml.NodeStr(cmd) ->
      Ok(Hook(HookSpec(run: cmd, local: True, timeout: None)))
    // hook: { run: '...', local: true|false, timeout: <seconds> }
    glaml.NodeMap(_) -> {
      use run <- result.try(required_string(value, "run"))
      let local = optional_bool_node(value, "local", True)
      let timeout = case optional_int(value, "timeout", -1) {
        Ok(-1) -> None
        Ok(n) -> Some(n)
        Error(_) -> None
      }
      Ok(Hook(HookSpec(run: run, local: local, timeout: timeout)))
    }
    _ ->
      Error(DecodeError("hook must be a string or { run, local, timeout } map"))
  }
}

// --- runner / egress -------------------------------------------------------

/// Parse `runner` and `egress` together. Default: nomad + traefik.
/// Only two combinations are valid: nomad+traefik and docker+kamal-proxy.
fn decode_runtime_egress(
  root: glaml.Node,
) -> Result(#(RuntimeBackend, EgressBackend), GingerError) {
  let runner = optional_string_node(root, "runner")
  let egress = optional_string_node(root, "egress")
  case runner {
    option.None | option.Some("nomad") ->
      case egress {
        option.None | option.Some("traefik") ->
          Ok(#(NomadRuntime, TraefikEgress))
        option.Some("kamal-proxy") ->
          Error(ConfigError("runner: nomad requires egress: traefik"))
        option.Some(e) ->
          Error(DecodeError(
            "unknown egress: '" <> e <> "' (valid: kamal-proxy, traefik)",
          ))
      }
    option.Some("docker") ->
      case egress {
        option.None | option.Some("kamal-proxy") ->
          Ok(#(DockerRuntime, KamalProxyEgress))
        option.Some("traefik") ->
          Error(ConfigError("runner: docker requires egress: kamal-proxy"))
        option.Some(e) ->
          Error(DecodeError(
            "unknown egress: '" <> e <> "' (valid: kamal-proxy, traefik)",
          ))
      }
    option.Some(r) ->
      Error(DecodeError("unknown runner: '" <> r <> "' (valid: docker, nomad)"))
  }
}

// --- glaml node helpers ----------------------------------------------------

fn field(node: glaml.Node, key: String) -> Result(glaml.Node, Nil) {
  case node {
    glaml.NodeMap(pairs) -> find_pair(pairs, key)
    _ -> Error(Nil)
  }
}

fn find_pair(
  pairs: List(#(glaml.Node, glaml.Node)),
  key: String,
) -> Result(glaml.Node, Nil) {
  case pairs {
    [] -> Error(Nil)
    [#(k, v), ..rest] ->
      case k {
        glaml.NodeStr(s) if s == key -> Ok(v)
        _ -> find_pair(rest, key)
      }
  }
}

fn node_key_string(node: glaml.Node) -> Result(String, GingerError) {
  scalar_string(node)
  |> result.replace_error(DecodeError("map key must be a scalar"))
}

/// Coerce any scalar node to its string form.
fn scalar_string(node: glaml.Node) -> Result(String, Nil) {
  case node {
    glaml.NodeStr(s) -> Ok(s)
    glaml.NodeInt(n) -> Ok(int.to_string(n))
    glaml.NodeBool(True) -> Ok("true")
    glaml.NodeBool(False) -> Ok("false")
    glaml.NodeFloat(f) -> Ok(float.to_string(f))
    _ -> Error(Nil)
  }
}

fn string_seq(items: List(glaml.Node)) -> List(String) {
  items
  |> list.filter_map(scalar_string)
}

fn required_string(
  node: glaml.Node,
  key: String,
) -> Result(String, GingerError) {
  case field(node, key) {
    Error(_) -> Error(ConfigError("missing required key: " <> key))
    Ok(n) ->
      scalar_string(n)
      |> result.replace_error(DecodeError(key <> " must be a scalar string"))
  }
}

fn optional_string_node(node: glaml.Node, key: String) -> Option(String) {
  case field(node, key) {
    Ok(n) ->
      case scalar_string(n) {
        Ok(s) -> Some(s)
        Error(_) -> None
      }
    Error(_) -> None
  }
}

fn optional_int(
  node: glaml.Node,
  key: String,
  default: Int,
) -> Result(Int, GingerError) {
  case field(node, key) {
    Error(_) -> Ok(default)
    Ok(glaml.NodeInt(n)) -> Ok(n)
    Ok(glaml.NodeStr(s)) ->
      int.parse(s)
      |> result.replace_error(DecodeError(key <> " must be an integer"))
    Ok(_) -> Error(DecodeError(key <> " must be an integer"))
  }
}

fn optional_bool_node(node: glaml.Node, key: String, default: Bool) -> Bool {
  case field(node, key) {
    Ok(glaml.NodeBool(b)) -> b
    Ok(glaml.NodeStr("true")) -> True
    Ok(glaml.NodeStr("false")) -> False
    _ -> default
  }
}
