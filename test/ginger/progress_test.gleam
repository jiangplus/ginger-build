import ginger/config.{
  type Config, Builder, Config, Count, DockerRuntime, KamalProxyEgress, Registry,
  Role, Rolling, Secrets,
}
import ginger/progress.{Timing}
import gleam/option.{None}
import gleam/string

pub fn duration_sub_second_test() {
  assert progress.duration(0) == "0ms"
  assert progress.duration(820) == "820ms"
  assert progress.duration(999) == "999ms"
}

pub fn duration_seconds_test() {
  assert progress.duration(1000) == "1s"
  assert progress.duration(12_400) == "12s"
  assert progress.duration(59_999) == "59s"
}

/// The seconds part is zero-padded so a column of durations stays aligned —
/// "3m 05s" and "3m 42s" are the same width, "3m 5s" is not.
pub fn duration_minutes_test() {
  assert progress.duration(60_000) == "1m 00s"
  assert progress.duration(185_000) == "3m 05s"
  assert progress.duration(3_600_000) == "60m 00s"
}

pub fn step_labels_test() {
  assert progress.step_label(config.Build) == "build"
  assert progress.step_label(config.Lock(config.Acquire)) == "lock"
  assert progress.step_label(config.Lock(config.Release)) == "unlock"
  assert progress.step_label(config.BootApp(rolling: False, version: None))
    == "release"
}

/// A hook has only a command, so it is labelled by the program it runs.
pub fn step_label_hook_test() {
  let spec =
    config.HookSpec(run: "docker build -t x .", local: True, timeout: None)
  assert progress.step_label(config.Hook(spec)) == "hook:docker"
}

pub fn step_line_is_padded_test() {
  assert progress.step_line(Timing("build", 12_400))
    == "  ✓ build           12s"
}

/// The closing line is the total only — the per-step durations already printed
/// as each step finished, and repeating them at the end doubled the report
/// without adding a fact.
pub fn total_line_test() {
  let out = progress.total_line(93_400)
  assert string.contains(out, "total")
  assert string.contains(out, "1m 33s")
  assert !string.contains(out, "build")
}

/// Step lines and the total share a column so the durations line up.
pub fn total_line_aligns_with_step_lines_test() {
  let step = progress.step_line(Timing("build", 1000))
  let total = progress.total_line(1000)
  assert string.length(step) == string.length(total)
}

/// The banner names the config file, because omitting `-c` silently selects a
/// different one — and in a repo with ginger.yml plus ginger.cn.yml that is a
/// different production environment.
pub fn banner_names_config_and_target_test() {
  let out = progress.banner("deploy", test_config(), "ginger.cn.yml", "abc1234")
  assert string.contains(out, "deploy")
  assert string.contains(out, "soon")
  assert string.contains(out, "ginger.cn.yml")
  assert string.contains(out, "juluo.xyz")
  assert string.contains(out, "abc1234")
}

/// A config with no primary role must still render a banner rather than crash
/// the run before it starts.
pub fn banner_without_primary_host_test() {
  let cfg = Config(..test_config(), servers: [])
  let out = progress.banner("deploy", cfg, "ginger.yml", "abc1234")
  assert string.contains(out, "(no primary host)")
}

fn test_config() -> Config {
  Config(
    service: "soon",
    image: "registry.juluo.xyz/soon",
    servers: [Role(name: "web", hosts: ["juluo.xyz"], primary: True, cmd: None)],
    registry: Registry(
      server: "registry.juluo.xyz",
      username: "ci",
      password: "TOKEN",
    ),
    proxy: None,
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
    runtime: DockerRuntime,
    egress: KamalProxyEgress,
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
    local_image: False,
  )
}
