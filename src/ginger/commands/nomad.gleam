import ginger/command.{type Command}
import ginger/config.{
  type Config, type NomadJob, type Role, image_ref, nomad_job_id,
}
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/string

/// Submit a Nomad job for a role. The job uses the Docker driver and puts the
/// container on the named network so Traefik (also on that network) can
/// discover it via the Docker provider and the labels embedded in the spec.
///
/// The job JSON is piped via a heredoc so no shell escaping is needed for the
/// image name or env values.
pub fn run_job(
  config: Config,
  role: Role,
  version: String,
  env_pairs: List(#(String, String)),
  traefik_labels: List(#(String, String)),
  app_port: Int,
  registry_auth: option.Option(#(String, String)),
  network: String,
) -> Command {
  let j =
    job_json(
      config,
      role,
      version,
      env_pairs,
      traefik_labels,
      app_port,
      registry_auth,
      network,
    )
  command.raw("nomad job run -json - << 'NOMAD_EOF'\n" <> j <> "\nNOMAD_EOF")
}

/// Job-template mode: submit the operator's own HCL spec, passing the image
/// reference as an HCL2 variable.
///
/// `-detach` is deliberately NOT used: `nomad job run` blocks until the
/// deployment settles, and ginger's health gate polls afterwards anyway. The
/// blocking form also surfaces plan/parse errors as a non-zero exit.
///
/// When the config sets `nomad.var_file`, it is passed through as
/// `-var-file=<path>`. Order matters to Nomad only in that later `-var` wins
/// over a var file, which is what we want: the image ref ginger computed
/// always beats a stale value left in the file.
pub fn run_job_file(job: NomadJob, image_ref: String) -> Command {
  let var_file = case job.var_file {
    option.Some(path) -> ["-var-file=" <> path]
    option.None -> []
  }
  command.run(
    list.flatten([
      ["nomad", "job", "run"],
      var_file,
      ["-var", job.image_var <> "=" <> image_ref, job.job_file],
    ]),
  )
}

/// Gracefully stop (drain) a Nomad job and remove it from state.
pub fn stop_job(config: Config, role_name: String) -> Command {
  command.run(["nomad", "job", "stop", "-purge", job_id(config, role_name)])
}

/// Print the current Nomad job status.
pub fn status_job(config: Config, role_name: String) -> Command {
  command.run(["nomad", "job", "status", job_id(config, role_name)])
}

/// Print the latest deployment record for a job (used by the health gate).
/// Output includes a "Status = <value>" line with values: running, successful,
/// failed, cancelled, pending.
pub fn deployment_status(config: Config, role_name: String) -> Command {
  command.run([
    "nomad",
    "job",
    "deployments",
    "-latest",
    job_id(config, role_name),
  ])
}

/// Run Nomad garbage collection to reclaim resources from terminal allocations.
pub fn system_gc() -> Command {
  command.run(["nomad", "system", "gc"])
}

/// Tail the most recent allocation's stderr for a job — used to surface the
/// actual failure when a deployment goes unhealthy, instead of leaving the
/// operator to ssh in and dig.
pub fn alloc_logs_tail(config: Config, role_name: String) -> Command {
  command.raw(
    "nomad alloc logs -job -stderr "
    <> job_id(config, role_name)
    <> " 2>&1 | tail -40",
  )
}

/// Follow a job's live logs (stdout and stderr merged by the shell).
pub fn alloc_logs_follow(config: Config, role_name: String) -> Command {
  command.raw(
    "nomad alloc logs -f -job " <> job_id(config, role_name) <> " 2>&1",
  )
}

/// Tail a job's recent logs without following.
pub fn alloc_logs(config: Config, role_name: String, lines: Int) -> Command {
  command.raw(
    "nomad alloc logs -job "
    <> job_id(config, role_name)
    <> " 2>&1 | tail -"
    <> int.to_string(lines),
  )
}

// ---------------------------------------------------------------------------

fn job_id(config: Config, role_name: String) -> String {
  nomad_job_id(config, role_name)
}

fn job_json(
  config: Config,
  role: Role,
  version: String,
  env_pairs: List(#(String, String)),
  traefik_labels: List(#(String, String)),
  app_port: Int,
  registry_auth: option.Option(#(String, String)),
  network: String,
) -> String {
  let id = job_id(config, role.name)
  let image = image_ref(config, version)
  let all_labels =
    list.flatten([
      traefik_labels,
      config.labels,
      [
        #("service", config.service),
        #("role", role.name),
        #("version", version),
      ],
    ])
  let all_env =
    list.append(env_pairs, [
      #("GINGER_VERSION", version),
      #("GINGER_SERVICE", config.service),
    ])

  // Docker driver config — build up a field list so optional keys are only
  // present when needed; the type checker ensures the JSON structure is sound.
  let docker_fields = [
    #("image", json.string(image)),
    #("force_pull", json.bool(config.force_pull)),
    #("ports", json.array(["app"], json.string)),
    #("network_mode", json.string(network)),
    // labels must be a list-of-map, not a plain map, per the Docker driver.
    #(
      "labels",
      json.preprocessed_array([
        json.object(list.map(all_labels, fn(p) { #(p.0, json.string(p.1)) })),
      ]),
    ),
  ]

  // Optional container plumbing from the config: bind-mounts and /etc/hosts
  // entries, emitted only when present.
  let docker_fields = case config.volumes {
    [] -> docker_fields
    volumes ->
      list.append(docker_fields, [
        #("volumes", json.array(volumes, json.string)),
      ])
  }
  let docker_fields = case config.extra_hosts {
    [] -> docker_fields
    hosts ->
      list.append(docker_fields, [
        #("extra_hosts", json.array(hosts, json.string)),
      ])
  }

  let docker_fields = case registry_auth {
    option.Some(#(username, password)) ->
      list.append(docker_fields, [
        #(
          "auth",
          json.object([
            #("username", json.string(username)),
            #("password", json.string(password)),
          ]),
        ),
      ])
    option.None -> docker_fields
  }

  let docker_fields = case role.cmd {
    option.None -> docker_fields
    option.Some(cmd) ->
      case string.split(cmd, " ") {
        [prog, ..args] ->
          list.append(docker_fields, [
            #("command", json.string(prog)),
            #("args", json.array(args, json.string)),
          ])
        [] -> docker_fields
      }
  }

  // HealthyDeadline: how long Nomad waits for an allocation to become healthy.
  // Driven by deploy_timeout so ginger's gate and Nomad's gate agree.
  // ProgressDeadline must be strictly greater than HealthyDeadline (Nomad
  // rejects the job otherwise), so add a buffer. Both in nanoseconds.
  let healthy_deadline_ns = case config.proxy {
    option.Some(proxy) -> proxy.deploy_timeout * 1_000_000_000
    option.None -> 120 * 1_000_000_000
  }
  let progress_deadline_ns = healthy_deadline_ns + 60 * 1_000_000_000

  // Traefik routing as Nomad service tags, for Traefik's Nomad provider
  // (`providers.nomad`). Only emitted when `traefik_provider: nomad` is set in
  // ginger.yml; the default ("docker") relies on the Docker `labels` above
  // instead. The `loadbalancer.server.port` tag is dropped here: with dynamic
  // ports the Nomad service registers the published host port, and Traefik must
  // route to that — not the container's internal port.
  let traefik_tags =
    traefik_labels
    |> list.filter(fn(p) { !string.contains(p.0, "loadbalancer.server.port") })
    |> list.map(fn(p) { p.0 <> "=" <> p.1 })

  // Native Nomad service with HTTP health check. Only added when the config
  // has a proxy section (which supplies the health_check_path).
  let task_group_services = case config.proxy {
    option.None -> []
    option.Some(proxy) -> {
      let base_fields = [
        #("Name", json.string(id)),
        #("Provider", json.string("nomad")),
        #("PortLabel", json.string("app")),
        #(
          "Checks",
          json.preprocessed_array([
            json.object([
              #("Type", json.string("http")),
              #("Path", json.string(proxy.health_check_path)),
              // Nomad time values are in nanoseconds.
              #("Interval", json.int(5_000_000_000)),
              #("Timeout", json.int(2_000_000_000)),
            ]),
          ]),
        ),
      ]
      let service_fields = case config.traefik_provider {
        "nomad" ->
          list.append(base_fields, [
            #("Tags", json.array(traefik_tags, json.string)),
          ])
        _ -> base_fields
      }
      [#("Services", json.preprocessed_array([json.object(service_fields)]))]
    }
  }

  json.to_string(
    json.object([
      #(
        "Job",
        json.object([
          #("ID", json.string(id)),
          #("Name", json.string(id)),
          #("Type", json.string("service")),
          #("Datacenters", json.array(["dc1"], json.string)),
          #(
            "Update",
            json.object([
              #("MaxParallel", json.int(1)),
              #("AutoRevert", json.bool(True)),
              // MinHealthyTime: how long a task must pass checks before Nomad
              // considers this allocation healthy (10 s is a sane minimum).
              #("MinHealthyTime", json.int(10_000_000_000)),
              #("HealthyDeadline", json.int(healthy_deadline_ns)),
              #("ProgressDeadline", json.int(progress_deadline_ns)),
            ]),
          ),
          #(
            "TaskGroups",
            json.preprocessed_array([
              json.object(list.append(
                [
                  #("Name", json.string("app")),
                  #("Count", json.int(1)),
                  #(
                    "Networks",
                    json.preprocessed_array([
                      json.object([
                        #(
                          "DynamicPorts",
                          json.preprocessed_array([
                            json.object([
                              #("Label", json.string("app")),
                              #("To", json.int(app_port)),
                            ]),
                          ]),
                        ),
                      ]),
                    ]),
                  ),
                  #(
                    "Tasks",
                    json.preprocessed_array([
                      json.object([
                        #("Name", json.string("app")),
                        #("Driver", json.string("docker")),
                        #("Config", json.object(docker_fields)),
                        #(
                          "Env",
                          json.object(
                            list.map(all_env, fn(p) { #(p.0, json.string(p.1)) }),
                          ),
                        ),
                        #("Resources", json.object(resource_fields(config))),
                      ]),
                    ]),
                  ),
                ],
                task_group_services,
              )),
            ]),
          ),
        ]),
      ),
    ]),
  )
}

/// Build the Nomad `Resources` block. `MemoryMaxMB` is only emitted when
/// `resources.memory_max` is set above the reservation, opting the task into
/// memory over-provisioning; otherwise the task is capped at its reservation.
fn resource_fields(config: Config) -> List(#(String, json.Json)) {
  let base = [
    #("CPU", json.int(config.resources.cpu)),
    #("MemoryMB", json.int(config.resources.memory)),
  ]
  case config.resources.memory_max > config.resources.memory {
    True ->
      list.append(base, [
        #("MemoryMaxMB", json.int(config.resources.memory_max)),
      ])
    False -> base
  }
}

/// Parse the deployment status out of `nomad job deployments -latest` output.
/// Returns the status string ("successful", "failed", "running", etc.) or
/// "pending" when no deployment record is present yet.
pub fn parse_deployment_status(output: String) -> String {
  output
  |> string.split("\n")
  |> list.find_map(fn(line) {
    let trimmed = string.trim(line)
    // Match lines like "Status          = successful"
    case string.starts_with(trimmed, "Status") {
      False -> Error(Nil)
      True ->
        case string.split_once(trimmed, "=") {
          Ok(#(_, value)) -> Ok(string.trim(value))
          Error(_) -> Error(Nil)
        }
    }
  })
  |> result_unwrap_or("pending")
}

fn result_unwrap_or(result: Result(a, e), default: a) -> a {
  case result {
    Ok(v) -> v
    Error(_) -> default
  }
}
