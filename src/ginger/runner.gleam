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
pub fn real(ssh_user: String) -> Runner {
  Runner(
    remote: fn(host, cmd) { remote_run(ssh_user, host, cmd) },
    probe: fn(host, cmd) { remote_probe(ssh_user, host, cmd) },
    local: executor.run_local,
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
) -> Result(String, GingerError) {
  case session(ssh_user, host) {
    Error(e) -> Error(e)
    Ok(s) -> executor.run(s, cmd)
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
