import ginger/command.{type Command}
import ginger/config.{type Config}

/// The run directory ginger uses on each host.
pub const run_directory = ".ginger"

/// The lock directory for a service: `.ginger/lock-<service>`.
pub fn lock_dir(config: Config) -> String {
  run_directory <> "/lock-" <> config.service
}

/// Ensure the run directory exists: `mkdir -p .ginger`.
pub fn ensure_run_directory() -> Command {
  command.run(["mkdir", "-p", run_directory])
}

/// Acquire the deploy lock by creating the lock directory. `mkdir` (without
/// `-p`) fails if the directory already exists — that failure is the mutex.
pub fn acquire(config: Config) -> Command {
  command.run(["mkdir", lock_dir(config)])
}

/// Release the lock: `rm -r .ginger/lock-<service>`.
pub fn release(config: Config) -> Command {
  command.run(["rm", "-r", lock_dir(config)])
}

/// Inspect the lock directory: `stat .ginger/lock-<service>`.
pub fn status(config: Config) -> Command {
  command.run(["stat", lock_dir(config)])
}
