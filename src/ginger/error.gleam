import gleam/int

/// Every fallible operation in ginger returns `Result(_, GingerError)`.
/// Variants carry enough context (host, command, exit code) to produce a
/// useful message at the top level.
pub type GingerError {
  /// SSH connection / channel level failure.
  SshError(String)
  /// Config file missing, unreadable, or failed a validation guard.
  ConfigError(String)
  /// YAML present but could not be decoded into the typed config.
  DecodeError(String)
  /// A remote command exited non-zero.
  ExecError(host: String, command: String, exit: Int, stderr: String)
  /// An inline hook command failed.
  HookFailed(String)
  /// The deploy lock could not be acquired (already held).
  LockError(String)
  /// A role was aborted because the primary role failed its health gate.
  DeployAborted(String)
}

/// Render an error for display to the operator.
pub fn to_string(error: GingerError) -> String {
  case error {
    SshError(msg) -> "SSH error: " <> msg
    ConfigError(msg) -> "Config error: " <> msg
    DecodeError(msg) -> "Config decode error: " <> msg
    ExecError(host, command, exit, stderr) ->
      "Command failed on "
      <> host
      <> " (exit "
      <> int.to_string(exit)
      <> "): "
      <> command
      <> case stderr {
        "" -> ""
        _ -> "\n" <> stderr
      }
    HookFailed(msg) -> "Hook failed: " <> msg
    LockError(msg) -> "Lock error: " <> msg
    DeployAborted(msg) -> "Deploy aborted: " <> msg
  }
}
