import ginger/config.{type Secrets}
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// Read environment access and local files via FFI.
@external(erlang, "env_ffi", "get_env")
fn ffi_get_env() -> List(#(String, String))

@external(erlang, "env_ffi", "read_file")
fn ffi_read_file(path: String) -> Result(String, String)

/// Build the merged secret map: process environment first, then each dotenv
/// file in `load` order. Later sources override earlier (a `.env` value wins
/// over the same key in the process environment).
pub fn load(spec: Secrets) -> Dict(String, String) {
  let base = dict.from_list(ffi_get_env())
  list.fold(spec.load, base, fn(acc, path) {
    case ffi_read_file(path) {
      Ok(content) -> merge(acc, parse_dotenv(content))
      Error(_) -> acc
    }
  })
}

/// Merge override pairs into a base map.
pub fn merge(
  base: Dict(String, String),
  overrides: List(#(String, String)),
) -> Dict(String, String) {
  list.fold(overrides, base, fn(acc, pair) { dict.insert(acc, pair.0, pair.1) })
}

/// Resolve a single secret by exact name (e.g. registry password).
pub fn resolve(secrets: Dict(String, String), name: String) -> Option(String) {
  case dict.get(secrets, name) {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
}

/// Validate that every exact (non-glob) name in `patterns` is present in the
/// secret map. Returns a list of missing keys so the caller can fail early with
/// a descriptive message before starting the deploy.
pub fn missing_keys(
  secrets: Dict(String, String),
  patterns: List(String),
) -> List(String) {
  patterns
  |> list.filter(fn(p) { !string.contains(p, "*") })
  |> list.filter(fn(key) {
    case dict.get(secrets, key) {
      Ok(v) -> string.trim(v) == ""
      Error(_) -> True
    }
  })
}

/// Select the secrets to inject into containers: every key matching one of the
/// `inject` patterns (exact name or glob with `*`). Returned sorted by key for
/// deterministic command output.
pub fn injected(
  secrets: Dict(String, String),
  patterns: List(String),
) -> List(#(String, String)) {
  secrets
  |> dict.to_list
  |> list.filter(fn(pair) {
    list.any(patterns, fn(pattern) { match(pattern, pair.0) })
  })
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
}

/// Glob match supporting `*` (matches any run of characters).
pub fn match(pattern: String, text: String) -> Bool {
  do_match(string.to_graphemes(pattern), string.to_graphemes(text))
}

fn do_match(pattern: List(String), text: List(String)) -> Bool {
  case pattern, text {
    [], [] -> True
    [], _ -> False
    ["*", ..ps], [] -> do_match(ps, [])
    ["*", ..ps], [_, ..ts] -> do_match(ps, text) || do_match(pattern, ts)
    [_, ..], [] -> False
    [ph, ..ps], [th, ..ts] ->
      case ph == th {
        True -> do_match(ps, ts)
        False -> False
      }
  }
}

/// Parse dotenv file content into key/value pairs. Handles blank lines,
/// `#` comments, an optional `export ` prefix, and single/double quoting.
pub fn parse_dotenv(content: String) -> List(#(String, String)) {
  content
  |> string.split("\n")
  |> list.filter_map(parse_line)
}

fn parse_line(line: String) -> Result(#(String, String), Nil) {
  let trimmed = string.trim(line)
  case trimmed == "" || string.starts_with(trimmed, "#") {
    True -> Error(Nil)
    False -> {
      let without_export = case string.starts_with(trimmed, "export ") {
        True -> string.drop_start(trimmed, 7)
        False -> trimmed
      }
      case string.split_once(without_export, "=") {
        Ok(#(key, value)) ->
          Ok(#(string.trim(key), unquote(string.trim(value))))
        Error(_) -> Error(Nil)
      }
    }
  }
}

fn unquote(value: String) -> String {
  case value {
    "\"" <> rest -> strip_suffix(rest, "\"")
    "'" <> rest -> strip_suffix(rest, "'")
    _ -> value
  }
}

fn strip_suffix(value: String, suffix: String) -> String {
  case string.ends_with(value, suffix) {
    True -> string.drop_end(value, string.length(suffix))
    False -> value
  }
}
