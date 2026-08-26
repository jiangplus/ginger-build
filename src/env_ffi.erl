-module(env_ffi).
-export([get_env/0, read_file/1, local_exec/1, local_exec_stream/1,
         local_exec_stream_prefixed/2, git_sha/1, timestamp/0, mono_ms/0]).

%% Decode a Gleam String (a UTF-8 binary) into the CHARACTER list that
%% open_port/2 and the file:* functions expect.
%%
%% This is not cosmetic. open_port/2 with spawn_executable encodes each element
%% of `args` according to file:native_name_encoding(), which is utf8 on macOS
%% and modern Linux. Handing it binary_to_list/1 passes the UTF-8 *bytes* as if
%% each were a codepoint, and every byte is then re-encoded: "深" (E6 B7 B1)
%% leaves the port as C3 A6 C2 B7 C2 B1. Decoding to codepoints first makes the
%% round trip lossless.
%%
%% This is what silently mangled a non-ASCII secret injected into a container —
%% the value arrived double-encoded and the service failed at runtime, with
%% nothing in the deploy output to suggest ginger had touched it.
chars(Bin) when is_binary(Bin) ->
    case unicode:characters_to_list(Bin, utf8) of
        L when is_list(L) -> L;
        %% Not valid UTF-8 — a raw byte string from somewhere upstream. Pass the
        %% bytes through rather than abort a deploy over an encoding guess.
        _ -> binary_to_list(Bin)
    end.

%% Encode a character list from the OS back into a UTF-8 binary (a Gleam
%% String). os:getenv/0 hands back codepoints when the emulator's name encoding
%% is utf8, so list_to_binary/1 would fail with badarg on any value outside
%% latin-1 rather than merely corrupting it.
env_binary(L) ->
    case file:native_name_encoding() of
        latin1 -> list_to_binary(L);
        _ ->
            case unicode:characters_to_binary(L) of
                B when is_binary(B) -> B;
                _ -> list_to_binary(L)
            end
    end.

%% Return the whole process environment as a list of {Key, Value} binaries.
get_env() ->
    lists:filtermap(
        fun(Entry) ->
            case string:split(Entry, "=") of
                [K, V] -> {true, {env_binary(K), env_binary(V)}};
                _ -> false
            end
        end,
        os:getenv()
    ).

%% Read a local file. Returns {ok, Binary} | {error, Binary}.
%% The contents come back as a raw binary, which is already the file's UTF-8
%% bytes — only the path needs decoding.
read_file(Path) ->
    case file:read_file(chars(Path)) of
        {ok, Bin} -> {ok, Bin};
        {error, Reason} ->
            {error, list_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% Run a shell command on the operator machine, capturing combined
%% stdout/stderr and the exit status. Returns {Output, ExitStatus}.
local_exec(Cmd) ->
    do_exec(chars(Cmd)).

%% Like local_exec/1 but streams each output chunk to stdout as it arrives.
%% Returns {"", ExitStatus} — the output has already been printed.
local_exec_stream(Cmd) ->
    do_exec_stream(chars(Cmd)).

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

%% Same as local_exec_stream/1, but tags every line with a prefix.
%%
%% Concurrent builds all wrote to the same stdout through io:put_chars/1 on raw
%% port chunks — chunks, not lines, so two builds could interleave *within* a
%% line. The output was unattributable: several "#24 DONE 185.9s" lines with no
%% way to tell which service each belonged to. Buffering to line boundaries and
%% prefixing fixes both problems at once.
local_exec_stream_prefixed(Cmd, Prefix) ->
    Port = open_port(
        {spawn_executable, "/bin/sh"},
        [{args, ["-c", chars(Cmd)]}, exit_status, stderr_to_stdout, binary, use_stdio]
    ),
    stream_collect_prefixed(Port, Prefix, <<"">>).

stream_collect_prefixed(Port, Prefix, Buf) ->
    receive
        {Port, {data, Data}} ->
            Rest = emit_lines(Prefix, <<Buf/binary, Data/binary>>),
            stream_collect_prefixed(Port, Prefix, Rest);
        {Port, {exit_status, Status}} ->
            %% A trailing fragment with no newline still has to be shown —
            %% dropping it would silently eat the last line of a failing build.
            case Buf of
                <<"">> -> ok;
                _ -> io:put_chars([Prefix, Buf, $\n])
            end,
            {<<"">>, Status}
    end.

emit_lines(Prefix, Buf) ->
    case binary:split(Buf, <<"\n">>) of
        [Line, Rest] ->
            io:put_chars([Prefix, Line, $\n]),
            emit_lines(Prefix, Rest);
        [Rest] ->
            Rest
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
    Cmd = "git -C " ++ shell_quote(chars(Dir)) ++ " rev-parse HEAD",
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
