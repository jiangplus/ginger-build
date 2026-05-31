import argv
import ginger/command
import ginger/commands/app as commands_app
import ginger/commands/lock as commands_lock
import ginger/commands/proxy as commands_proxy
import ginger/config.{type Config, container_prefix, primary_host}
import ginger/config/decode
import ginger/config/validate
import ginger/context.{type Context, Context}
import ginger/deploy
import ginger/error.{type GingerError, ConfigError}
import ginger/fs
import ginger/pipeline
import ginger/runner
import ginger/secrets
import ginger/version
import gleam/dict
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

const version_string = "ginger 0.1.2"

/// A parsed CLI invocation. Kept separate from execution so routing is pure
/// and unit-testable.
pub type Invocation {
  Help
  ShowVersion
  ConfigDump(config_path: String)
  RunPipeline(
    name: String,
    config_path: String,
    skip_push: Bool,
    version: Option(String),
  )
  LockCmd(action: String, config_path: String)
  StatusCmd(config_path: String)
}

/// Entry point: parse argv, route, and dispatch.
pub fn run() -> Nil {
  dispatch(route(argv.load().arguments))
}

/// Pure routing of raw arguments to an `Invocation`.
pub fn route(args: List(String)) -> Invocation {
  case args {
    [] -> Help
    ["help", ..] -> Help
    ["--help", ..] -> Help
    ["-h", ..] -> Help
    ["version", ..] -> ShowVersion
    ["--version", ..] -> ShowVersion
    ["config", ..rest] -> ConfigDump(config_flag(rest))
    ["deploy", ..rest] ->
      RunPipeline("deploy", config_flag(rest), skip_push(rest), tag_flag(rest))
    ["redeploy", ..rest] ->
      RunPipeline(
        "redeploy",
        config_flag(rest),
        skip_push(rest),
        tag_flag(rest),
      )
    ["remove", ..rest] ->
      RunPipeline("remove", config_flag(rest), True, tag_flag(rest))
    ["status", ..rest] -> StatusCmd(config_flag(rest))
    ["lock", "release", ..rest] -> LockCmd("release", config_flag(rest))
    ["lock", "status", ..rest] -> LockCmd("status", config_flag(rest))
    ["lock", "acquire", ..rest] -> LockCmd("acquire", config_flag(rest))
    ["rollback", target, ..rest] ->
      RunPipeline("rollback", config_flag(rest), False, Some(target))
    ["run", name, ..rest] ->
      RunPipeline(name, config_flag(rest), skip_push(rest), tag_flag(rest))
    [name, ..rest] ->
      RunPipeline(name, config_flag(rest), skip_push(rest), tag_flag(rest))
  }
}

fn dispatch(invocation: Invocation) -> Nil {
  case invocation {
    Help -> io.println(help_text)
    ShowVersion -> io.println(version_string)
    ConfigDump(path) -> dump_config(path)
    RunPipeline(name, path, skip, override) ->
      execute(name, path, skip, override)
    LockCmd(action, path) -> run_lock(action, path)
    StatusCmd(path) -> run_status(path)
  }
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
  use resolved_version <- result.try(version.resolve(version_override))
  let loaded_secrets = secrets.load(config.secrets)
  use _ <- result.try(preflight_secrets(loaded_secrets, config.secrets.inject))
  let context =
    context.Context(
      config: config,
      version: resolved_version,
      secrets: loaded_secrets,
      runner: runner.real(config.ssh_user),
      log: fn(message) { io.println(message) },
    )
  use base <- result.try(deploy.select_pipeline(config, name))
  let selected = case skip_push {
    True -> deploy.without_build(base)
    False -> base
  }
  pipeline.run(context, selected) |> result.replace(Nil)
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

// --- config dump -----------------------------------------------------------

fn dump_config(path: String) -> Nil {
  case load_config(path) {
    Ok(config) -> io.println(render_config(config))
    Error(err) -> {
      io.println("✗ " <> error.to_string(err))
      halt(1)
    }
  }
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
      "proxy: " <> proxy.host <> " -> :" <> int.to_string(proxy.app_port)
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
  case load_config(config_path) {
    Error(e) -> {
      io.println("✗ " <> error.to_string(e))
      halt(1)
    }
    Ok(cfg) -> {
      let r = runner.real(cfg.ssh_user)
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
    }
  }
}

// --- status -----------------------------------------------------------------

fn run_status(config_path: String) -> Nil {
  case load_config(config_path) {
    Error(e) -> {
      io.println("✗ " <> error.to_string(e))
      halt(1)
    }
    Ok(cfg) -> {
      let r = runner.real(cfg.ssh_user)
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
      // Show proxy registrations from the primary host.
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
                Error(_) ->
                  io.println("proxy: " <> name <> " (could not query)")
              }
            }
          }
        }
        Error(_) -> Nil
      }
    }
  }
}

// --- arg helpers -----------------------------------------------------------

fn config_flag(args: List(String)) -> String {
  find_value(args, ["-c", "--config"]) |> option.unwrap("ginger.yml")
}

/// `--tag <version>` pins the deploy version (image tag), bypassing git-sha
/// resolution. Useful to deploy a pre-built image.
fn tag_flag(args: List(String)) -> Option(String) {
  find_value(args, ["--tag", "-t"])
}

fn skip_push(args: List(String)) -> Bool {
  list.contains(args, "--skip-push") || list.contains(args, "-P")
}

fn find_value(args: List(String), names: List(String)) -> Option(String) {
  case args {
    [flag, value, ..rest] ->
      case list.contains(names, flag) {
        True -> Some(value)
        False -> find_value([value, ..rest], names)
      }
    _ -> None
  }
}

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> a

const help_text = "ginger — deploy containers anywhere, in Gleam

USAGE:
  ginger <command> [options]

COMMANDS:
  deploy             Build, push, and deploy with zero downtime
  redeploy           Deploy without booting the proxy or pruning
  rollback <version> Switch traffic back to a previous version
  remove             Deregister from proxy and remove all containers
  status             Show running version and proxy state per host
  lock release       Release a stuck deploy lock
  lock status        Show current lock holder
  lock acquire       Acquire the deploy lock manually
  run <pipeline>     Run a named pipeline from the config
  config             Print the parsed configuration (secrets redacted)
  version            Print the ginger version
  help               Show this help

OPTIONS:
  -c, --config <file>   Config file (default: ginger.yml)
  -P, --skip-push       Skip image build/push (use the registry image as-is)
  -t, --tag <version>   Pin the image tag; bypass git-sha resolution

Any other first argument is treated as a custom pipeline name from the config."
