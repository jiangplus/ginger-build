import ginger/config.{
  Acquire, BootApp, BootProxy, Build, Count, Hook, HookSpec, Lock, Percent,
  Prune, Push, Release,
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
      Hook(HookSpec(run: "./bin/check", local: True)),
      BootApp(rolling: True, version: None),
      Prune,
      Lock(Release),
      Hook(HookSpec(run: "echo done", local: False)),
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
