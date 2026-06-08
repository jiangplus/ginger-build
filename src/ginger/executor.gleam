import ginger/command.{type Command}
import ginger/error.{type GingerError, ExecError, HookFailed}
import ginger/ssh.{type Session}
import gleam/int
import gleam/result
import gleam/string

/// Default command timeout (5 minutes) — generous enough for image pulls.
pub const default_timeout = 300_000

@external(erlang, "env_ffi", "local_exec")
fn ffi_local_exec(command: String) -> #(String, Int)

@external(erlang, "env_ffi", "local_exec_stream")
fn ffi_local_exec_stream(command: String) -> #(String, Int)

/// Run a command over an existing SSH session. Non-zero exit → `ExecError`.
pub fn run(session: Session, cmd: Command) -> Result(String, GingerError) {
  run_with_timeout(session, cmd, default_timeout)
}

pub fn run_with_timeout(
  session: Session,
  cmd: Command,
  timeout_ms: Int,
) -> Result(String, GingerError) {
  let rendered = command.to_string(cmd)
  use #(stdout, stderr, exit) <- result.try(ssh.exec(
    session,
    rendered,
    timeout_ms,
  ))
  case exit {
    0 -> Ok(string.trim(stdout))
    _ ->
      Error(ExecError(
        host: session.host,
        command: rendered,
        exit: exit,
        stderr: string.trim(stderr),
      ))
  }
}

/// Run a command over SSH but tolerate a non-zero exit, returning
/// `#(combined_output, exit_status)`. Used for probes (e.g. "does this
/// container exist?") where a non-zero exit is information, not an error.
pub fn probe(session: Session, cmd: Command) -> #(String, Int) {
  let rendered = command.to_string(cmd)
  case ssh.exec(session, rendered, default_timeout) {
    Ok(#(stdout, stderr, exit)) ->
      case stdout {
        "" -> #(string.trim(stderr), exit)
        _ -> #(string.trim(stdout), exit)
      }
    Error(_) -> #("", -1)
  }
}

/// Run a built command on the operator machine (e.g. `docker buildx build`).
pub fn run_local(cmd: Command) -> Result(String, GingerError) {
  run_local_string(command.to_string(cmd))
}

/// Like `run_local` but streams output to stdout as it arrives instead of
/// capturing it. Used for long-running commands like `docker buildx build`
/// where the user wants to see progress in real time.
pub fn run_local_streamed(cmd: Command) -> Result(String, GingerError) {
  let rendered = command.to_string(cmd)
  let #(_, exit) = ffi_local_exec_stream(rendered)
  case exit {
    0 -> Ok("")
    _ ->
      Error(HookFailed(
        "local command failed (exit " <> int.to_string(exit) <> "): " <> rendered,
      ))
  }
}

/// Run a raw shell string locally (e.g. an inline local hook).
pub fn run_local_string(rendered: String) -> Result(String, GingerError) {
  let #(output, exit) = ffi_local_exec(rendered)
  case exit {
    0 -> Ok(string.trim(output))
    _ ->
      Error(HookFailed(
        "local command failed (exit "
        <> int.to_string(exit)
        <> "): "
        <> rendered
        <> "\n"
        <> string.trim(output),
      ))
  }
}
