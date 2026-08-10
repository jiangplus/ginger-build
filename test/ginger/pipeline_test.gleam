import ginger/command
import ginger/config.{
  type Config, BootApp, BootProxy, Build, Builder, Config, Count, DockerRuntime,
  KamalProxyEgress, Proxy, Prune, Registry, Role, Rolling, Secrets,
}
import ginger/context.{type Context, Context, Runner}
import ginger/pipeline
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string

fn test_config() -> Config {
  Config(
    service: "blog",
    image: "ghcr.io/acme/blog",
    servers: [Role(name: "web", hosts: ["10.0.0.1"], primary: True, cmd: None)],
    registry: Registry(server: "ghcr.io", username: "ci", password: "TOKEN"),
    proxy: Some(Proxy(
      hosts: ["blog.example.com"],
      app_port: 3000,
      ssl: True,
      health_check_path: "/up",
      deploy_timeout: 30,
      drain_timeout: 30,
    )),
    builder: Builder(
      arch: "amd64",
      remote: None,
      context: ".",
      dockerfile: None,
      tags: [],
      cache: config.CacheMin,
      provenance: False,
      build_args: [],
      push_registry: None,
    ),
    env: [],
    secrets: Secrets(load: [".env"], inject: []),
    rolling: Rolling(limit: Count(1), wait: 0, parallel_roles: False),
    retain_containers: 5,
    ssh_user: "root",
    pipelines: [],
    runtime: DockerRuntime,
    egress: KamalProxyEgress,
    network: "ginger",
    traefik_provider: "docker",
    force_pull: False,
    volumes: [],
    extra_hosts: [],
    labels: [],
    resources: config.Resources(cpu: 256, memory: 512, memory_max: 0),
    ssh_timeout: 600,
    deps: [],
    nomad_job: None,
    deploy_only: False,
    local_image: False,
  )
}

/// A fake runner that records `remote`/`local` commands in order. `probe` reads
/// answer host queries: `existing_proxy` is what proxy detection finds (empty
/// for "none"); container/version probes return empty so boot skips
/// rename/stop.
fn recording_context(sink: Subject(String), existing_proxy: String) -> Context {
  let probe = fn(_host, cmd) {
    let s = command.to_string(cmd)
    let is_network = string.contains(s, "NetworkSettings.Networks")
    let is_detect = string.contains(s, "kamal-proxy")
    // network_of check must come first (its command also contains "kamal-proxy")
    case is_network, is_detect {
      True, _ -> #("kamal", 0)
      _, True -> #(existing_proxy, 0)
      _, _ -> #("", 1)
    }
  }
  let runner =
    Runner(
      remote: fn(host, cmd) {
        process.send(sink, "remote:" <> host <> ":" <> command.to_string(cmd))
        Ok("")
      },
      remote_timed: fn(host, cmd, _timeout) {
        process.send(sink, "remote:" <> host <> ":" <> command.to_string(cmd))
        Ok("")
      },
      remote_streamed: fn(host, cmd, _timeout) {
        process.send(sink, "remote:" <> host <> ":" <> command.to_string(cmd))
        Ok("")
      },
      probe: probe,
      local: fn(cmd) {
        process.send(sink, "local:" <> command.to_string(cmd))
        Ok("")
      },
      local_streamed: fn(cmd) {
        process.send(sink, "local:" <> command.to_string(cmd))
        Ok("")
      },
      local_shell: fn(shell) {
        process.send(sink, "shell:" <> shell)
        Ok("")
      },
    )
  Context(
    config: test_config(),
    config_path: "ginger.yml",
    version: "v1",
    secrets: dict.new(),
    runner: runner,
    log: fn(_) { Nil },
  )
}

fn drain(sink: Subject(String), acc: List(String)) -> List(String) {
  case process.receive(sink, 0) {
    Ok(msg) -> drain(sink, [msg, ..acc])
    Error(_) -> list.reverse(acc)
  }
}

/// No proxy on the host → ginger boots its own on the ginger network.
pub fn deploy_boots_own_proxy_when_none_exists_test() {
  let sink = process.new_subject()
  let ctx = recording_context(sink, "")
  let pl =
    config.Pipeline(name: "deploy", steps: [
      Build,
      BootProxy,
      BootApp(rolling: False, version: None),
      Prune,
    ])
  let assert Ok(_) = pipeline.run(ctx, pl)
  let commands = drain(sink, [])

  // build, net, proxy, write-env-file, app-run, rm-env-file, proxy-deploy,
  // history-append, prune
  let assert [
    build,
    net,
    proxy,
    env_write,
    app,
    _env_rm,
    deploy,
    history,
    prune,
  ] = commands
  assert string.contains(history, ".ginger/history-blog.log")
  assert string.starts_with(build, "local:docker buildx build --push")
  assert string.contains(net, "docker network create ginger")
  assert string.contains(
    proxy,
    "docker container start ginger-proxy || docker run",
  )
  assert string.contains(env_write, "GINGER_ENV_EOF")
  assert string.contains(app, "docker run --detach")
  assert string.contains(app, "--network ginger")
  assert string.contains(app, "--env-file")
  assert string.contains(
    deploy,
    "docker exec ginger-proxy kamal-proxy deploy blog-web --target blog-web-v1:3000",
  )
  assert string.contains(prune, "docker container prune")
}

/// After a successful boot the old container is stopped and removed.
pub fn old_container_is_removed_after_successful_boot_test() {
  let sink = process.new_subject()
  // probe: no detect-proxy, old version "v0" is running for `running_names`
  let probe = fn(_host, cmd) {
    let s = command.to_string(cmd)
    let is_detect = string.contains(s, "kamal-proxy")
    let is_names = string.contains(s, "{{.Names}}")
    case is_detect, is_names {
      True, _ -> #("", 1)
      _, True -> #("blog-web-v0", 0)
      _, _ -> #("", 1)
    }
  }
  let runner =
    context.Runner(
      remote: fn(host, cmd) {
        process.send(sink, "remote:" <> host <> ":" <> command.to_string(cmd))
        Ok("")
      },
      remote_timed: fn(host, cmd, _timeout) {
        process.send(sink, "remote:" <> host <> ":" <> command.to_string(cmd))
        Ok("")
      },
      remote_streamed: fn(host, cmd, _timeout) {
        process.send(sink, "remote:" <> host <> ":" <> command.to_string(cmd))
        Ok("")
      },
      probe: probe,
      local: fn(cmd) {
        process.send(sink, "local:" <> command.to_string(cmd))
        Ok("")
      },
      local_streamed: fn(cmd) {
        process.send(sink, "local:" <> command.to_string(cmd))
        Ok("")
      },
      local_shell: fn(shell) {
        process.send(sink, "shell:" <> shell)
        Ok("")
      },
    )
  let ctx =
    Context(
      config: test_config(),
      config_path: "ginger.yml",
      version: "v1",
      secrets: dict.new(),
      runner: runner,
      log: fn(_) { Nil },
    )
  let pl =
    config.Pipeline(name: "x", steps: [BootApp(rolling: False, version: None)])
  let assert Ok(_) = pipeline.run(ctx, pl)
  let commands = drain(sink, [])

  // expect: ensure_network, start_or_run, docker run, proxy deploy, docker stop old, docker rm old
  let stop_cmds =
    list.filter(commands, fn(c) {
      string.contains(c, "container stop blog-web-v0")
    })
  let rm_cmds =
    list.filter(commands, fn(c) {
      string.contains(c, "container rm blog-web-v0")
    })
  assert list.length(stop_cmds) == 1
  assert list.length(rm_cmds) == 1
  // rm comes after stop
  let stop_idx = list_index(commands, list.first(stop_cmds))
  let rm_idx = list_index(commands, list.first(rm_cmds))
  assert rm_idx > stop_idx
}

fn list_index(items: List(String), target: Result(String, Nil)) -> Int {
  case target {
    Error(_) -> -1
    Ok(t) -> do_index(items, t, 0)
  }
}

fn do_index(items: List(String), target: String, idx: Int) -> Int {
  case items {
    [] -> -1
    [x, ..rest] ->
      case x == target {
        True -> idx
        False -> do_index(rest, target, idx + 1)
      }
  }
}

/// An existing kamal-proxy is detected → reuse it, join its network, register
/// against it. ginger does NOT boot a second proxy.
pub fn deploy_reuses_existing_proxy_test() {
  let sink = process.new_subject()
  let ctx = recording_context(sink, "kamal-proxy")
  let pl =
    config.Pipeline(name: "deploy", steps: [
      Build,
      BootProxy,
      BootApp(rolling: False, version: None),
      Prune,
    ])
  let assert Ok(_) = pipeline.run(ctx, pl)
  let commands = drain(sink, [])

  // build, ensure-network, write-env-file, app-run, rm-env-file, proxy-deploy,
  // history-append, prune
  let assert [build, _net, env_write, app, _env_rm, deploy, history, prune] =
    commands
  assert string.contains(history, ".ginger/history-blog.log")
  assert string.starts_with(build, "local:docker buildx build --push")
  assert string.contains(env_write, "GINGER_ENV_EOF")
  assert string.contains(app, "docker run --detach")
  assert string.contains(app, "--network kamal")
  assert string.contains(app, "--env-file")
  assert string.contains(
    deploy,
    "docker exec kamal-proxy kamal-proxy deploy blog-web --target blog-web-v1:3000",
  )
  assert string.contains(prune, "docker container prune")
  // no proxy was booted
  assert list.any(commands, fn(c) {
      string.contains(c, "start ginger-proxy")
      || string.contains(c, "run --name ginger-proxy")
    })
    == False
}
