import ginger/command.{type Command}
import ginger/commands/lock
import ginger/config.{type Config}
import gleam/int

/// Per-host deploy audit log. One line is appended on the primary host after
/// every successful boot-app, so `ginger history` (and a human with `cat`)
/// can answer "what versions ran here, and when" — the prerequisite for a
/// usable `rollback <version>`.
pub fn log_path(config: Config) -> String {
  lock.run_directory <> "/history-" <> config.service <> ".log"
}

/// Append an audit line: `<utc-timestamp> service=<s> version=<v> image=<ref>`.
/// The timestamp is stamped on the host (`date -u`) so entries are consistent
/// even when operators deploy from machines with skewed clocks.
pub fn append(config: Config, version: String) -> Command {
  let line =
    "$(date -u +%Y-%m-%dT%H:%M:%SZ) service="
    <> config.service
    <> " version="
    <> version
    <> " image="
    <> config.image
    <> ":"
    <> version
  command.raw(
    "mkdir -p "
    <> lock.run_directory
    <> " && echo \""
    <> line
    <> "\" >> "
    <> log_path(config),
  )
}

/// Show the most recent deploy history entries (newest last).
pub fn show(config: Config, lines: Int) -> Command {
  command.raw(
    "tail -"
    <> int.to_string(lines)
    <> " "
    <> log_path(config)
    <> " 2>/dev/null",
  )
}
