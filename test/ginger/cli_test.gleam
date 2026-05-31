import ginger/cli.{ConfigDump, Help, RunPipeline, ShowVersion}
import gleam/option.{None, Some}

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
  assert cli.route(["deploy"])
    == RunPipeline("deploy", "ginger.yml", False, None)
}

pub fn route_deploy_skip_push_test() {
  assert cli.route(["deploy", "--skip-push"])
    == RunPipeline("deploy", "ginger.yml", True, None)
  assert cli.route(["deploy", "-P", "-c", "x.yml"])
    == RunPipeline("deploy", "x.yml", True, None)
}

pub fn route_rollback_test() {
  assert cli.route(["rollback", "abc1234"])
    == RunPipeline("rollback", "ginger.yml", False, Some("abc1234"))
}

pub fn route_run_named_pipeline_test() {
  assert cli.route(["run", "migrate", "-c", "x.yml"])
    == RunPipeline("migrate", "x.yml", False, None)
}

pub fn route_tag_flag_test() {
  assert cli.route(["deploy", "--tag", "v1"])
    == RunPipeline("deploy", "ginger.yml", False, Some("v1"))
  assert cli.route(["run", "verify", "-c", "x.yml", "-t", "abc123"])
    == RunPipeline("verify", "x.yml", False, Some("abc123"))
}

pub fn route_remove_test() {
  assert cli.route(["remove"])
    == RunPipeline("remove", "ginger.yml", True, None)
  assert cli.route(["remove", "-c", "x.yml"])
    == RunPipeline("remove", "x.yml", True, None)
}

pub fn route_custom_pipeline_test() {
  assert cli.route(["smoke-test"])
    == RunPipeline("smoke-test", "ginger.yml", False, None)
}
