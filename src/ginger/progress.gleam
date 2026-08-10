import ginger/config.{type Config, type Step}
import gleam/int
import gleam/list
import gleam/string

/// Milliseconds from an arbitrary origin. Monotonic, so a clock correction
/// during a long build cannot make a step look instantaneous or negative.
@external(erlang, "env_ffi", "mono_ms")
pub fn now_ms() -> Int

/// One finished step: what it was, and how long it took.
pub type Timing {
  Timing(label: String, ms: Int)
}

/// A short label per step kind, for the running progress lines and the closing
/// summary. Deliberately terser than the prose each step already logs — the
/// point here is a scannable column, not a second narration.
pub fn step_label(step: Step) -> String {
  case step {
    config.Build -> "build"
    config.Push -> "push"
    config.BootProxy -> "proxy"
    config.BootApp(rolling: _, version: _) -> "release"
    config.RemoveApp -> "remove"
    config.Prune -> "prune"
    config.Healthcheck -> "health"
    config.Lock(config.Acquire) -> "lock"
    config.Lock(config.Release) -> "unlock"
    config.Lock(config.Status) -> "lock-status"
    // A hook has no name, only a command, so label it by the program being
    // run — "hook:docker" says more than a truncated shell line would.
    config.Hook(spec) -> "hook:" <> first_word(spec.run)
  }
}

fn first_word(command: String) -> String {
  case string.split(string.trim(command), " ") {
    [word, ..] if word != "" -> word
    _ -> "?"
  }
}

/// The banner printed before a pipeline runs.
///
/// It names the config file and the primary host on purpose. A repo commonly
/// holds more than one config (ginger.yml plus ginger.cn.yml), the wrong one
/// is selected by simply omitting `-c`, and until now nothing in the output
/// said which environment was about to be changed — the first hint was the
/// hostname buried in a later line.
pub fn banner(
  pipeline_name: String,
  config: Config,
  config_path: String,
  version: String,
) -> String {
  let host = case config.primary_host(config) {
    Ok(h) -> h
    Error(_) -> "(no primary host)"
  }
  string.join(
    [
      "▸ " <> pipeline_name <> " " <> config.service,
      "  config   " <> config_path,
      "  target   " <> host,
      "  version  " <> version,
    ],
    "\n",
  )
}

/// A completed step, e.g. "  ✓ build            1m 12s".
pub fn step_line(timing: Timing) -> String {
  "  ✓ " <> pad_to(timing.label, 16) <> duration(timing.ms)
}

/// The closing total, in the same column as the step lines above it.
///
/// Deliberately *not* a table repeating every step: each step already printed
/// its own duration the moment it finished, and a build's step line lands
/// directly beneath the buildx output it measured. Re-listing all of them at
/// the end doubled the report without adding a fact.
pub fn total_line(total_ms: Int) -> String {
  "  " <> pad_to("total", 18) <> duration(total_ms)
}

/// "820ms", "12s", "3m 05s" — whichever reads fastest at that magnitude.
pub fn duration(ms: Int) -> String {
  case ms < 1000, ms < 60_000 {
    True, _ -> int.to_string(ms) <> "ms"
    False, True -> int.to_string(ms / 1000) <> "s"
    False, False -> {
      let minutes = ms / 60_000
      let seconds = { ms % 60_000 } / 1000
      int.to_string(minutes) <> "m " <> pad_left(int.to_string(seconds)) <> "s"
    }
  }
}

fn pad_left(value: String) -> String {
  case string.length(value) {
    1 -> "0" <> value
    _ -> value
  }
}

fn pad_to(value: String, width: Int) -> String {
  case width - string.length(value) {
    n if n > 0 -> value <> string.repeat(" ", n)
    _ -> value <> " "
  }
}
