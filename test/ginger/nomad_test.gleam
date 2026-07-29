import ginger/command
import ginger/commands/nomad
import ginger/config.{
  type Config, type Role, Builder, Config, Count, NomadJob, NomadRuntime, Proxy,
  Registry, Role, Rolling, Secrets, TraefikEgress,
}
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import gleam/string

fn test_config() -> Config {
  Config(
    service: "blog",
    image: "ghcr.io/acme/blog",
    servers: [Role(name: "web", hosts: ["10.0.0.1"], primary: True, cmd: None)],
    registry: Registry(
      server: "ghcr.io",
      username: "ci",
      password: "GITHUB_TOKEN",
    ),
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
    runtime: NomadRuntime,
    egress: TraefikEgress,
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
  )
}

fn web_role() -> Role {
  Role(name: "web", hosts: ["10.0.0.1"], primary: True, cmd: None)
}

fn run_cmd(
  env_pairs: List(#(String, String)),
  traefik_labels: List(#(String, String)),
  registry_auth: option.Option(#(String, String)),
  network: String,
) -> String {
  nomad.run_job(
    test_config(),
    web_role(),
    "abc123",
    env_pairs,
    traefik_labels,
    3000,
    registry_auth,
    network,
  )
  |> command.to_string
  |> extract_json_body
}

/// Extract the JSON body from between the heredoc markers.
/// The raw command is: `nomad job run -json - << 'NOMAD_EOF'\n{JSON}\nNOMAD_EOF`
fn extract_json_body(full: String) -> String {
  case string.split_once(full, "'NOMAD_EOF'\n") {
    Ok(#(_, rest)) ->
      case string.split_once(rest, "\nNOMAD_EOF") {
        Ok(#(body, _)) -> body
        Error(_) -> rest
      }
    Error(_) -> full
  }
}

// ---------------------------------------------------------------------------
// Structural correctness tests

pub fn job_spec_valid_json_test() {
  let raw = run_cmd([], [], None, "ginger")
  let assert Ok(_) = json.parse(raw, decode.dynamic)
}

pub fn job_spec_top_level_keys_test() {
  let raw = run_cmd([], [], None, "ginger")
  let assert Ok(job_id) =
    json.parse(raw, decode.at(["Job", "ID"], decode.string))
  assert job_id == "blog-web"
}

pub fn job_spec_labels_is_array_not_object_test() {
  // The Docker driver requires labels to be a list-of-map, not a plain map.
  // Verify by checking the raw JSON — json.to_string never adds whitespace.
  let raw = run_cmd([], [#("traefik.enable", "true")], None, "ginger")
  assert string.contains(raw, "\"labels\":[{")
}

pub fn job_spec_env_contains_injected_secret_test() {
  let raw =
    run_cmd([#("DATABASE_URL", "postgres://localhost")], [], None, "ginger")
  assert string.contains(raw, "\"DATABASE_URL\":\"postgres://localhost\"")
}

pub fn job_spec_env_contains_ginger_version_test() {
  let raw = run_cmd([], [], None, "ginger")
  assert string.contains(raw, "\"GINGER_VERSION\":\"abc123\"")
}

pub fn job_spec_auth_present_when_credentials_given_test() {
  let raw = run_cmd([], [], Some(#("myuser", "mypassword")), "ginger")
  assert string.contains(raw, "\"auth\":{")
  assert string.contains(raw, "\"username\":\"myuser\"")
  assert string.contains(raw, "\"password\":\"mypassword\"")
}

pub fn job_spec_auth_absent_when_no_credentials_test() {
  let raw = run_cmd([], [], None, "ginger")
  assert string.contains(raw, "\"auth\"") == False
}

pub fn job_spec_network_mode_configurable_test() {
  let raw = run_cmd([], [], None, "mynet")
  assert string.contains(raw, "\"network_mode\":\"mynet\"")
}

pub fn job_spec_network_mode_default_test() {
  let raw = run_cmd([], [], None, "ginger")
  assert string.contains(raw, "\"network_mode\":\"ginger\"")
}

pub fn job_spec_traefik_labels_present_test() {
  let raw =
    run_cmd(
      [],
      [
        #("traefik.enable", "true"),
        #("traefik.http.routers.blog-web.rule", "Host(`blog.example.com`)"),
      ],
      None,
      "ginger",
    )
  assert string.contains(raw, "\"traefik.enable\":\"true\"")
  assert string.contains(
    raw,
    "\"traefik.http.routers.blog-web.rule\":\"Host(`blog.example.com`)\"",
  )
}

pub fn job_spec_service_labels_always_present_test() {
  let raw = run_cmd([], [], None, "ginger")
  assert string.contains(raw, "\"service\":\"blog\"")
  assert string.contains(raw, "\"role\":\"web\"")
  assert string.contains(raw, "\"version\":\"abc123\"")
}

// ---------------------------------------------------------------------------
// Fail-fast: Update block deadlines

pub fn job_spec_update_has_progress_deadline_test() {
  let raw = run_cmd([], [], None, "ginger")
  // deploy_timeout=30 → HealthyDeadline 30s; ProgressDeadline = healthy + 60s.
  assert string.contains(raw, "\"HealthyDeadline\":30000000000")
  assert string.contains(raw, "\"ProgressDeadline\":90000000000")
}

pub fn job_spec_nomad_tags_present_when_provider_nomad_test() {
  // traefik_provider: nomad → routing emitted as Nomad service Tags, minus
  // the loadbalancer.server.port tag (dynamic port is used).
  let cfg = Config(..test_config(), traefik_provider: "nomad")
  let raw =
    nomad.run_job(
      cfg,
      web_role(),
      "abc123",
      [],
      [
        #("traefik.enable", "true"),
        #("traefik.http.routers.blog-web.rule", "Host(`blog.example.com`)"),
        #("traefik.http.services.blog-web.loadbalancer.server.port", "3000"),
      ],
      3000,
      None,
      "ginger",
    )
    |> command.to_string
    |> extract_json_body
  assert string.contains(raw, "\"Tags\":[")
  assert string.contains(raw, "traefik.enable=true")
  // The tag form ("key=value") of the port is dropped; the Docker label form
  // ("key":"value") is still emitted and is harmless for the Nomad provider.
  assert string.contains(raw, "loadbalancer.server.port=") == False
}

pub fn job_spec_nomad_tags_absent_when_provider_docker_test() {
  let raw = run_cmd([], [#("traefik.enable", "true")], None, "ginger")
  assert string.contains(raw, "\"Tags\":[") == False
}

pub fn job_spec_update_has_min_healthy_time_test() {
  let raw = run_cmd([], [], None, "ginger")
  assert string.contains(raw, "\"MinHealthyTime\":10000000000")
}

pub fn job_spec_services_present_when_proxy_configured_test() {
  let raw = run_cmd([], [], None, "ginger")
  assert string.contains(raw, "\"Services\":[{")
  assert string.contains(raw, "\"Provider\":\"nomad\"")
  assert string.contains(raw, "\"Path\":\"/up\"")
}

pub fn job_spec_services_absent_when_no_proxy_test() {
  let cfg = Config(..test_config(), proxy: None)
  let raw =
    nomad.run_job(cfg, web_role(), "abc123", [], [], 80, None, "ginger")
    |> command.to_string
    |> extract_json_body
  assert string.contains(raw, "\"Services\"") == False
}

pub fn job_spec_memory_max_absent_by_default_test() {
  // With memory_max: 0 the task is capped at its reservation — no MemoryMaxMB.
  let raw = run_cmd([], [], None, "ginger")
  assert string.contains(raw, "\"MemoryMB\":512")
  assert string.contains(raw, "MemoryMaxMB") == False
}

pub fn job_spec_memory_max_emitted_when_set_test() {
  // memory_max above the reservation opts into over-provisioning.
  let cfg = Config(..test_config(), resources: config.Resources(256, 512, 1024))
  let raw =
    nomad.run_job(cfg, web_role(), "abc123", [], [], 3000, None, "ginger")
    |> command.to_string
    |> extract_json_body
  assert string.contains(raw, "\"MemoryMB\":512")
  assert string.contains(raw, "\"MemoryMaxMB\":1024")
}

// ---------------------------------------------------------------------------
// parse_deployment_status unit tests

pub fn parse_deployment_status_successful_test() {
  let output =
    "ID          = abc123\nJob ID      = blog-web\nStatus      = successful\nDescription = deployed\n"
  assert nomad.parse_deployment_status(output) == "successful"
}

pub fn parse_deployment_status_running_test() {
  let output = "Status      = running\n"
  assert nomad.parse_deployment_status(output) == "running"
}

pub fn parse_deployment_status_failed_test() {
  let output = "Status           = failed\nDescription = timed out\n"
  assert nomad.parse_deployment_status(output) == "failed"
}

pub fn parse_deployment_status_empty_returns_pending_test() {
  assert nomad.parse_deployment_status("") == "pending"
}

pub fn parse_deployment_status_no_status_line_returns_pending_test() {
  let output = "ID = abc\nJob ID = blog-web\n"
  assert nomad.parse_deployment_status(output) == "pending"
}

// --- job-template mode (nomad.job_file) ------------------------------------

fn job_template_config() -> Config {
  let base = test_config()
  Config(
    ..base,
    nomad_job: Some(NomadJob(
      job_file: "/srv/xjdao/deploy/nomad/social-app.nomad.hcl",
      job_id: Some("social-app"),
      image_var: "image",
    )),
  )
}

pub fn run_job_file_passes_image_as_hcl_var_test() {
  let job =
    NomadJob(
      job_file: "/srv/app/web.nomad.hcl",
      job_id: None,
      image_var: "image",
    )
  let rendered =
    nomad.run_job_file(job, "reg.example.com/app:abc1234")
    |> command.to_string
  assert string.contains(rendered, "nomad job run")
  assert string.contains(rendered, "-var")
  assert string.contains(rendered, "image=reg.example.com/app:abc1234")
  assert string.contains(rendered, "/srv/app/web.nomad.hcl")
}

pub fn run_job_file_honours_custom_image_var_test() {
  let job =
    NomadJob(
      job_file: "/srv/app/web.nomad.hcl",
      job_id: None,
      image_var: "container_image",
    )
  let rendered =
    nomad.run_job_file(job, "reg.example.com/app:abc1234")
    |> command.to_string
  assert string.contains(
    rendered,
    "container_image=reg.example.com/app:abc1234",
  )
}

// The health gate polls by job ID. A hand-written spec is named whatever the
// operator wrote, not "<service>-<role>" — getting this wrong means ginger
// polls a job that does not exist and every deploy times out.
pub fn job_template_status_uses_custom_job_id_test() {
  let rendered =
    nomad.status_job(job_template_config(), "web") |> command.to_string
  assert string.contains(rendered, "social-app")
  assert !string.contains(rendered, "blog-web")
}

pub fn job_template_deployment_status_uses_custom_job_id_test() {
  let rendered =
    nomad.deployment_status(job_template_config(), "web") |> command.to_string
  assert string.contains(rendered, "social-app")
}

pub fn job_template_job_id_defaults_to_service_test() {
  let base = test_config()
  let config =
    Config(
      ..base,
      nomad_job: Some(NomadJob(
        job_file: "/srv/app/web.nomad.hcl",
        job_id: None,
        image_var: "image",
      )),
    )
  let rendered = nomad.status_job(config, "web") |> command.to_string
  assert string.contains(rendered, "blog")
  assert !string.contains(rendered, "blog-web")
}

// Without the nomad block nothing changes: generated specs keep the
// "<service>-<role>" convention.
pub fn generated_mode_job_id_unchanged_test() {
  let rendered = nomad.status_job(test_config(), "web") |> command.to_string
  assert string.contains(rendered, "blog-web")
}
