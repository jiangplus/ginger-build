import ginger/config.{type Config}
import ginger/error.{type GingerError, ConfigError}
import gleam/list
import gleam/option
import gleam/string

/// Run post-decode guards. Returns the config unchanged on success.
pub fn validate(config: Config) -> Result(Config, GingerError) {
  use _ <- result_try(check_service_name(config))
  use _ <- result_try(check_roles_present(config))
  use _ <- result_try(check_roles_have_hosts(config))
  use _ <- result_try(check_single_primary(config))
  use _ <- result_try(check_remote_builder_url(config))
  use _ <- result_try(check_retain_containers(config))
  Ok(config)
}

fn result_try(res: Result(a, e), next: fn(a) -> Result(b, e)) -> Result(b, e) {
  case res {
    Ok(v) -> next(v)
    Error(e) -> Error(e)
  }
}

fn check_service_name(config: Config) -> Result(Nil, GingerError) {
  let ok =
    config.service != ""
    && config.service
    |> string.to_graphemes
    |> list.all(is_service_char)
  case ok {
    True -> Ok(Nil)
    False ->
      Error(ConfigError(
        "service name '"
        <> config.service
        <> "' may only contain letters, digits, hyphens, and underscores",
      ))
  }
}

fn is_service_char(c: String) -> Bool {
  case c {
    "-" | "_" -> True
    _ -> is_alnum(c)
  }
}

fn is_alnum(c: String) -> Bool {
  string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
    c,
  )
}

fn check_roles_present(config: Config) -> Result(Nil, GingerError) {
  case config.servers {
    [] -> Error(ConfigError("no roles defined under 'servers'"))
    _ -> Ok(Nil)
  }
}

fn check_roles_have_hosts(config: Config) -> Result(Nil, GingerError) {
  case list.find(config.servers, fn(r) { r.hosts == [] }) {
    Ok(role) -> Error(ConfigError("role '" <> role.name <> "' has no hosts"))
    Error(_) -> Ok(Nil)
  }
}

fn check_single_primary(config: Config) -> Result(Nil, GingerError) {
  let primaries = list.filter(config.servers, fn(r) { r.primary })
  case list.length(primaries) > 1 {
    True ->
      Error(ConfigError(
        "more than one role is marked primary; mark exactly one",
      ))
    False -> Ok(Nil)
  }
}

fn check_remote_builder_url(config: Config) -> Result(Nil, GingerError) {
  case config.builder.remote {
    option.None -> Ok(Nil)
    option.Some(url) ->
      case string.starts_with(url, "ssh://") {
        True -> Ok(Nil)
        False ->
          Error(ConfigError(
            "builder.remote must be an ssh:// URL, got: " <> url,
          ))
      }
  }
}

fn check_retain_containers(config: Config) -> Result(Nil, GingerError) {
  case config.retain_containers >= 1 {
    True -> Ok(Nil)
    False -> Error(ConfigError("retain_containers must be at least 1"))
  }
}
