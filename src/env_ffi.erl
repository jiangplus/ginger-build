-module(env_ffi).
-export([get_env/0, read_file/1, local_exec/1, git_sha/0]).

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

%% Resolve the current git revision (HEAD). Returns {ok, Sha} | {error, Reason}.
git_sha() ->
    {Output, Status} = do_exec("git rev-parse HEAD"),
    case Status of
        0 -> {ok, string:trim(Output)};
        _ -> {error, <<"not a git repository (or git unavailable)">>}
    end.
