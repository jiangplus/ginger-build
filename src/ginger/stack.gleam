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
      let sink: Subject(#(String, Result(Nil, GingerError))) =
        process.new_subject()
      let started = list.take(builds, concurrency)
      let queued = list.drop(builds, concurrency)
      list.each(started, fn(b) { start_build(b, sink, log) })
      pump(sink, queued, list.length(started), Ok(Nil), log)
    }
  }
}

fn start_build(
  build: #(String, fn() -> Result(Nil, GingerError)),
  sink: Subject(#(String, Result(Nil, GingerError))),
  log: fn(String) -> Nil,
) -> Nil {
  let #(service, work) = build
  log("  build " <> service <> " started")
  process.spawn(fn() { process.send(sink, #(service, work())) })
  Nil
}

/// Keep `concurrency` builds in flight: as soon as one finishes, start the
/// next.
///
/// The previous implementation chunked the list into fixed batches and waited
/// for an entire batch before starting the next one. A slot freed by a fast
/// build sat idle until its slowest batch-mate finished — with concurrency 2
/// and builds of 1, 7, 8 and 1 minutes, the 8-minute build did not start until
/// seven minutes in, and the whole group took 15 minutes instead of 9.
fn pump(
  sink: Subject(#(String, Result(Nil, GingerError))),
  queued: List(#(String, fn() -> Result(Nil, GingerError))),
  in_flight: Int,
  acc: Result(Nil, GingerError),
  log: fn(String) -> Nil,
) -> Result(Nil, GingerError) {
  case in_flight {
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
      // On failure, stop starting new builds — but still collect the ones
      // already in flight. Abandoning them would leave a half-written image
      // and a deploy lock nobody releases.
      case queued, acc {
        [next, ..tail], Ok(_) -> {
          start_build(next, sink, log)
          pump(sink, tail, in_flight, acc, log)
        }
        _, _ -> pump(sink, [], in_flight - 1, acc, log)
      }
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
  // `deploy_only`/`local_image` mean there is no source to build — the image
  // comes from elsewhere. Single-config deploys have always honoured this;
  // group mode did not, and so ran `docker buildx build` in a directory with
  // no Dockerfile for every upstream-image service in the set, failing the
  // whole deploy.
  let nothing_to_build = entry_config.deploy_only || entry_config.local_image
  let has_build =
    !nothing_to_build
    && list.any(selected.steps, fn(step) {
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
  version.resolve(
    option.or(tag, entry.config.tag),
    entry.config.builder.context,
  )
}
