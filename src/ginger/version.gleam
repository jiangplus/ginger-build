import ginger/error.{type GingerError, ConfigError}
import gleam/option.{type Option, None, Some}
import gleam/string

@external(erlang, "env_ffi", "git_sha")
fn ffi_git_sha() -> Result(String, String)

/// Resolve the deploy version. An explicit override (e.g. a rollback target)
/// wins; otherwise the abbreviated git HEAD sha is used.
pub fn resolve(override: Option(String)) -> Result(String, GingerError) {
  case override {
    Some(version) -> Ok(version)
    None ->
      case ffi_git_sha() {
        Ok(sha) -> Ok(abbreviate(string.trim(sha)))
        Error(reason) ->
          Error(ConfigError("could not determine version from git: " <> reason))
      }
  }
}

fn abbreviate(sha: String) -> String {
  string.slice(sha, 0, 7)
}
