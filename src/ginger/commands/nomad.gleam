import ginger/command.{type Command}
import ginger/config.{type Config, type Role, container_prefix, image_ref}
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
  let j = job_json(config, role, version, env_pairs, traefik_labels, app_port, registry_auth, network)
  command.raw(
    "nomad job run -json - << 'NOMAD_EOF'\n" <> j <> "\nNOMAD_EOF",
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
    "nomad", "job", "deployments", "-latest", job_id(config, role_name),
  ])
}

/// Run Nomad garbage collection to reclaim resources from terminal allocations.
pub fn system_gc() -> Command {
  command.run(["nomad", "system", "gc"])
}

// ---------------------------------------------------------------------------

fn job_id(config: Config, role_name: String) -> String {
  container_prefix(config, role_name)
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
    list.append(traefik_labels, [
      #("service", config.service),
      #("role", role.name),
      #("version", version),
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

  // ProgressDeadline: maximum time Nomad waits for the deployment to become
  // healthy before marking it failed and triggering AutoRevert. Expressed in
  // nanoseconds — use deploy_timeout so ginger's gate and Nomad's gate agree.
  let deadline_ns = case config.proxy {
    option.Some(proxy) -> proxy.deploy_timeout * 1_000_000_000
    option.None -> 120 * 1_000_000_000
  }

  // Native Nomad service with HTTP health check. Only added when the config
  // has a proxy section (which supplies the health_check_path).
  let task_group_services = case config.proxy {
    option.None -> []
    option.Some(proxy) -> [
      #(
        "Services",
        json.preprocessed_array([
          json.object([
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
          ]),
        ]),
      ),
    ]
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
              #("ProgressDeadline", json.int(deadline_ns)),
            ]),
          ),
          #(
            "TaskGroups",
            json.preprocessed_array([
              json.object(
                list.append(
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
                              list.map(all_env, fn(p) {
                                #(p.0, json.string(p.1))
                              }),
                            ),
                          ),
                          #(
                            "Resources",
                            json.object([
                              #("CPU", json.int(256)),
                              #("MemoryMB", json.int(512)),
                            ]),
                          ),
                        ]),
                      ]),
                    ),
                  ],
                  task_group_services,
                ),
              ),
            ]),
          ),
        ]),
      ),
    ]),
  )
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
