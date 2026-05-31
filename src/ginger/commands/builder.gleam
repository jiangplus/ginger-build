import ginger/command.{type Command}
import ginger/config.{type Config}
import gleam/option.{None, Some}

/// Build and push the image. Local builds run `docker buildx build --push`
/// on the operator machine; when `builder.remote` is set, the same command is
/// prefixed with `DOCKER_HOST=ssh://...` so it executes on the remote Docker
/// host. Either way this command is intended to run locally (the SSH transport
/// for the remote case is handled by Docker itself).
pub fn build(config: Config, version: String) -> Command {
  let image = config.image <> ":" <> version
  let platform = "linux/" <> config.builder.arch
  let buildx = [
    "docker", "buildx", "build", "--push", "--platform", platform, "-t", image,
    ".",
  ]
  case config.builder.remote {
    Some(url) -> command.run(["DOCKER_HOST=" <> url, ..buildx])
    None -> command.run(buildx)
  }
}

/// Pull an already-pushed image to a host (used by `--skip-push` deploys).
pub fn pull(config: Config, version: String) -> Command {
  command.docker(["pull", config.image <> ":" <> version])
}
