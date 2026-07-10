//// Multi-config orchestration: `ginger deploy -c a.yml -c b.yml -c c.yml`.
////
//// ginger deliberately has no stack file — each service keeps its own
//// independent ginger.yml. A config may declare `deps: [../other.yml]`
//// (paths relative to the config file); when several configs are deployed
//// together, deps order the rollout. Builds run first, in parallel with a
//// small concurrency cap (they are memory-hungry — don't be aggressive),
//// then services deploy sequentially in dependency order. Deps pointing at
//// configs outside the deploy set are ignored with a note.

import ginger/config.{type Config}
import ginger/deploy
import ginger/error.{type GingerError, ConfigError}
import ginger/version
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string

/// One loaded config plus the path it came from (normalized, used as the
/// identity that `deps` entries resolve against).
pub type Entry {
  Entry(path: String, config: Config)
}

/// Resolve a dep path (relative to the directory of `from`) to normalized
/// form so it can be matched against the entry list.
pub fn resolve_dep(from: String, dep: String) -> String {
  case string.starts_with(dep, "/") {
    True -> normalize(dep)
    False -> normalize(dirname(from) <> "/" <> dep)
  }
}

/// Normalize a path textually: collapse `.`, `..`, and `//`.
pub fn normalize(path: String) -> String {
  let absolute = string.starts_with(path, "/")
  let parts =
    path
    |> string.split("/")
    |> list.fold([], fn(acc, part) {
      case part {
        "" | "." -> acc
        ".." ->
          case acc {
            [top, ..rest] if top != ".." -> rest
            _ -> [part, ..acc]
          }
        _ -> [part, ..acc]
      }
    })
    |> list.reverse
  case absolute {
    True -> "/" <> string.join(parts, "/")
    False -> string.join(parts, "/")
  }
}

fn dirname(path: String) -> String {
  case string.split(path, "/") |> list.reverse {
    [_file] -> "."
    [_file, ..dirs] -> string.join(list.reverse(dirs), "/")
    [] -> "."
  }
}

/// Order entries so every entry comes after its in-set deps (Kahn's
/// algorithm). Deps outside the set are ignored. A cycle is a config error.
pub fn topo_order(entries: List(Entry)) -> Result(List(Entry), GingerError) {
  let paths = list.map(entries, fn(e) { e.path })
  let in_set_deps = fn(entry: Entry) {
    entry.config.deps
    |> list.map(fn(dep) { resolve_dep(entry.path, dep) })
    |> list.filter(fn(dep) { list.contains(paths, dep) })
  }
  do_topo(entries, in_set_deps, [], list.length(entries))
}

fn do_topo(
  remaining: List(Entry),
  deps_of: fn(Entry) -> List(String),
  done: List(Entry),
  fuel: Int,
) -> Result(List(Entry), GingerError) {
  case remaining {
    [] -> Ok(list.reverse(done))
    _ if fuel <= 0 ->
      Error(ConfigError(
        "dependency cycle among configs: "
        <> string.join(list.map(remaining, fn(e) { e.path }), ", "),
      ))
    _ -> {
      let done_paths = list.map(done, fn(e) { e.path })
      let #(ready, blocked) =
        list.partition(remaining, fn(entry) {
          deps_of(entry)
          |> list.all(fn(dep) { list.contains(done_paths, dep) })
        })
      case ready {
        [] ->
          Error(ConfigError(
            "dependency cycle among configs: "
            <> string.join(list.map(remaining, fn(e) { e.path }), ", "),
          ))
        _ ->
          do_topo(
            blocked,
            deps_of,
            list.append(list.reverse(ready), done),
            fuel - 1,
          )
      }
    }
  }
}

/// The per-entry work already prepared by the CLI layer: a build thunk (run
/// concurrently, capped) and a deploy thunk (run sequentially in dep order).
pub type Job {
  Job(
    entry: Entry,
    build: Option(fn() -> Result(Nil, GingerError)),
    deploy: fn() -> Result(Nil, GingerError),
  )
}

/// Run a group: parallel builds (batches of `concurrency`), then sequential
/// deploys in the given (already topo-sorted) order.
pub fn run_group(
  jobs: List(Job),
  concurrency: Int,
  log: fn(String) -> Nil,
) -> Result(Nil, GingerError) {
  let builds =
    jobs
    |> list.filter_map(fn(job) {
      case job.build {
        option.Some(build) -> Ok(#(job.entry.config.service, build))
        option.None -> Error(Nil)
      }
    })
  use _ <- result.try(run_builds(builds, int.max(concurrency, 1), log))
  list.try_fold(jobs, Nil, fn(_, job) {
    log("Deploying " <> job.entry.config.service <> "...")
    job.deploy()
  })
}

fn run_builds(
  builds: List(#(String, fn() -> Result(Nil, GingerError))),
  concurrency: Int,
  log: fn(String) -> Nil,
) -> Result(Nil, GingerError) {
  case builds {
    [] -> Ok(Nil)
    _ -> {
      log(
        "Building "
        <> int.to_string(list.length(builds))
        <> " image(s), "
        <> int.to_string(concurrency)
        <> " at a time...",
      )
      builds
      |> list.sized_chunk(concurrency)
      |> list.try_fold(Nil, fn(_, batch) { run_build_batch(batch, log) })
    }
  }
}

fn run_build_batch(
  batch: List(#(String, fn() -> Result(Nil, GingerError))),
  log: fn(String) -> Nil,
) -> Result(Nil, GingerError) {
  let sink: Subject(#(String, Result(Nil, GingerError))) = process.new_subject()
  list.each(batch, fn(build) {
    let #(service, work) = build
    log("  build " <> service <> " started")
    process.spawn(fn() { process.send(sink, #(service, work())) })
  })
  collect(sink, list.length(batch), Ok(Nil), log)
}

fn collect(
  sink: Subject(#(String, Result(Nil, GingerError))),
  remaining: Int,
  acc: Result(Nil, GingerError),
  log: fn(String) -> Nil,
) -> Result(Nil, GingerError) {
  case remaining {
    0 -> acc
    _ -> {
      let #(service, outcome) = process.receive_forever(sink)
      let acc = case outcome, acc {
        Ok(_), _ -> {
          log("  ✓ build " <> service <> " done")
          acc
        }
        Error(e), Ok(_) -> {
          log("  ✗ build " <> service <> " failed")
          Error(e)
        }
        Error(_), _ -> {
          log("  ✗ build " <> service <> " failed")
          acc
        }
      }
      collect(sink, remaining - 1, acc, log)
    }
  }
}

/// Select the pipeline for a group entry and split it into "has a build step"
/// and "the pipeline with builds removed" — group mode hoists builds into the
/// parallel phase and runs the remainder sequentially.
pub fn split_pipeline(
  entry_config: Config,
  name: String,
) -> Result(#(Bool, config.Pipeline), GingerError) {
  use selected <- result.try(deploy.select_pipeline(entry_config, name))
  let has_build =
    list.any(selected.steps, fn(step) {
      case step {
        config.Build -> True
        _ -> False
      }
    })
  Ok(#(has_build, deploy.without_build(selected)))
}

/// Resolve each entry's version: an explicit tag wins, otherwise the git sha
/// of that entry's build context.
pub fn entry_version(
  entry: Entry,
  tag: Option(String),
) -> Result(String, GingerError) {
  version.resolve(tag, entry.config.builder.context)
}
