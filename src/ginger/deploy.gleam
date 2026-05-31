import ginger/config.{
  type Config, type Pipeline, type Step, Acquire, BootApp, BootProxy, Build,
  Lock, Pipeline, Prune, Push, Release, RemoveApp,
}
import ginger/error.{type GingerError, ConfigError}
import gleam/list
import gleam/option.{None}

/// Resolve the pipeline to run for a command name. A pipeline declared in the
/// config wins; otherwise a built-in default is used for the well-known
/// commands (deploy/redeploy/rollback). Unknown names error.
pub fn select_pipeline(
  config: Config,
  name: String,
) -> Result(Pipeline, GingerError) {
  case list.find(config.pipelines, fn(p) { p.name == name }) {
    Ok(pipeline) -> Ok(pipeline)
    Error(_) ->
      case default_steps(name) {
        Ok(steps) -> Ok(Pipeline(name: name, steps: steps))
        Error(_) ->
          Error(ConfigError(
            "no pipeline named '"
            <> name
            <> "' in config, and no built-in default exists",
          ))
      }
  }
}

/// Built-in default step sequences, mirroring Kamal's hardcoded flows. Used
/// when the user hasn't declared a pipeline of this name.
pub fn default_steps(name: String) -> Result(List(Step), Nil) {
  case name {
    "deploy" ->
      Ok([
        Build,
        Push,
        Lock(Acquire),
        BootProxy,
        BootApp(rolling: True, version: None),
        Prune,
        Lock(Release),
      ])
    "redeploy" ->
      Ok([
        Build,
        Lock(Acquire),
        BootApp(rolling: True, version: None),
        Lock(Release),
      ])
    "rollback" -> Ok([BootApp(rolling: True, version: None)])
    "remove" -> Ok([RemoveApp])
    _ -> Error(Nil)
  }
}

/// Drop `Build`/`Push` steps for `--skip-push` deploys (the image is assumed to
/// already be in the registry; `docker run` pulls it on boot).
pub fn without_build(pipeline: Pipeline) -> Pipeline {
  let steps =
    list.filter(pipeline.steps, fn(step) {
      case step {
        Build -> False
        Push -> False
        _ -> True
      }
    })
  Pipeline(..pipeline, steps: steps)
}
