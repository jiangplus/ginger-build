import ginger/config.{
  Acquire, BootApp, BootProxy, Build, Count, DockerRuntime, Hook, HookSpec,
  KamalProxyEgress, Lock, NomadRuntime, Percent, Prune, Push, Release,
  TraefikEgress,
}
import ginger/config/decode
import ginger/config/validate
import gleam/option.{None, Some}

const minimal = "
service: blog
image: ghcr.io/acme/blog
servers:
  web:
    hosts: [10.0.0.1, 10.0.0.2]
    primary: true
registry:
  server: ghcr.io
"

pub fn decode_minimal_test() {
  let assert Ok(cfg) = decode.from_string(minimal)
  assert cfg.service == "blog"
  assert cfg.image == "ghcr.io/acme/blog"
  assert cfg.retain_containers == 5
  // default: nomad + traefik
  assert cfg.runtime == NomadRuntime
  assert cfg.egress == TraefikEgress
}

pub fn decode_docker_runner_test() {
  let yaml = minimal <> "\nrunner: docker\negress: kamal-proxy\n"
  let assert Ok(cfg) = decode.from_string(yaml)
  assert cfg.runtime == DockerRuntime
  assert cfg.egress == KamalProxyEgress
}

pub fn decode_invalid_runner_combo_test() {
  let yaml = minimal <> "\nrunner: nomad\negress: kamal-proxy\n"
  let assert Error(_) = decode.from_string(yaml)
}

pub fn decode_unknown_runner_test() {
  let yaml = minimal <> "\nrunner: kubernetes\n"
  let assert Error(_) = decode.from_string(yaml)
}

pub fn decode_roles_test() {
  let assert Ok(cfg) = decode.from_string(minimal)
  let assert [web] = cfg.servers
  assert web.name == "web"
  assert web.hosts == ["10.0.0.1", "10.0.0.2"]
  assert web.primary == True
  assert web.cmd == None
}

pub fn decode_registry_test() {
  let assert Ok(cfg) = decode.from_string(minimal)
  assert cfg.registry.server == "ghcr.io"
}

pub fn missing_required_key_test() {
  let assert Error(_) =
    decode.from_string(
      "image: x\nservers:\n  web:\n    hosts: [a]\nregistry:\n  server: r\n",
    )
}

const with_proxy = "
service: blog
image: img
servers:
  web:
    hosts: [10.0.0.1]
registry:
  server: ghcr.io
proxy:
  host: blog.example.com
  app_port: 3000
  ssl: true
"

pub fn decode_proxy_test() {
  let assert Ok(cfg) = decode.from_string(with_proxy)
  let assert Some(proxy) = cfg.proxy
  assert proxy.hosts == ["blog.example.com"]
  assert proxy.app_port == 3000
  assert proxy.ssl == True
  assert proxy.health_check_path == "/up"
}

const with_proxy_hosts = "
service: blog
image: img
servers:
  web:
    hosts: [10.0.0.1]
registry:
  server: ghcr.io
proxy:
  hosts: [blog.example.com, www.example.com]
  app_port: 3000
"

pub fn decode_proxy_hosts_list_test() {
  let assert Ok(cfg) = decode.from_string(with_proxy_hosts)
  let assert Some(proxy) = cfg.proxy
  assert proxy.hosts == ["blog.example.com", "www.example.com"]
}

const with_rolling = "
service: blog
image: img
servers:
  web:
    hosts: [a, b, c, d]
registry:
  server: r
rolling:
  limit: 25%
  wait: 5
"

pub fn decode_rolling_percent_test() {
  let assert Ok(cfg) = decode.from_string(with_rolling)
  assert cfg.rolling.limit == Percent(25)
  assert cfg.rolling.wait == 5
}

const with_count = "
service: blog
image: img
servers:
  web:
    hosts: [a]
registry:
  server: r
rolling:
  limit: 2
"

pub fn decode_rolling_count_test() {
  let assert Ok(cfg) = decode.from_string(with_count)
  assert cfg.rolling.limit == Count(2)
}

const with_secrets = "
service: blog
image: img
servers:
  web:
    hosts: [a]
registry:
  server: r
secrets:
  load: [.env, .env.production]
  inject:
    - RAILS_MASTER_KEY
    - STRIPE_*
"

pub fn decode_secrets_test() {
  let assert Ok(cfg) = decode.from_string(with_secrets)
  assert cfg.secrets.load == [".env", ".env.production"]
  assert cfg.secrets.inject == ["RAILS_MASTER_KEY", "STRIPE_*"]
}

const with_pipeline = "
service: blog
image: img
servers:
  web:
    hosts: [a]
registry:
  server: r
pipelines:
  deploy:
    - build
    - push
    - lock: acquire
    - boot-proxy
    - hook: ./bin/check
    - boot-app: { rolling: true }
    - prune
    - lock: release
    - hook: { run: 'echo done', local: false }
"

pub fn decode_pipeline_steps_test() {
  let assert Ok(cfg) = decode.from_string(with_pipeline)
  let assert [pipeline] = cfg.pipelines
  assert pipeline.name == "deploy"
  assert pipeline.steps
    == [
      Build,
      Push,
      Lock(Acquire),
      BootProxy,
      Hook(HookSpec(run: "./bin/check", local: True, timeout: None)),
      BootApp(rolling: True, version: None),
      Prune,
      Lock(Release),
      Hook(HookSpec(run: "echo done", local: False, timeout: None)),
    ]
}

pub fn unknown_step_errors_test() {
  let bad =
    "
service: blog
image: img
servers:
  web:
    hosts: [a]
registry:
  server: r
pipelines:
  deploy:
    - frobnicate
"
  let assert Error(_) = decode.from_string(bad)
}

pub fn validate_rejects_bad_service_name_test() {
  let assert Ok(cfg) = decode.from_string(minimal)
  let bad = config.Config(..cfg, service: "bad name!")
  let assert Error(_) = validate.validate(bad)
}

pub fn validate_accepts_good_config_test() {
  let assert Ok(cfg) = decode.from_string(minimal)
  let assert Ok(_) = validate.validate(cfg)
}

// --- 0.6.0 additions ---------------------------------------------------------

pub fn decode_container_passthroughs_test() {
  let yaml =
    "
service: blog
image: ghcr.io/acme/blog
servers:
  web:
    hosts: [10.0.0.1]
registry:
  server: ghcr.io
volumes:
  - /opt/data:/data
extra_hosts:
  - plc.internal:127.0.0.1
labels:
  team: platform
resources:
  cpu: 50
  memory: 400
  memory_max: 800
ssh:
  user: ubuntu
  command_timeout: 1800
deps:
  - ../plc.yml
"
  let assert Ok(cfg) = decode.from_string(yaml)
  assert cfg.volumes == ["/opt/data:/data"]
  assert cfg.extra_hosts == ["plc.internal:127.0.0.1"]
  assert cfg.labels == [#("team", "platform")]
  assert cfg.resources
    == config.Resources(cpu: 50, memory: 400, memory_max: 800)
  assert cfg.ssh_timeout == 1800
  assert cfg.deps == ["../plc.yml"]
}

pub fn decode_builder_extensions_test() {
  let yaml =
    "
service: blog
image: ghcr.io/acme/blog
servers:
  web:
    hosts: [10.0.0.1]
registry:
  server: ghcr.io
builder:
  context: ../repo
  dockerfile: cmd/relay/Dockerfile
  tags: [latest]
  cache: none
"
  let assert Ok(cfg) = decode.from_string(yaml)
  assert cfg.builder.context == "../repo"
  assert cfg.builder.dockerfile == Some("cmd/relay/Dockerfile")
  assert cfg.builder.tags == ["latest"]
  assert cfg.builder.cache == config.CacheNone
}

pub fn decode_defaults_are_backward_compatible_test() {
  // a minimal 0.5.0-era config must decode with the new fields defaulted
  let yaml =
    "
service: blog
image: ghcr.io/acme/blog
servers:
  web:
    hosts: [10.0.0.1]
registry:
  server: ghcr.io
"
  let assert Ok(cfg) = decode.from_string(yaml)
  assert cfg.volumes == []
  assert cfg.extra_hosts == []
  assert cfg.labels == []
  assert cfg.resources == config.Resources(cpu: 256, memory: 512, memory_max: 0)
  assert cfg.ssh_timeout == 600
  assert cfg.deps == []
  assert cfg.builder.context == "."
  assert cfg.builder.dockerfile == None
  assert cfg.builder.tags == []
  assert cfg.builder.cache == config.CacheMin
}

pub fn decode_hook_timeout_test() {
  let yaml =
    "
service: blog
image: ghcr.io/acme/blog
servers:
  web:
    hosts: [10.0.0.1]
registry:
  server: ghcr.io
pipelines:
  deploy:
    - hook: { run: 'sleep 1', local: false, timeout: 1800 }
"
  let assert Ok(cfg) = decode.from_string(yaml)
  let assert [config.Pipeline(name: "deploy", steps: [step])] = cfg.pipelines
  assert step
    == Hook(HookSpec(run: "sleep 1", local: False, timeout: Some(1800)))
}

// --- nomad job-template mode ------------------------------------------------

pub fn nomad_job_file_decoded_test() {
  let yaml =
    "service: social-app
image: registry.juluo.xyz/xjdao/social-app
runner: nomad
egress: traefik
servers:
  web:
    hosts: [121.41.70.29]
    primary: true
registry:
  server: registry.juluo.xyz
  username: username
  password: YATCH_TOKEN
nomad:
  job_file: /srv/xjdao/deploy/nomad/social-app.nomad.hcl
  job_id: social-app
  image_var: container_image
"
  let assert Ok(config) = decode.from_string(yaml)
  let assert Some(job) = config.nomad_job
  assert job.job_file == "/srv/xjdao/deploy/nomad/social-app.nomad.hcl"
  assert job.job_id == Some("social-app")
  assert job.image_var == "container_image"
}

pub fn nomad_job_image_var_defaults_to_image_test() {
  let yaml =
    "service: social-app
image: registry.juluo.xyz/xjdao/social-app
runner: nomad
egress: traefik
servers:
  web:
    hosts: [121.41.70.29]
    primary: true
registry:
  server: registry.juluo.xyz
  username: username
  password: YATCH_TOKEN
nomad:
  job_file: /srv/xjdao/deploy/nomad/social-app.nomad.hcl
"
  let assert Ok(config) = decode.from_string(yaml)
  let assert Some(job) = config.nomad_job
  assert job.image_var == "image"
  assert job.job_id == None
}

pub fn nomad_job_absent_by_default_test() {
  let yaml =
    "service: blog
image: ghcr.io/acme/blog
servers:
  web:
    hosts: [10.0.0.1]
    primary: true
registry:
  server: ghcr.io
  username: ci
  password: TOKEN
"
  let assert Ok(config) = decode.from_string(yaml)
  assert config.nomad_job == None
}

pub fn nomad_block_without_job_file_is_an_error_test() {
  let yaml =
    "service: blog
image: ghcr.io/acme/blog
servers:
  web:
    hosts: [10.0.0.1]
    primary: true
registry:
  server: ghcr.io
  username: ci
  password: TOKEN
nomad:
  job_id: blog
"
  assert case decode.from_string(yaml) {
    Error(_) -> True
    Ok(_) -> False
  }
}

pub fn deploy_only_decoded_test() {
  let yaml =
    "service: pds
image: registry.juluo.xyz/xjdao/pds
runner: nomad
egress: traefik
deploy_only: true
servers:
  web:
    hosts: [121.41.70.29]
    primary: true
registry:
  server: registry.juluo.xyz
  username: username
  password: YATCH_TOKEN
"
  let assert Ok(config) = decode.from_string(yaml)
  assert config.deploy_only == True
}

/// `-t` is a single global flag, so a multi-config deploy mixing built and
/// deploy-only services cannot express per-service versions. `tag:` gives the
/// deploy-only ones a version of their own without pinning the built ones.
pub fn tag_is_decoded_test() {
  let yaml =
    "service: plc
image: plc
runner: nomad
egress: traefik
deploy_only: true
tag: latest
servers:
  web:
    hosts: [10.0.0.1]
    primary: true
registry:
  server: reg.example.com
  username: u
  password: P
"
  let assert Ok(config) = decode.from_string(yaml)
  assert config.tag == Some("latest")
}

pub fn tag_defaults_to_none_test() {
  let assert Ok(config) = decode.from_string(minimal)
  assert config.tag == None
}

pub fn deploy_only_defaults_false_test() {
  let assert Ok(config) = decode.from_string(minimal)
  assert config.deploy_only == False
}

/// `local_image` means the image only ever exists in the target host's Docker
/// daemon, so requiring registry credentials would force placeholder values.
pub fn local_image_makes_registry_optional_test() {
  let yaml =
    "service: yatch
image: yatch
runner: nomad
egress: traefik
local_image: true
servers:
  web:
    hosts: [10.0.0.1]
    primary: true
"
  let assert Ok(config) = decode.from_string(yaml)
  assert config.local_image == True
  assert config.registry.server == ""
  assert config.registry.password == ""
}

/// An explicit `registry:` block is still honoured alongside `local_image` —
/// useful when a service is bootstrapping now but will pull normally later.
pub fn local_image_keeps_explicit_registry_test() {
  let yaml =
    "service: yatch
image: yatch
local_image: true
servers:
  web:
    hosts: [10.0.0.1]
    primary: true
registry:
  server: home-registry.sola.day
  username: sola
  password: YATCH_TOKEN
"
  let assert Ok(config) = decode.from_string(yaml)
  assert config.local_image == True
  assert config.registry.server == "home-registry.sola.day"
}

pub fn local_image_defaults_false_test() {
  let assert Ok(config) = decode.from_string(minimal)
  assert config.local_image == False
}

/// Without `local_image`, a missing `registry:` is still an error — the flag is
/// the only thing that relaxes it.
pub fn registry_still_required_without_local_image_test() {
  let yaml =
    "service: yatch
image: yatch
servers:
  web:
    hosts: [10.0.0.1]
    primary: true
"
  assert case decode.from_string(yaml) {
    Error(_) -> True
    Ok(_) -> False
  }
}
