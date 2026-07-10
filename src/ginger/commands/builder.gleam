import ginger/command.{type Command}
import ginger/config.{type Config}
import gleam/list
import gleam/option.{None, Some}
import gleam/string

/// The image reference builds are pushed to. When `builder.push_registry` is set,
/// the host segment of `image` is swapped for it while the repository path is
/// preserved — so a runtime registry sharing the same backend (object store +
/// metadata DB) can pull the very same repo:tag. Otherwise it's just `image`.
pub fn push_image(config: Config) -> String {
  case config.builder.push_registry {
    Some(host) -> host <> "/" <> repo_path(config.image)
    None -> config.image
  }
}

fn repo_path(image: String) -> String {
  case string.split_once(image, "/") {
    Ok(#(_host, rest)) -> rest
    Error(_) -> image
  }
}

/// Build and push the image. Local builds run `docker buildx build --push`
/// on the operator machine; when `builder.remote` is set, the same command is
/// prefixed with `DOCKER_HOST=ssh://...` so it executes on the remote Docker
/// host. Either way this command is intended to run locally (the SSH transport
/// for the remote case is handled by Docker itself).
pub fn build(config: Config, version: String) -> Command {
  let push_ref = push_image(config)
  let image = push_ref <> ":" <> version
  let platform = "linux/" <> config.builder.arch
  // Cache layers are stored as a separate tag in the same registry so they
  // survive builder restarts. --cache-from is a no-op on a cold cache.
  // mode=min (default) exports only final-stage layers — mode=max exports
  // every intermediate layer and its export time can rival the build itself.
  let cache_ref = push_ref <> ":buildcache"
  let cache_flags = case config.builder.cache {
    config.CacheNone -> []
    config.CacheMin -> [
      "--cache-from",
      "type=registry,ref=" <> cache_ref,
      "--cache-to",
      "type=registry,mode=min,ref=" <> cache_ref,
    ]
    config.CacheMax -> [
      "--cache-from",
      "type=registry,ref=" <> cache_ref,
      "--cache-to",
      "type=registry,mode=max,ref=" <> cache_ref,
    ]
  }
  // Extra tags (e.g. "latest") pushed alongside the version tag, so pinned
  // runtime specs and versioned rollback history coexist.
  let tag_flags =
    config.builder.tags
    |> list.filter(fn(tag) { tag != version })
    |> list.flat_map(fn(tag) { ["-t", push_ref <> ":" <> tag] })
  // Dockerfile override for monorepos, declared relative to the context.
  // docker resolves -f against the CLI's cwd (not the context), so join the
  // two here.
  let dockerfile_flags = case config.builder.dockerfile {
    Some(path) -> {
      let resolved = case
        string.starts_with(path, "/"),
        config.builder.context
      {
        True, _ -> path
        False, "." -> path
        False, context -> context <> "/" <> path
      }
      ["-f", resolved]
    }
    None -> []
  }
  // Extra --build-arg flags (e.g. proxy settings so RUN steps reach the net).
  let build_arg_flags =
    config.builder.build_args
    |> list.flat_map(fn(p) { ["--build-arg", p.0 <> "=" <> p.1] })
  // Attestations off by default: they add export time and extra manifests
  // that simple registries may not expect.
  let provenance_flags = case config.builder.provenance {
    True -> []
    False -> ["--provenance=false", "--sbom=false"]
  }
  let buildx =
    list.flatten([
      ["docker", "buildx", "build", "--push", "--platform", platform],
      provenance_flags,
      ["-t", image],
      tag_flags,
      dockerfile_flags,
      cache_flags,
      build_arg_flags,
      [config.builder.context],
    ])
  case config.builder.remote {
    Some(url) -> command.run(["DOCKER_HOST=" <> url, ..buildx])
    None -> command.run(buildx)
  }
}

/// Pull an already-pushed image to a host (used by `--skip-push` deploys).
pub fn pull(config: Config, version: String) -> Command {
  command.docker(["pull", config.image <> ":" <> version])
}
