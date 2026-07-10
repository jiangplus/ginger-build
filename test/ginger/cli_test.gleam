import ginger/cli.{ConfigDump, Flags, Help, RunPipeline, ShowVersion}
import gleam/option.{None, Some}

fn default_flags() -> cli.Flags {
  Flags(
    configs: [],
    tag: None,
    skip_push: False,
    build_concurrency: 2,
    follow: False,
    tail: 100,
  )
}

pub fn route_help_test() {
  assert cli.route([]) == Help
  assert cli.route(["help"]) == Help
  assert cli.route(["--help"]) == Help
  assert cli.route(["-h"]) == Help
}

pub fn route_version_test() {
  assert cli.route(["version"]) == ShowVersion
  assert cli.route(["--version"]) == ShowVersion
}

pub fn route_config_default_path_test() {
  assert cli.route(["config"]) == ConfigDump("ginger.yml")
}

pub fn route_config_custom_path_test() {
  assert cli.route(["config", "-c", "prod.yml"]) == ConfigDump("prod.yml")
  assert cli.route(["config", "--config", "prod.yml"]) == ConfigDump("prod.yml")
}

pub fn route_deploy_test() {
  assert cli.route(["deploy"]) == RunPipeline("deploy", default_flags())
}

pub fn route_deploy_skip_push_test() {
  assert cli.route(["deploy", "--skip-push"])
    == RunPipeline("deploy", Flags(..default_flags(), skip_push: True))
  assert cli.route(["deploy", "-P", "-c", "x.yml"])
    == RunPipeline(
      "deploy",
      Flags(..default_flags(), skip_push: True, configs: ["x.yml"]),
    )
}

/// Flags may appear BEFORE the command too — 0.5.0 silently ignored them
/// there and fell back to ./ginger.yml.
pub fn route_flags_before_command_test() {
  assert cli.route(["-c", "x.yml", "deploy"])
    == RunPipeline("deploy", Flags(..default_flags(), configs: ["x.yml"]))
  assert cli.route(["--config", "x.yml", "status"]) == cli.StatusCmd("x.yml")
  assert cli.route(["-t", "v9", "deploy"])
    == RunPipeline("deploy", Flags(..default_flags(), tag: Some("v9")))
}

/// Repeated -c collects configs for a multi-service (group) deploy.
pub fn route_multi_config_test() {
  assert cli.route(["deploy", "-c", "a.yml", "-c", "b.yml"])
    == RunPipeline(
      "deploy",
      Flags(..default_flags(), configs: ["a.yml", "b.yml"]),
    )
  assert cli.route([
      "deploy",
      "-c",
      "a.yml",
      "-c",
      "b.yml",
      "--build-concurrency",
      "3",
    ])
    == RunPipeline(
      "deploy",
      Flags(
        ..default_flags(),
        configs: ["a.yml", "b.yml"],
        build_concurrency: 3,
      ),
    )
}

pub fn route_rollback_test() {
  assert cli.route(["rollback", "abc1234"])
    == RunPipeline("rollback", Flags(..default_flags(), tag: Some("abc1234")))
  assert cli.route(["rollback"])
    == cli.BadUsage("rollback requires a version argument")
}

pub fn route_run_named_pipeline_test() {
  assert cli.route(["run", "migrate", "-c", "x.yml"])
    == RunPipeline("migrate", Flags(..default_flags(), configs: ["x.yml"]))
}

pub fn route_tag_flag_test() {
  assert cli.route(["deploy", "--tag", "v1"])
    == RunPipeline("deploy", Flags(..default_flags(), tag: Some("v1")))
  assert cli.route(["run", "verify", "-c", "x.yml", "-t", "abc123"])
    == RunPipeline(
      "verify",
      Flags(..default_flags(), configs: ["x.yml"], tag: Some("abc123")),
    )
}

pub fn route_remove_test() {
  assert cli.route(["remove"])
    == RunPipeline("remove", Flags(..default_flags(), skip_push: True))
  assert cli.route(["remove", "-c", "x.yml"])
    == RunPipeline(
      "remove",
      Flags(..default_flags(), skip_push: True, configs: ["x.yml"]),
    )
}

pub fn route_lock_test() {
  assert cli.route(["lock", "release"]) == cli.LockCmd("release", "ginger.yml")
  assert cli.route(["lock", "status", "-c", "x.yml"])
    == cli.LockCmd("status", "x.yml")
  assert cli.route(["lock", "acquire"]) == cli.LockCmd("acquire", "ginger.yml")
}

pub fn route_status_test() {
  assert cli.route(["status"]) == cli.StatusCmd("ginger.yml")
  assert cli.route(["status", "-c", "x.yml"]) == cli.StatusCmd("x.yml")
}

pub fn route_logs_test() {
  assert cli.route(["logs"]) == cli.LogsCmd("ginger.yml", False, 100)
  assert cli.route(["logs", "-f", "-c", "x.yml"])
    == cli.LogsCmd("x.yml", True, 100)
  assert cli.route(["logs", "--tail", "20"])
    == cli.LogsCmd("ginger.yml", False, 20)
}

pub fn route_history_test() {
  assert cli.route(["history"]) == cli.HistoryCmd("ginger.yml", 100)
  assert cli.route(["history", "--tail", "5", "-c", "x.yml"])
    == cli.HistoryCmd("x.yml", 5)
}

pub fn route_custom_pipeline_test() {
  assert cli.route(["smoke-test"]) == RunPipeline("smoke-test", default_flags())
}
