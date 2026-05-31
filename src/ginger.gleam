import gleam/io
import gleam/list
import gleam/result
import gleam/string

@external(erlang, "ssh_ffi", "start")
fn ssh_start() -> Result(Nil, String)

@external(erlang, "ssh_ffi", "connect")
fn ssh_connect(host: String, user: String) -> Result(Connection, String)

@external(erlang, "ssh_ffi", "exec_command")
fn ssh_exec(conn: Connection, cmd: String, timeout_ms: Int) -> Result(String, String)

@external(erlang, "ssh_ffi", "close")
fn ssh_close(conn: Connection) -> Result(Nil, String)

@external(erlang, "ssh_ffi", "get_args")
fn get_args() -> List(String)

pub type Connection

pub fn main() -> Nil {
  case get_args() {
    [host, ..rest] -> {
      let user = list.first(rest) |> result.unwrap("root")
      run(host, user)
    }
    [] -> {
      io.println("usage: ginger <host> [user]")
    }
  }
}

fn run(host: String, user: String) -> Nil {
  io.println("Connecting to " <> user <> "@" <> host <> "...")

  let outcome = {
    use _ <- result.try(ssh_start())
    use conn <- result.try(ssh_connect(host, user))
    use output <- result.try(ssh_exec(conn, "ls -la ~", 10_000))
    let _ = ssh_close(conn)
    Ok(output)
  }

  case outcome {
    Ok(output) -> io.println(string.trim(output))
    Error(reason) -> io.println("Error: " <> reason)
  }
}
