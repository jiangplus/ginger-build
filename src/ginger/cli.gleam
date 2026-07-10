import argv
import ginger/command
import ginger/commands/app as commands_app
import ginger/commands/history as commands_history
import ginger/commands/lock as commands_lock
import ginger/commands/nomad as commands_nomad
import ginger/commands/proxy as commands_proxy
import ginger/config.{type Config, container_prefix, primary_host}
import ginger/config/decode
import ginger/config/validate
import ginger/context
import ginger/deploy
import ginger/error.{type GingerError, ConfigError}
import ginger/fs
import ginger/pipeline
import ginger/runner
import ginger/secrets
import ginger/stack
import ginger/version
import gleam/dict
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

const version_string = "ginger 0.6.0"

/// Global flags, accepted anywhere on the command line — `ginger -c x deploy`
/// and `ginger deploy -c x` are equivalent (0.5.0 silently ignored flags
/// placed before the command and fell back to ./ginger.yml).
pub type Flags {
  Flags(
    configs: List(String),
    tag: Option(String),
    skip_push: Bool,
    build_concurrency: Int,
    follow: Bool,
    tail: Int,
  )
}

/// A parsed CLI invocation. Kept separate from execution so routing is pure
/// and unit-testable.
pub type Invocation {
  Help
  ShowVersion
  ConfigDump(config_path: String)
  RunPipeline(name: String, flags: Flags)
  LockCmd(action: String, config_path: String)
  StatusCmd(config_path: String)
  LogsCmd(config_path: String, follow: Bool, tail: Int)
  HistoryCmd(config_path: String, tail: Int)
  BadUsage(message: String)
}

/// Entry point: parse argv, route, and dispatch.
pub fn run() -> Nil {
  dispatch(route(argv.load().arguments))
}

/// Separate global flags (anywhere) from positional tokens.
pub fn parse_args(args: List(String)) -> #(List(String), Flags) {
  do_parse(
    args,
    [],
    Flags(
      configs: [],
      tag: None,
      skip_push: False,
      build_concurrency: 2,
      follow: False,
      tail: 100,
    ),
  )
}

fn do_parse(
  args: List(String),
  positional: List(String),
  flags: Flags,
) -> #(List(String), Flags) {
  case args {
    [] -> #(list.reverse(positional), flags)
    ["-c", value, ..rest] | ["--config", value, ..rest] ->
      do_parse(
        rest,
        positional,
        Flags(..flags, configs: list.append(flags.configs, [value])),
      )
    ["-t", value, ..rest] | ["--tag", value, ..rest] ->
      do_parse(rest, positional, Flags(..flags, tag: Some(value)))
    ["-P", ..rest] | ["--skip-push", ..rest] ->
      do_parse(rest, positional, Flags(..flags, skip_push: True))
    ["--build-concurrency", value, ..rest] ->
      do_parse(
        rest,
        positional,
        Flags(..flags, build_concurrency: int.parse(value) |> result.unwrap(2)),
      )
    ["-f", ..rest] | ["--follow", ..rest] ->
      do_parse(rest, positional, Flags(..flags, follow: True))
    ["--tail", value, ..rest] ->
      do_parse(
        rest,
        positional,
        Flags(..flags, tail: int.parse(value) |> result.unwrap(100)),
      )
    [arg, ..rest] -> do_parse(rest, [arg, ..positional], flags)
  }
}

/// Pure routing of raw arguments to an `Invocation`.
pub fn route(args: List(String)) -> Invocation {
  let #(positional, flags) = parse_args(args)
  let config_path = first_config(flags)
  case positional {
    [] -> Help
    ["help", ..] -> Help
    ["--help", ..] -> Help
    ["-h", ..] -> Help
    ["version", ..] -> ShowVersion
    ["--version", ..] -> ShowVersion
    ["config", ..] -> ConfigDump(config_path)
    ["deploy", ..] -> RunPipeline("deploy", flags)
    ["redeploy", ..] -> RunPipeline("redeploy", flags)
    ["remove", ..] -> RunPipeline("remove", Flags(..flags, skip_push: True))
    ["status", ..] -> StatusCmd(config_path)
    ["logs", ..] -> LogsCmd(config_path, flags.follow, flags.tail)
    ["history", ..] -> HistoryCmd(config_path, flags.tail)
    ["lock", "release", ..] -> LockCmd("release", config_path)
    ["lock", "status", ..] -> LockCmd("status", config_path)
    ["lock", "acquire", ..] -> LockCmd("acquire", config_path)
    ["rollback", target, ..] ->
      RunPipeline("rollback", Flags(..flags, tag: Some(target)))
    ["rollback"] -> BadUsage("rollback requires a version argument")
    ["run", name, ..] -> RunPipeline(name, flags)
    ["run"] -> BadUsage("run requires a pipeline name")
    [name, ..] -> RunPipeline(name, flags)
  }
}

fn first_config(flags: Flags) -> String {
  case flags.configs {
    [first, ..] -> first
    [] -> "ginger.yml"
  }
}

fn dispatch(invocation: Invocation) -> Nil {
  case invocation {
    Help -> io.println(help_text)
    ShowVersion -> io.println(version_string)
    ConfigDump(path) -> dump_config(path)
    RunPipeline(name, flags) ->
      case flags.configs {
        [_, _, ..] -> execute_group(name, flags)
        _ -> execute(name, first_config(flags), flags.skip_push, flags.tag)
      }
    LockCmd(action, path) -> run_lock(action, path)
    // status / logs / history: a same-named pipeline in the config wins, so
    // hook-driven setups can define their own (0.5.0's built-in `status`
    // silently shadowed user pipelines).
    StatusCmd(path) ->
      pipeline_or_builtin(path, "status", fn(cfg) { run_status(cfg) })
    LogsCmd(path, follow, tail) ->
      pipeline_or_builtin(path, "logs", fn(cfg) { run_logs(cfg, follow, tail) })
    HistoryCmd(path, tail) ->
      pipeline_or_builtin(path, "history", fn(cfg) { run_history(cfg, tail) })
    BadUsage(message) -> {
      io.println("✗ " <> message)
      halt(1)
    }
  }
}

/// If the config defines a pipeline with this name, run it; otherwise fall
/// back to the built-in implementation.
fn pipeline_or_builtin(
  config_path: String,
  name: String,
  builtin: fn(Config) -> Nil,
) -> Nil {
  with_config(config_path, fn(cfg) {
    case list.any(cfg.pipelines, fn(p) { p.name == name }) {
      True -> execute(name, config_path, True, Some("current"))
      False -> builtin(cfg)
    }
  })
}

// --- pipeline execution ----------------------------------------------------

fn execute(
  name: String,
  config_path: String,
  skip_push: Bool,
  version_override: Option(String),
) -> Nil {
  case do_execute(name, config_path, skip_push, version_override) {
    Ok(_) -> io.println("✓ " <> name <> " complete")
    Error(err) -> {
      io.println("✗ " <> error.to_string(err))
      halt(1)
    }
  }
}

fn do_execute(
  name: String,
  config_path: String,
  skip_push: Bool,
  version_override: Option(String),
) -> Result(Nil, GingerError) {
  use config <- result.try(load_config(config_path))
  use context <- result.try(build_context(config, version_override))
  use base <- result.try(deploy.select_pipeline(config, name))
  let selected = case skip_push {
    True -> deploy.without_build(base)
    False -> base
  }
  pipeline.run(context, selected) |> result.replace(Nil)
}

fn build_context(
  config: Config,
  version_override: Option(String),
) -> Result(context.Context, GingerError) {
  use resolved_version <- result.try(version.resolve(
    version_override,
    config.builder.context,
  ))
  let loaded_secrets = secrets.load(config.secrets)
  use _ <- result.try(preflight_secrets(loaded_secrets, config.secrets.inject))
  Ok(
    context.Context(
      config: config,
      version: resolved_version,
      secrets: loaded_secrets,
      runner: runner.real(config.ssh_user, config.ssh_timeout * 1000),
      log: fn(message) { io.println(message) },
    ),
  )
}

// --- multi-config (group) execution ------------------------------------------

fn execute_group(name: String, flags: Flags) -> Nil {
  case do_execute_group(name, flags) {
    Ok(_) -> io.println("✓ " <> name <> " complete (all services)")
    Error(err) -> {
      io.println("✗ " <> error.to_string(err))
      halt(1)
    }
  }
}

fn do_execute_group(name: String, flags: Flags) -> Result(Nil, GingerError) {
  use entries <- result.try(
    list.try_map(flags.configs, fn(path) {
      use config <- result.try(load_config(path))
      Ok(stack.Entry(path: stack.normalize(path), config: config))
    }),
  )
  use ordered <- result.try(stack.topo_order(entries))
  io.println(
    "Deploy order: "
    <> string.join(list.map(ordered, fn(e) { e.config.service }), " -> "),
  )
  use jobs <- result.try(
    list.try_map(ordered, fn(entry) {
      use ctx <- result.try(build_context(entry.config, flags.tag))
      use #(has_build, rest) <- result.try(stack.split_pipeline(
        entry.config,
        name,
      ))
      let build = case has_build && !flags.skip_push {
        True ->
          Some(fn() {
            pipeline.run_step(ctx, config.Build) |> result.replace(Nil)
          })
        False -> None
      }
      Ok(
        stack.Job(entry: entry, build: build, deploy: fn() {
          pipeline.run(ctx, rest) |> result.replace(Nil)
        }),
      )
    }),
  )
  stack.run_group(jobs, flags.build_concurrency, io.println)
}

fn preflight_secrets(
  loaded: dict.Dict(String, String),
  patterns: List(String),
) -> Result(Nil, GingerError) {
  let missing = secrets.missing_keys(loaded, patterns)
  case missing {
    [] -> Ok(Nil)
    keys ->
      Error(error.ConfigError(
        "secrets.inject keys not set (empty or missing): "
        <> string.join(keys, ", "),
      ))
  }
}

fn load_config(path: String) -> Result(Config, GingerError) {
  use yaml <- result.try(
    fs.read_file(path)
    |> result.map_error(fn(e) {
      ConfigError("cannot read " <> path <> ": " <> e)
    }),
  )
  use config <- result.try(decode.from_string(yaml))
  validate.validate(config)
}

/// Load config and run `then`, or print an error and halt.
fn with_config(path: String, then: fn(Config) -> Nil) -> Nil {
  case load_config(path) {
    Ok(cfg) -> then(cfg)
    Error(e) -> {
      io.println("✗ " <> error.to_string(e))
      halt(1)
    }
  }
}

// --- config dump -----------------------------------------------------------

fn dump_config(path: String) -> Nil {
  with_config(path, fn(cfg) { io.println(render_config(cfg)) })
}

fn render_config(config: Config) -> String {
  let roles =
    config.servers
    |> list.map(fn(role) {
      let marker = case role.primary {
        True -> " (primary)"
        False -> ""
      }
      "  - " <> role.name <> marker <> ": " <> string.join(role.hosts, ", ")
    })
    |> string.join("\n")

  let pipelines =
    config.pipelines
    |> list.map(fn(p) {
      "  - "
      <> p.name
      <> " ("
      <> int.to_string(list.length(p.steps))
      <> " steps)"
    })
    |> string.join("\n")

  let proxy_line = case config.proxy {
    Some(proxy) ->
      "proxy: "
      <> string.join(proxy.hosts, ", ")
      <> " -> :"
      <> int.to_string(proxy.app_port)
    None -> "proxy: (none)"
  }

  string.join(
    [
      "service: " <> config.service,
      "image: " <> config.image,
      "ssh user: " <> config.ssh_user,
      "registry: "
        <> config.registry.server
        <> " (password from secret: "
        <> config.registry.password
        <> ")",
      proxy_line,
      "roles:",
      roles,
      "inject secrets: " <> string.join(config.secrets.inject, ", "),
      "pipelines:",
      pipelines,
    ],
    "\n",
  )
}

// --- lock subcommands -------------------------------------------------------

fn run_lock(action: String, config_path: String) -> Nil {
  with_config(config_path, fn(cfg) {
    let r = runner.real(cfg.ssh_user, cfg.ssh_timeout * 1000)
    case primary_host(cfg) {
      Error(_) -> {
        io.println("✗ no primary host in config")
        halt(1)
      }
      Ok(host) -> {
        let cmd = case action {
          "release" -> commands_lock.release(cfg)
          "status" -> commands_lock.status(cfg)
          _ -> commands_lock.acquire(cfg)
        }
        case r.remote(host, cmd) {
          Ok(out) ->
            case string.trim(out) {
              "" -> io.println("✓ lock " <> action)
              s -> io.println(s)
            }
          Error(e) -> {
            io.println("✗ " <> error.to_string(e))
            halt(1)
          }
        }
      }
    }
  })
}

// --- status -----------------------------------------------------------------

fn run_status(cfg: Config) -> Nil {
  let r = runner.real(cfg.ssh_user, cfg.ssh_timeout * 1000)
  case cfg.runtime {
    config.NomadRuntime -> run_status_nomad(cfg, r)
    config.DockerRuntime -> run_status_docker(cfg, r)
  }
}

fn run_status_nomad(cfg: Config, r: context.Runner) -> Nil {
  list.each(cfg.servers, fn(role) {
    list.each(role.hosts, fn(host) {
      let #(out, exit) =
        r.probe(host, commands_nomad.status_job(cfg, role.name))
      case exit {
        0 -> io.println("[" <> host <> "]\n" <> out)
        _ ->
          io.println(
            "["
            <> host
            <> "] job "
            <> container_prefix(cfg, role.name)
            <> ": not found",
          )
      }
    })
  })
}

fn run_status_docker(cfg: Config, r: context.Runner) -> Nil {
  list.each(cfg.servers, fn(role) {
    list.each(role.hosts, fn(host) {
      let #(names, _) =
        r.probe(host, commands_app.running_names(cfg, role.name))
      let version = case string.trim(names) {
        "" -> "(none)"
        out -> {
          let prefix = container_prefix(cfg, role.name) <> "-"
          out
          |> string.split("\n")
          |> list.first
          |> result.unwrap("")
          |> string.trim
          |> fn(n) {
            case string.starts_with(n, prefix) {
              True -> string.drop_start(n, string.length(prefix))
              False -> n
            }
          }
        }
      }
      io.println(role.name <> "@" <> host <> "  version=" <> version)
    })
  })
  case primary_host(cfg) {
    Ok(host) -> {
      let #(proxy_name, _) = r.probe(host, commands_proxy.detect())
      case string.trim(proxy_name) {
        "" -> io.println("proxy: none detected")
        name -> {
          let list_cmd =
            command.raw("docker exec " <> name <> " kamal-proxy list")
          case r.remote(host, list_cmd) {
            Ok(out) -> io.println("\nproxy (" <> name <> "):\n" <> out)
            Error(_) -> io.println("proxy: " <> name <> " (could not query)")
          }
        }
      }
    }
    Error(_) -> Nil
  }
}

// --- logs ---------------------------------------------------------------------

/// Follow uses a 24h inactivity deadline — the stream stays open as long as
/// the service keeps logging; a silent day ends it.
const follow_timeout_ms = 86_400_000

fn run_logs(cfg: Config, follow: Bool, tail: Int) -> Nil {
  let r = runner.real(cfg.ssh_user, cfg.ssh_timeout * 1000)
  list.each(cfg.servers, fn(role) {
    list.each(role.hosts, fn(host) {
      let cmd = case cfg.runtime {
        config.NomadRuntime ->
          case follow {
            True -> commands_nomad.alloc_logs_follow(cfg, role.name)
            False -> commands_nomad.alloc_logs(cfg, role.name, tail)
          }
        config.DockerRuntime -> commands_app.logs(cfg, role.name, tail, follow)
      }
      case follow {
        True ->
          case r.remote_streamed(host, cmd, follow_timeout_ms) {
            Ok(_) -> Nil
            Error(e) -> io.println("✗ " <> error.to_string(e))
          }
        False -> {
          let #(out, _) = r.probe(host, cmd)
          case string.trim(out) {
            "" -> io.println("[" <> host <> "/" <> role.name <> "] (no logs)")
            trimmed ->
              trimmed
              |> string.split("\n")
              |> list.each(fn(line) {
                io.println("[" <> host <> "/" <> role.name <> "] " <> line)
              })
          }
        }
      }
    })
  })
}

// --- history -------------------------------------------------------------------

fn run_history(cfg: Config, tail: Int) -> Nil {
  let r = runner.real(cfg.ssh_user, cfg.ssh_timeout * 1000)
  case primary_host(cfg) {
    Error(_) -> {
      io.println("✗ no primary host in config")
      halt(1)
    }
    Ok(host) -> {
      let #(out, _) = r.probe(host, commands_history.show(cfg, tail))
      case string.trim(out) {
        "" ->
          io.println(
            "no deploy history recorded on "
            <> host
            <> " ("
            <> commands_history.log_path(cfg)
            <> ")",
          )
        trimmed -> io.println(trimmed)
      }
    }
  }
}

// --- arg helpers -----------------------------------------------------------

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> a

const help_text = "ginger — deploy containers anywhere, in Gleam

USAGE:
  ginger <command> [options]      (global options may appear anywhere)

COMMANDS:
  deploy             Build, push, and deploy with zero downtime
                     (repeat -c to deploy several services: builds run in
                      parallel, deploys follow each config's deps: order)
  redeploy           Deploy without booting the proxy or pruning
  rollback <version> Switch traffic back to a previous version
  remove             Deregister from proxy and remove all containers
  status             Show job/container status per host
  logs               Show service logs (--tail N, -f/--follow)
  history            Show the deploy audit log from the primary host
  lock release       Release a stuck deploy lock
  lock status        Show current lock holder
  lock acquire       Acquire the deploy lock manually
  run <pipeline>     Run a named pipeline from the config
  config             Print the parsed configuration (secrets redacted)
  version            Print the ginger version
  help               Show this help

OPTIONS:
  -c, --config <file>        Config file (default: ginger.yml); repeatable
  -P, --skip-push            Skip image build/push (use the registry image as-is)
  -t, --tag <version>        Pin the image tag; bypass git-sha resolution
  --build-concurrency <n>    Parallel builds in multi-config deploys (default 2)
  -f, --follow               Follow logs
  --tail <n>                 Log/history lines to show (default 100)

A pipeline in the config with the same name as a command (status, logs,
history, deploy, ...) takes precedence over the built-in behaviour.
Any other first argument is treated as a custom pipeline name."
