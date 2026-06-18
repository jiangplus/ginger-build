import ginger/command.{type Command}
import ginger/config.{type Config, type Role, container_prefix, image_ref}
import gleam/int
import gleam/list
import gleam/option
import gleam/string

/// Submit a Nomad job for a role. The job uses the Docker driver and puts the
/// container on the `ginger` network so Traefik (also on that network) can
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
) -> Command {
  let json =
    job_json(
      config,
      role,
      version,
      env_pairs,
      traefik_labels,
      app_port,
      registry_auth,
    )
  command.raw(
    "nomad job run -json - << 'NOMAD_EOF'\n" <> json <> "\nNOMAD_EOF",
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

  "{"
  <> "\"Job\":{"
  <> "\"ID\":\""
  <> id
  <> "\","
  <> "\"Name\":\""
  <> id
  <> "\","
  <> "\"Type\":\"service\","
  <> "\"Datacenters\":[\"dc1\"],"
  <> "\"Update\":{\"MaxParallel\":1,\"AutoRevert\":true},"
  <> "\"TaskGroups\":[{"
  <> "\"Name\":\"app\","
  <> "\"Count\":1,"
  <> "\"Networks\":[{\"DynamicPorts\":[{\"Label\":\"app\",\"To\":"
  <> int.to_string(app_port)
  <> "}]}],"
  <> "\"Tasks\":[{"
  <> "\"Name\":\"app\","
  <> "\"Driver\":\"docker\","
  <> "\"Config\":{"
  <> "\"image\":\""
  <> json_escape(image)
  <> "\","
  <> "\"ports\":[\"app\"],"
  <> "\"network_mode\":\"ginger\","
  <> "\"labels\":[{"
  <> json_map(all_labels)
  <> "}]"
  <> case registry_auth {
    option.Some(#(username, password)) ->
      ",\"auth\":{\"username\":\""
      <> json_escape(username)
      <> "\",\"password\":\""
      <> json_escape(password)
      <> "\"}"
    option.None -> ""
  }
  <> case role.cmd {
    option.None -> ""
    option.Some(cmd) ->
      case string.split(cmd, " ") {
        [prog, ..] -> ",\"command\":\"" <> json_escape(prog) <> "\""
        [] -> ""
      }
  }
  <> "},"
  <> "\"Env\":{"
  <> json_map(all_env)
  <> "},"
  <> "\"Resources\":{\"CPU\":256,\"MemoryMB\":512}"
  <> "}]"
  <> "}]"
  <> "}}"
}

fn json_map(pairs: List(#(String, String))) -> String {
  pairs
  |> list.map(fn(p) {
    "\"" <> json_escape(p.0) <> "\":\"" <> json_escape(p.1) <> "\""
  })
  |> string.join(",")
}

fn json_escape(s: String) -> String {
  s
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
  |> string.replace("\r", "\\r")
  |> string.replace("\t", "\\t")
}
