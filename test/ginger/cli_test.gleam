import ginger/cli.{ConfigDump, Flags, Help, RunPipeline, ShowVersion}
import gleam/option.{Some}

fn default_flags() -> cli.Flags {
  cli.default_flags()
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

// --- argument-parsing safety -----------------------------------------------
//
// Everything below guards one class of bug: a token the parser did not
// recognise used to fall through to the positional list, where only the first
// element is ever read. The flag AND its value disappeared silently, and the
// command ran anyway — with defaults, against the default config.

/// The one that shipped a real deploy. `--help` after a command parsed as the
/// positional list ["deploy", "--help"], which matches the deploy arm.
pub fn route_help_after_command_test() {
  assert cli.route(["deploy", "--help"]) == Help
  assert cli.route(["deploy", "-h"]) == Help
  assert cli.route(["rollback", "abc123", "--help"]) == Help
  assert cli.route(["logs", "-c", "x.yml", "--help"]) == Help
}

pub fn route_version_after_command_test() {
  assert cli.route(["deploy", "--version"]) == ShowVersion
}

/// A mistyped --config is the dangerous case: the flag and the path both
/// vanished, so this deployed to ./ginger.yml — a different environment than
/// the one the operator named.
pub fn route_unknown_flag_is_rejected_test() {
  assert cli.route(["deploy", "--conifg", "prod.yml"])
    == cli.BadUsage("unknown flag '--conifg' (try `ginger help`)")
  assert cli.route(["deploy", "--dry-run"])
    == cli.BadUsage("unknown flag '--dry-run' (try `ginger help`)")
  assert cli.route(["-x", "status"])
    == cli.BadUsage("unknown flag '-x' (try `ginger help`)")
}

/// A value-taking flag with nothing after it used to become a positional, so
/// `ginger deploy -c` ran the pipeline named "-c".
pub fn route_flag_missing_value_test() {
  assert cli.route(["deploy", "-c"]) == cli.BadUsage("-c needs a value")
  assert cli.route(["deploy", "--config"])
    == cli.BadUsage("--config needs a value")
  assert cli.route(["deploy", "--tag"]) == cli.BadUsage("--tag needs a value")
  assert cli.route(["logs", "--tail"]) == cli.BadUsage("--tail needs a value")
}

/// int.parse failures used to silently fall back to the default, so a typo in
/// --tail showed 100 lines while claiming to show what was asked for.
pub fn route_non_numeric_count_is_rejected_test() {
  assert cli.route(["logs", "--tail", "abc"])
    == cli.BadUsage("--tail needs a positive whole number, got 'abc'")
  assert cli.route(["deploy", "--build-concurrency", "0"])
    == cli.BadUsage(
      "--build-concurrency needs a positive whole number, got '0'",
    )
  assert cli.route(["deploy", "--build-concurrency", "-2"])
    == cli.BadUsage(
      "--build-concurrency needs a positive whole number, got '-2'",
    )
}

/// `--` ends flag parsing, so a pipeline or rollback target may start with a
/// dash without being read as a flag.
pub fn route_double_dash_ends_flags_test() {
  assert cli.route(["run", "--", "-weird-name"])
    == RunPipeline("-weird-name", default_flags())
  assert cli.route(["--", "deploy"]) == RunPipeline("deploy", default_flags())
}

/// Valid invocations must be untouched by the above.
pub fn route_valid_invocations_unchanged_test() {
  assert cli.route(["deploy", "-c", "ginger.cn.yml"])
    == RunPipeline(
      "deploy",
      Flags(..default_flags(), configs: ["ginger.cn.yml"]),
    )
  assert cli.route(["deploy", "-P", "--tag", "v1", "--build-concurrency", "4"])
    == RunPipeline(
      "deploy",
      Flags(
        ..default_flags(),
        skip_push: True,
        tag: Some("v1"),
        build_concurrency: 4,
      ),
    )
}
