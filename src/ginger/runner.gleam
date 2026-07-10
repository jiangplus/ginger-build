import ginger/command.{type Command}
import ginger/context.{type Runner, Runner}
import ginger/error.{type GingerError}
import ginger/executor
import ginger/ssh

/// The production runner. Remote commands reuse one SSH connection per host
/// (cached in the calling process), connecting lazily with retry. Connecting
/// inside the calling process keeps it safe to run from concurrent per-host
/// workers (OTP routes SSH channel messages to the connecting process), and
/// reusing the connection avoids tripping sshd rate limits on rapid reconnects.
/// `default_timeout_ms` is the deadline applied to every plain `remote` call
/// (from `ssh.command_timeout` in the config).
pub fn real(ssh_user: String, default_timeout_ms: Int) -> Runner {
  Runner(
    remote: fn(host, cmd) {
      remote_run(ssh_user, host, cmd, default_timeout_ms)
    },
    remote_timed: fn(host, cmd, timeout_ms) {
      remote_run(ssh_user, host, cmd, timeout_ms)
    },
    remote_streamed: fn(host, cmd, timeout_ms) {
      remote_stream(ssh_user, host, cmd, timeout_ms)
    },
    probe: fn(host, cmd) { remote_probe(ssh_user, host, cmd) },
    local: executor.run_local,
    local_streamed: executor.run_local_streamed,
    local_shell: executor.run_local_string,
  )
}

fn session(ssh_user: String, host: String) -> Result(ssh.Session, GingerError) {
  case ssh.ensure_started() {
    Error(e) -> Error(e)
    Ok(_) -> ssh.connect_cached(host, ssh_user)
  }
}

fn remote_run(
  ssh_user: String,
  host: String,
  cmd: Command,
  timeout_ms: Int,
) -> Result(String, GingerError) {
  case session(ssh_user, host) {
    Error(e) -> Error(e)
    Ok(s) -> executor.run_with_timeout(s, cmd, timeout_ms)
  }
}

fn remote_stream(
  ssh_user: String,
  host: String,
  cmd: Command,
  timeout_ms: Int,
) -> Result(String, GingerError) {
  case session(ssh_user, host) {
    Error(e) -> Error(e)
    Ok(s) -> executor.run_streamed(s, cmd, timeout_ms)
  }
}

fn remote_probe(
  ssh_user: String,
  host: String,
  cmd: Command,
) -> #(String, Int) {
  case session(ssh_user, host) {
    Error(_) -> #("", -1)
    Ok(s) -> executor.probe(s, cmd)
  }
}
