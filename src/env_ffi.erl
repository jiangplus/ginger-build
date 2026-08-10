-module(env_ffi).
-export([get_env/0, read_file/1, local_exec/1, local_exec_stream/1, git_sha/1, timestamp/0, mono_ms/0]).

%% Return the whole process environment as a list of {Key, Value} binaries.
get_env() ->
    lists:filtermap(
        fun(Entry) ->
            case string:split(Entry, "=") of
                [K, V] -> {true, {list_to_binary(K), list_to_binary(V)}};
                _ -> false
            end
        end,
        os:getenv()
    ).

%% Read a local file. Returns {ok, Binary} | {error, Binary}.
read_file(Path) ->
    case file:read_file(binary_to_list(Path)) of
        {ok, Bin} -> {ok, Bin};
        {error, Reason} ->
            {error, list_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% Run a shell command on the operator machine, capturing combined
%% stdout/stderr and the exit status. Returns {Output, ExitStatus}.
local_exec(Cmd) ->
    do_exec(binary_to_list(Cmd)).

%% Like local_exec/1 but streams each output chunk to stdout as it arrives.
%% Returns {"", ExitStatus} — the output has already been printed.
local_exec_stream(Cmd) ->
    do_exec_stream(binary_to_list(Cmd)).

do_exec_stream(Cmd) ->
    Port = open_port(
        {spawn_executable, "/bin/sh"},
        [{args, ["-c", Cmd]}, exit_status, stderr_to_stdout, binary, use_stdio]
    ),
    stream_collect(Port).

stream_collect(Port) ->
    receive
        {Port, {data, Data}} ->
            io:put_chars(Data),
            stream_collect(Port);
        {Port, {exit_status, Status}} ->
            {<<"">>, Status}
    end.

do_exec(Cmd) ->
    Port = open_port(
        {spawn_executable, "/bin/sh"},
        [{args, ["-c", Cmd]}, exit_status, stderr_to_stdout, binary, use_stdio]
    ),
    collect(Port, []).

collect(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect(Port, [Data | Acc]);
        {Port, {exit_status, Status}} ->
            Output = iolist_to_binary(lists:reverse(Acc)),
            {Output, Status}
    end.

%% Resolve the current git revision (HEAD) of a directory.
%% Returns {ok, Sha} | {error, Reason}.
git_sha(Dir) ->
    Cmd = "git -C " ++ shell_quote(binary_to_list(Dir)) ++ " rev-parse HEAD",
    {Output, Status} = do_exec(Cmd),
    case Status of
        0 -> {ok, string:trim(Output)};
        _ -> {error, <<"not a git repository (or git unavailable)">>}
    end.

shell_quote(S) ->
    "'" ++ lists:flatten([case C of $' -> "'\\''"; _ -> [C] end || C <- S]) ++ "'".

%% Milliseconds from an arbitrary origin, for measuring step durations.
%% Monotonic, not wall-clock: an NTP correction mid-deploy must not be able to
%% report a step as having taken negative time.
mono_ms() ->
    erlang:monotonic_time(millisecond).

%% UTC timestamp "YYYY-MM-DDTHH:MM:SSZ" for the deploy history log.
timestamp() ->
    {{Y, Mo, D}, {H, Mi, S}} = calendar:universal_time(),
    list_to_binary(io_lib:format(
        "~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ", [Y, Mo, D, H, Mi, S]
    )).
