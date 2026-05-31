import ginger/error.{type GingerError, SshError}

/// Opaque handle to an OTP ssh connection (an Erlang pid).
pub type Connection

@external(erlang, "ssh_ffi", "start")
fn ffi_start() -> Result(Nil, String)

@external(erlang, "ssh_ffi", "connect")
fn ffi_connect(host: String, user: String) -> Result(Connection, String)

@external(erlang, "ssh_ffi", "connect_cached")
fn ffi_connect_cached(host: String, user: String) -> Result(Connection, String)

@external(erlang, "ssh_ffi", "exec_with_status")
fn ffi_exec(
  conn: Connection,
  cmd: String,
  timeout_ms: Int,
) -> Result(#(String, String, Int), String)

@external(erlang, "ssh_ffi", "close")
fn ffi_close(conn: Connection) -> Result(Nil, String)

/// A live SSH session to one host. The connection is owned by the process that
/// created it — do not share a `Session` across processes (OTP delivers SSH
/// channel messages only to the connecting process).
pub type Session {
  Session(host: String, connection: Connection)
}

/// Ensure the OTP ssh application is started (idempotent).
pub fn ensure_started() -> Result(Nil, GingerError) {
  case ffi_start() {
    Ok(_) -> Ok(Nil)
    Error(reason) ->
      Error(SshError("could not start ssh application: " <> reason))
  }
}

/// Open a session to a host as a user (public-key auth from ~/.ssh).
pub fn connect(host: String, user: String) -> Result(Session, GingerError) {
  case ffi_connect(host, user) {
    Ok(connection) -> Ok(Session(host: host, connection: connection))
    Error(reason) ->
      Error(SshError("connect " <> user <> "@" <> host <> ": " <> reason))
  }
}

/// Like `connect`, but reuses a per-process cached connection to the host
/// (connecting once, with retry). Use this for the many commands a deploy runs
/// against the same host to avoid rapid-reconnect rate limiting.
pub fn connect_cached(
  host: String,
  user: String,
) -> Result(Session, GingerError) {
  case ffi_connect_cached(host, user) {
    Ok(connection) -> Ok(Session(host: host, connection: connection))
    Error(reason) ->
      Error(SshError("connect " <> user <> "@" <> host <> ": " <> reason))
  }
}

/// Execute a command string, returning `#(stdout, stderr, exit_status)`.
pub fn exec(
  session: Session,
  command_string: String,
  timeout_ms: Int,
) -> Result(#(String, String, Int), GingerError) {
  case ffi_exec(session.connection, command_string, timeout_ms) {
    Ok(triple) -> Ok(triple)
    Error(reason) ->
      Error(SshError("exec on " <> session.host <> ": " <> reason))
  }
}

/// Close a session. Errors are ignored — teardown is best-effort.
pub fn close(session: Session) -> Nil {
  let _ = ffi_close(session.connection)
  Nil
}
