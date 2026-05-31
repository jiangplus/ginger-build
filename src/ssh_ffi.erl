-module(ssh_ffi).
-export([start/0, connect/2, connect_cached/2, exec_command/3, exec_with_status/3, close/1, get_args/0]).

%% Reuse a single SSH connection per host within the calling process. OTP ssh
%% delivers channel messages to the connecting process, so the cache lives in
%% the process dictionary and is therefore process-local (safe with per-host
%% worker processes). Connecting once per host avoids hammering sshd with rapid
%% reconnects (which trips MaxStartups / rate limiting).
connect_cached(Host, User) ->
    Key = {ssh_conn, Host},
    case get(Key) of
        undefined ->
            case connect_retry(Host, User, 3) of
                {ok, Conn} -> put(Key, Conn), {ok, Conn};
                Err -> Err
            end;
        Conn ->
            {ok, Conn}
    end.

connect_retry(Host, User, N) when N =< 1 ->
    connect(Host, User);
connect_retry(Host, User, N) ->
    case connect(Host, User) of
        {ok, Conn} -> {ok, Conn};
        {error, _} ->
            timer:sleep(800),
            connect_retry(Host, User, N - 1)
    end.

get_args() ->
    [list_to_binary(A) || A <- init:get_plain_arguments()].

start() ->
    case application:ensure_all_started(ssh) of
        {ok, _} -> {ok, nil};
        {error, Reason} -> {error, list_to_binary(io_lib:format("~p", [Reason]))}
    end.

connect(Host, User) ->
    HostStr = binary_to_list(Host),
    UserStr = binary_to_list(User),
    HomeDir = os:getenv("HOME"),
    KeyDir = HomeDir ++ "/.ssh",
    Opts = [
        {user, UserStr},
        {user_dir, KeyDir},
        {silently_accept_hosts, true},
        {auth_methods, "publickey"},
        {connect_timeout, 10000}
    ],
    case ssh:connect(HostStr, 22, Opts) of
        {ok, Conn} -> {ok, Conn};
        {error, Reason} -> {error, list_to_binary(io_lib:format("~p", [Reason]))}
    end.

exec_command(Conn, Cmd, TimeoutMs) ->
    CmdStr = binary_to_list(Cmd),
    case ssh_connection:session_channel(Conn, TimeoutMs) of
        {ok, Chan} ->
            case ssh_connection:exec(Conn, Chan, CmdStr, TimeoutMs) of
                success ->
                    collect_output(Conn, Chan, TimeoutMs, []);
                {error, Reason} ->
                    {error, list_to_binary(io_lib:format("exec failed: ~p", [Reason]))}
            end;
        {error, Reason} ->
            {error, list_to_binary(io_lib:format("channel failed: ~p", [Reason]))}
    end.

collect_output(Conn, Chan, Timeout, Acc) ->
    receive
        {ssh_cm, Conn, {data, Chan, _Type, Data}} ->
            collect_output(Conn, Chan, Timeout, [Data | Acc]);
        {ssh_cm, Conn, {eof, Chan}} ->
            collect_output(Conn, Chan, Timeout, Acc);
        {ssh_cm, Conn, {exit_status, Chan, _Status}} ->
            collect_output(Conn, Chan, Timeout, Acc);
        {ssh_cm, Conn, {closed, Chan}} ->
            Output = iolist_to_binary(lists:reverse(Acc)),
            {ok, Output}
    after Timeout ->
        Output = iolist_to_binary(lists:reverse(Acc)),
        {ok, Output}
    end.

%% Like exec_command, but captures stdout and stderr separately and returns the
%% command's exit status. Returns {ok, {Stdout, Stderr, ExitStatus}} | {error, Reason}.
exec_with_status(Conn, Cmd, TimeoutMs) ->
    CmdStr = binary_to_list(Cmd),
    case ssh_connection:session_channel(Conn, TimeoutMs) of
        {ok, Chan} ->
            case ssh_connection:exec(Conn, Chan, CmdStr, TimeoutMs) of
                success ->
                    collect_status(Conn, Chan, TimeoutMs, [], [], 0);
                {error, Reason} ->
                    {error, list_to_binary(io_lib:format("exec failed: ~p", [Reason]))}
            end;
        {error, Reason} ->
            {error, list_to_binary(io_lib:format("channel failed: ~p", [Reason]))}
    end.

collect_status(Conn, Chan, Timeout, Out, Err, Status) ->
    receive
        {ssh_cm, Conn, {data, Chan, 0, Data}} ->
            collect_status(Conn, Chan, Timeout, [Data | Out], Err, Status);
        {ssh_cm, Conn, {data, Chan, 1, Data}} ->
            collect_status(Conn, Chan, Timeout, Out, [Data | Err], Status);
        {ssh_cm, Conn, {eof, Chan}} ->
            collect_status(Conn, Chan, Timeout, Out, Err, Status);
        {ssh_cm, Conn, {exit_status, Chan, S}} ->
            collect_status(Conn, Chan, Timeout, Out, Err, S);
        {ssh_cm, Conn, {exit_signal, Chan, _Signal, _ErrMsg, _Lang}} ->
            collect_status(Conn, Chan, Timeout, Out, Err, Status);
        {ssh_cm, Conn, {closed, Chan}} ->
            finish_status(Out, Err, Status)
    after Timeout ->
        finish_status(Out, Err, Status)
    end.

finish_status(Out, Err, Status) ->
    Stdout = iolist_to_binary(lists:reverse(Out)),
    Stderr = iolist_to_binary(lists:reverse(Err)),
    {ok, {Stdout, Stderr, Status}}.

close(Conn) ->
    ssh:close(Conn),
    {ok, nil}.
