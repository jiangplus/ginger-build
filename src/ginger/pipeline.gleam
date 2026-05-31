import ginger/boot
import ginger/commands/app as app_cmd
import ginger/commands/builder
import ginger/commands/lock as lock_cmd
import ginger/commands/proxy as proxy_cmd
import ginger/commands/prune as prune_cmd
import ginger/commands/registry as registry_cmd
import ginger/config.{
  type Pipeline, type Role, type Step, Acquire, BootApp, BootProxy, Build,
  Healthcheck, Hook, Lock, Prune, Push, Release, RemoveApp, Status,
}
import ginger/context.{type Context}
import ginger/error.{type GingerError, ConfigError, LockError}
import ginger/hooks
import ginger/secrets
import gleam/list
import gleam/option.{Some}
import gleam/result

/// Run all steps of a pipeline in order, threading the context. Short-circuits
/// on the first error.
pub fn run(
  context: Context,
  pipeline: Pipeline,
) -> Result(Context, GingerError) {
  context.log("Running pipeline: " <> pipeline.name)
  list.try_fold(pipeline.steps, context, run_step)
}

/// Interpret a single step.
pub fn run_step(context: Context, step: Step) -> Result(Context, GingerError) {
  case step {
    Build -> build(context)
    Push -> Ok(context)
    BootProxy -> boot_proxy(context)
    BootApp(rolling: rolling, version: _) -> boot.run(context, rolling)
    RemoveApp -> remove_app(context)
    Prune -> prune(context)
    Healthcheck -> Ok(context)
    Lock(Acquire) -> acquire_lock(context)
    Lock(Release) -> release_lock(context)
    Lock(Status) -> lock_status(context)
    Hook(spec) -> hooks.run(context, spec)
  }
}

fn build(context: Context) -> Result(Context, GingerError) {
  let config = context.config
  context.log("Building and pushing image...")
  // Login to the registry first if a password secret is configured.
  use _ <- result.try(
    case secrets.resolve(context.secrets, config.registry.password) {
      Some(password) ->
        context.runner.local(registry_cmd.login(config.registry, password))
      _ -> Ok("")
    },
  )
  use _ <- result.try(
    context.runner.local(builder.build(config, context.version)),
  )
  Ok(context)
}

fn boot_proxy(context: Context) -> Result(Context, GingerError) {
  context.log("Ensuring a proxy is running (reusing any existing one)...")
  use _ <- result.try(
    list.try_fold(config.all_hosts(context.config), Nil, fn(_, host) {
      use _ <- result.try(boot.ensure_proxy(context, host))
      Ok(Nil)
    }),
  )
  Ok(context)
}

fn remove_app(context: Context) -> Result(Context, GingerError) {
  context.log("Removing deployment...")
  use _ <- result.try(
    list.try_fold(context.config.servers, Nil, fn(_, role) {
      list.try_fold(role.hosts, Nil, fn(_, host) {
        remove_host(context, role, host)
      })
    }),
  )
  Ok(context)
}

fn remove_host(
  context: Context,
  role: config.Role,
  host: String,
) -> Result(Nil, GingerError) {
  let #(proxy_container, _) = boot.resolve_proxy_info(context, host)
  case context.config.proxy {
    Some(_) -> {
      let _ =
        context.runner.remote(
          host,
          proxy_cmd.remove(context.config, role, proxy_container),
        )
      Nil
    }
    _ -> Nil
  }
  context.log("  " <> role.name <> " on " <> host)
  let _ =
    context.runner.remote(host, app_cmd.stop_all(context.config, role.name))
  use _ <- result.try(context.runner.remote(
    host,
    app_cmd.remove_all(context.config, role.name),
  ))
  Ok(Nil)
}

fn prune(context: Context) -> Result(Context, GingerError) {
  context.log("Pruning old containers and images...")
  use _ <- result.try(
    list.try_fold(config.all_hosts(context.config), Nil, fn(_, host) {
      use _ <- result.try(context.runner.remote(
        host,
        prune_cmd.all(context.config),
      ))
      Ok(Nil)
    }),
  )
  Ok(context)
}

fn acquire_lock(context: Context) -> Result(Context, GingerError) {
  use host <- with_primary_host(context)
  context.log("Acquiring deploy lock on " <> host <> "...")
  use _ <- result.try(context.runner.remote(
    host,
    lock_cmd.ensure_run_directory(),
  ))
  case context.runner.remote(host, lock_cmd.acquire(context.config)) {
    Ok(_) -> Ok(context)
    Error(_) ->
      Error(LockError(
        "deploy lock already held on " <> host <> " (run `ginger lock release`)",
      ))
  }
}

fn release_lock(context: Context) -> Result(Context, GingerError) {
  use host <- with_primary_host(context)
  context.log("Releasing deploy lock...")
  let _ = context.runner.remote(host, lock_cmd.release(context.config))
  Ok(context)
}

fn lock_status(context: Context) -> Result(Context, GingerError) {
  use host <- with_primary_host(context)
  let #(out, _) = context.runner.probe(host, lock_cmd.status(context.config))
  context.log(out)
  Ok(context)
}

fn with_primary_host(
  context: Context,
  next: fn(String) -> Result(Context, GingerError),
) -> Result(Context, GingerError) {
  case config.primary_host(context.config) {
    Ok(host) -> next(host)
    Error(_) -> Error(ConfigError("no primary host to run lock on"))
  }
}
