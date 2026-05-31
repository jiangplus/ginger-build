import gleam/list
import gleam/string

/// A structured shell command. Builders construct `Command` values purely —
/// nothing is executed here. The executor renders a `Command` to a string with
/// `to_string` and runs it (locally or over SSH). This separation mirrors
/// Kamal's `Commands` layer and keeps every builder unit-testable.
pub opaque type Command {
  /// A single command as an ordered list of argv tokens.
  Run(List(String))
  /// Several commands joined by a shell operator (`&&`, `;`, `|`, `||`).
  Compose(List(Command), separator: String)
}

/// Build a command from raw tokens, e.g. `run(["mkdir", "-p", "/tmp/x"])`.
pub fn run(tokens: List(String)) -> Command {
  Run(tokens)
}

/// Wrap an already-formed shell string as a command (e.g. an inline hook).
/// It is rendered verbatim with no further quoting or splitting.
pub fn raw(shell: String) -> Command {
  Run([shell])
}

/// Build a `docker ...` command: `docker([:run, ...])`.
pub fn docker(args: List(String)) -> Command {
  Run(["docker", ..args])
}

/// Join commands with an arbitrary shell separator.
pub fn combine(commands: List(Command), by separator: String) -> Command {
  Compose(commands, separator)
}

/// Join with `&&` — run the next only if the previous succeeded.
pub fn and(commands: List(Command)) -> Command {
  Compose(commands, "&&")
}

/// Join with `;` — run sequentially regardless of exit status.
pub fn chain(commands: List(Command)) -> Command {
  Compose(commands, ";")
}

/// Join with `|` — pipe stdout into the next command.
pub fn pipe(commands: List(Command)) -> Command {
  Compose(commands, "|")
}

/// Join with `||` — run the next only if the previous failed.
pub fn or(commands: List(Command)) -> Command {
  Compose(commands, "||")
}

/// Render a command to a shell string. Empty tokens are dropped so optional
/// flags can be added as `""` and disappear.
pub fn to_string(command: Command) -> String {
  case command {
    Run(tokens) ->
      tokens
      |> list.filter(fn(token) { token != "" })
      |> string.join(" ")
    Compose(commands, separator) ->
      commands
      |> list.map(to_string)
      |> string.join(" " <> separator <> " ")
  }
}

/// Single-quote a value for safe shell interpolation, escaping embedded
/// single quotes via the `'\''` idiom. Use for any value that may contain
/// spaces or special characters (env values, labels, paths).
pub fn quote(value: String) -> String {
  "'" <> string.replace(value, "'", "'\\''") <> "'"
}

/// Produce `["--flag", "key=quoted-value"]` token pairs for the given map.
/// Used for `--env`, `--label`, etc.
pub fn flag_pairs(
  flag: String,
  pairs: List(#(String, String)),
) -> List(String) {
  pairs
  |> list.flat_map(fn(pair) {
    let #(key, value) = pair
    [flag, key <> "=" <> quote(value)]
  })
}
