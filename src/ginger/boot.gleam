import ginger/barrier
import ginger/commands/app
import ginger/commands/proxy as proxy_cmd
import ginger/config.{type Config, type Role, container_prefix}
import ginger/context.{type Context}
import ginger/error.{type GingerError, DeployAborted}
import ginger/rolling
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// Boot the application containers across all roles. Roles run primary-first.
/// When `parallel_roles` is set, non-primary roles boot concurrently with the
/// primary but wait at a barrier until the primary's containers are healthy.
pub fn run(
  context: Context,
  rolling_enabled: Bool,
) -> Result(Context, GingerError) {
  let roles = ordered_roles(context.config)
  case context.config.rolling.parallel_roles {
    False -> {
      use _ <- result.try(
        list.try_fold(roles, Nil, fn(_, role) {
          run_role(context, role, rolling_enabled)
        }),
      )
      Ok(context)
    }
    True -> run_roles_parallel(context, roles, rolling_enabled)
  }
}

// --- per-role rolling boot -------------------------------------------------

fn run_role(
  context: Context,
  role: Role,
  rolling_enabled: Bool,
) -> Result(Nil, GingerError) {
  let batch_list = case rolling_enabled {
    True -> rolling.batches(role.hosts, context.config.rolling.limit)
    False -> [role.hosts]
  }
  run_batches(context, role, batch_list)
}

fn run_batches(
  context: Context,
  role: Role,
  batch_list: List(List(String)),
) -> Result(Nil, GingerError) {
  case batch_list {
    [] -> Ok(Nil)
    [batch] -> boot_batch(context, role, batch)
    [batch, ..rest] -> {
      use _ <- result.try(boot_batch(context, role, batch))
      process.sleep(context.config.rolling.wait * 1000)
      run_batches(context, role, rest)
    }
  }
}

/// Boot all hosts in a batch concurrently; fail the batch if any host fails.
fn boot_batch(
  context: Context,
  role: Role,
  hosts: List(String),
) -> Result(Nil, GingerError) {
  parallel_results(hosts, fn(host) {
    boot_host(context, role, host) |> result.replace(Nil)
  })
}

// --- parallel-roles path (barrier-gated) -----------------------------------

fn run_roles_parallel(
  context: Context,
  roles: List(Role),
  rolling_enabled: Bool,
) -> Result(Context, GingerError) {
  let gate = barrier.new()
  let #(primaries, others) = list.partition(roles, fn(r) { r.primary })
  let sink = process.new_subject()

  list.each(primaries, fn(role) {
    process.spawn(fn() {
      let outcome = run_role(context, role, rolling_enabled)
      case outcome {
        Ok(_) -> barrier.open(gate)
        Error(_) -> barrier.close(gate)
      }
      process.send(sink, outcome)
    })
  })
  // No primary role → release the gate immediately.
  case primaries {
    [] -> barrier.open(gate)
    _ -> Nil
  }

  list.each(others, fn(role) {
    process.spawn(fn() {
      case barrier.wait(gate) {
        barrier.Released ->
          process.send(sink, run_role(context, role, rolling_enabled))
        barrier.Aborted ->
          process.send(
            sink,
            Error(DeployAborted(
              "role " <> role.name <> " not booted: primary role unhealthy",
            )),
          )
      }
    })
  })

  collect_results(sink, list.length(roles), Ok(Nil))
  |> result.replace(context)
}

// --- concurrency helpers ---------------------------------------------------

fn parallel_results(
  items: List(a),
  work: fn(a) -> Result(Nil, GingerError),
) -> Result(Nil, GingerError) {
  let sink = process.new_subject()
  list.each(items, fn(item) {
    process.spawn(fn() { process.send(sink, work(item)) })
  })
  collect_results(sink, list.length(items), Ok(Nil))
}

fn collect_results(
  sink: Subject(Result(Nil, GingerError)),
  remaining: Int,
  acc: Result(Nil, GingerError),
) -> Result(Nil, GingerError) {
  case remaining {
    0 -> acc
    _ -> {
      let result = process.receive_forever(sink)
      let next = case acc, result {
        Ok(_), Error(e) -> Error(e)
        _, _ -> acc
      }
      collect_results(sink, remaining - 1, next)
    }
  }
}

// --- single-host zero-downtime swap ----------------------------------------

/// Boot a single role's container on a single host: rename any clashing
/// container, start the new one, switch proxy traffic, then stop the old one.
pub fn boot_host(
  context: Context,
  role: Role,
  host: String,
) -> Result(Context, GingerError) {
  let config = context.config
  let version = context.version
  context.log("Booting " <> role.name <> " on " <> host <> "...")

  let #(existing_id, _) =
    context.runner.probe(host, app.container_id(config, role.name, version))
  use _ <- result.try(case string.trim(existing_id) {
    "" -> Ok("")
    _ ->
      context.runner.remote(
        host,
        app.rename(config, role.name, version, version <> "_replaced"),
      )
  })

  let #(running_out, _) =
    context.runner.probe(host, app.running_names(config, role.name))
  let old_version = parse_old_version(config, role.name, running_out)

  // Find which proxy serves this host and which network it is on, so the app
  // joins the right network and is registered with the right proxy container.
  let #(proxy_container, network) = resolve_proxy_info(context, host)

  use _ <- result.try(context.runner.remote(
    host,
    app.run(
      config,
      role,
      host,
      version,
      context.container_env(context),
      network,
    ),
  ))

  use _ <- result.try(case config.proxy {
    Some(proxy) ->
      context.runner.remote(
        host,
        proxy_cmd.deploy(config, role, proxy, version, proxy_container),
      )
    None -> Ok("")
  })

  // Deployment of the new container succeeded — stop AND remove the old one.
  case old_version {
    Some(ov) if ov != version -> {
      context.log("Removing old container for version " <> ov <> " on " <> host)
      let _ = context.runner.remote(host, app.stop(config, role.name, ov))
      let _ = context.runner.remote(host, app.remove(config, role.name, ov))
      Ok(context)
    }
    _ -> Ok(context)
  }
}

/// Ensure a proxy is available on the host. If one is already running (e.g. a
/// shared `kamal-proxy`), reuse it untouched and return its name. Otherwise
/// boot ginger's own proxy on the ginger network. Returns the proxy container
/// name to register against.
pub fn ensure_proxy(
  context: Context,
  host: String,
) -> Result(String, GingerError) {
  let #(found, _) = context.runner.probe(host, proxy_cmd.detect())
  case string.trim(found) {
    "" -> {
      context.log(
        "No proxy on " <> host <> "; booting " <> proxy_cmd.container <> "...",
      )
      use _ <- result.try(context.runner.remote(
        host,
        proxy_cmd.ensure_network(app.network),
      ))
      use _ <- result.try(context.runner.remote(host, proxy_cmd.start_or_run()))
      Ok(proxy_cmd.container)
    }
    name -> {
      context.log("Reusing existing proxy '" <> name <> "' on " <> host)
      Ok(name)
    }
  }
}

/// Determine the proxy container and the docker network it is on for a host.
/// Falls back to ginger's own proxy name + network when none is found.
/// Public so the remove step in pipeline.gleam can deregister against the
/// correct proxy.
pub fn resolve_proxy_info(context: Context, host: String) -> #(String, String) {
  let #(found, _) = context.runner.probe(host, proxy_cmd.detect())
  case string.trim(found) {
    "" -> #(proxy_cmd.container, app.network)
    name -> {
      let #(net, _) = context.runner.probe(host, proxy_cmd.network_of(name))
      case string.trim(net) {
        "" -> #(name, app.network)
        network -> #(name, network)
      }
    }
  }
}

/// Roles with the primary role first.
pub fn ordered_roles(config: Config) -> List(Role) {
  let #(primaries, others) = list.partition(config.servers, fn(r) { r.primary })
  list.append(primaries, others)
}

/// Extract the running version from `docker ps` name output. Names look like
/// `service-role-<version>`; strip the `service-role-` prefix off the first line.
pub fn parse_old_version(
  config: Config,
  role_name: String,
  ps_output: String,
) -> Option(String) {
  let prefix = container_prefix(config, role_name) <> "-"
  ps_output
  |> string.split("\n")
  |> list.map(string.trim)
  |> list.filter(fn(line) { line != "" })
  |> list.filter_map(fn(line) {
    case string.starts_with(line, prefix) {
      True -> Ok(string.drop_start(line, string.length(prefix)))
      False -> Error(Nil)
    }
  })
  |> list.first
  |> option.from_result
}
