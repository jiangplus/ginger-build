import ginger/barrier
import ginger/commands/app
import ginger/commands/nomad as nomad_cmd
import ginger/commands/proxy as proxy_cmd
import ginger/commands/registry as registry_cmd
import ginger/commands/traefik as traefik_cmd
import ginger/config.{
  type Config, type Role, DockerRuntime, KamalProxyEgress, NomadRuntime,
  TraefikEgress, container_prefix,
}
import ginger/context.{type Context, container_env, plain_env, secret_env}
import ginger/error.{type GingerError, DeployAborted}
import ginger/rolling
import ginger/secrets
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

/// Boot a single role's container on a single host. Dispatches to the
/// runtime-specific implementation (Docker or Nomad).
pub fn boot_host(
  context: Context,
  role: Role,
  host: String,
) -> Result(Context, GingerError) {
  case context.config.runtime {
    DockerRuntime -> boot_host_docker(context, role, host)
    NomadRuntime -> boot_host_nomad(context, role, host)
  }
}

/// Docker path: rename any clashing container, start the new one, switch
/// proxy traffic (kamal-proxy), then stop and remove the old one.
fn boot_host_docker(
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

  use _ <- result.try(
    case secrets.resolve(context.secrets, config.registry.password) {
      Some(password) ->
        context.runner.remote(
          host,
          registry_cmd.login_stdin(config.registry, password),
        )
      option.None -> Ok("")
    },
  )

  let #(proxy_container, network) = resolve_proxy_info(context, host)

  let extra_labels = traefik_labels_for(context, role)

  let env_file = app.env_file_path(config, role.name, version)
  use _ <- result.try(context.runner.remote(
    host,
    app.write_env_file(env_file, secret_env(context)),
  ))

  use _ <- result.try(context.runner.remote(
    host,
    app.run(
      config,
      role,
      host,
      version,
      plain_env(context),
      env_file,
      network,
      extra_labels,
    ),
  ))

  let _ = context.runner.remote(host, app.remove_env_file(env_file))

  use _ <- result.try(case config.egress, config.proxy {
    KamalProxyEgress, Some(proxy) ->
      context.runner.remote(
        host,
        proxy_cmd.deploy(config, role, proxy, version, proxy_container),
      )
    _, _ -> Ok("")
  })

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

/// Nomad path: submit a Nomad job with the Docker driver. Traefik labels are
/// embedded in the job spec so Traefik auto-discovers the service. Nomad
/// handles rolling updates and container lifecycle internally.
fn boot_host_nomad(
  context: Context,
  role: Role,
  host: String,
) -> Result(Context, GingerError) {
  let config = context.config
  let version = context.version
  context.log(
    "Submitting Nomad job "
    <> config.service
    <> "-"
    <> role.name
    <> " on "
    <> host
    <> "...",
  )

  use _ <- result.try(
    case secrets.resolve(context.secrets, config.registry.password) {
      Some(password) ->
        context.runner.remote(
          host,
          registry_cmd.login_stdin(config.registry, password),
        )
      option.None -> Ok("")
    },
  )

  let t_labels = traefik_labels_for(context, role)
  let app_port = case config.proxy {
    Some(proxy) -> proxy.app_port
    None -> 80
  }

  // Nomad's docker driver does not read the host's ~/.docker/config.json, so
  // embed registry auth in the task config for private image pulls.
  let registry_auth =
    case secrets.resolve(context.secrets, config.registry.password) {
      Some(password) -> Some(#(config.registry.username, password))
      option.None -> option.None
    }

  use _ <- result.try(context.runner.remote(
    host,
    nomad_cmd.run_job(
      config,
      role,
      version,
      // Nomad embeds env (incl. secrets) in the job spec's Env map, which is
      // piped via stdin heredoc — not exposed in process args.
      container_env(context),
      t_labels,
      app_port,
      registry_auth,
    ),
  ))

  Ok(context)
}

/// Traefik routing labels for a role, or empty list when egress is kamal-proxy
/// or there is no proxy config.
fn traefik_labels_for(context: Context, role: Role) -> List(#(String, String)) {
  case context.config.egress, context.config.proxy {
    TraefikEgress, Some(proxy) ->
      traefik_cmd.labels(context.config, role, proxy)
    _, _ -> []
  }
}

/// Ensure the egress proxy is available on the host. Dispatches to the
/// egress-specific implementation. Returns the proxy container name.
pub fn ensure_proxy(
  context: Context,
  host: String,
) -> Result(String, GingerError) {
  case context.config.egress {
    KamalProxyEgress -> ensure_kamal_proxy(context, host)
    TraefikEgress -> ensure_traefik(context, host)
  }
}

fn ensure_kamal_proxy(
  context: Context,
  host: String,
) -> Result(String, GingerError) {
  case detect_kamal_proxy(context, host) {
    Some(name) -> {
      context.log("Reusing existing proxy '" <> name <> "' on " <> host)
      Ok(name)
    }
    None -> {
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
  }
}

fn ensure_traefik(
  context: Context,
  host: String,
) -> Result(String, GingerError) {
  case detect_traefik(context, host) {
    Some(name) -> {
      context.log("Reusing existing Traefik '" <> name <> "' on " <> host)
      Ok(name)
    }
    None -> {
      context.log(
        "No Traefik on "
        <> host
        <> "; booting "
        <> traefik_cmd.container
        <> "...",
      )
      use _ <- result.try(context.runner.remote(
        host,
        proxy_cmd.ensure_network(app.network),
      ))
      use _ <- result.try(
        context.runner.remote(host, traefik_cmd.start_or_run()),
      )
      Ok(traefik_cmd.container)
    }
  }
}

fn detect_kamal_proxy(context: Context, host: String) -> option.Option(String) {
  let #(found, _) = context.runner.probe(host, proxy_cmd.detect())
  case string.trim(found) {
    "" -> None
    name -> Some(name)
  }
}

fn detect_traefik(context: Context, host: String) -> option.Option(String) {
  let #(found, _) = context.runner.probe(host, traefik_cmd.detect())
  case string.trim(found) {
    "" -> None
    name -> Some(name)
  }
}

/// Determine the proxy container and docker network for a host.
/// Public so the remove step in pipeline.gleam can deregister correctly.
pub fn resolve_proxy_info(context: Context, host: String) -> #(String, String) {
  let detect_fn = case context.config.egress {
    KamalProxyEgress -> fn() { detect_kamal_proxy(context, host) }
    TraefikEgress -> fn() { detect_traefik(context, host) }
  }
  let network_cmd_fn = case context.config.egress {
    KamalProxyEgress -> proxy_cmd.network_of
    TraefikEgress -> traefik_cmd.network_of
  }
  let default_container = case context.config.egress {
    KamalProxyEgress -> proxy_cmd.container
    TraefikEgress -> traefik_cmd.container
  }
  case detect_fn() {
    None -> #(default_container, app.network)
    Some(name) -> {
      let #(net, _) = context.runner.probe(host, network_cmd_fn(name))
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
