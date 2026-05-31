-module(ssh_ffi).
-export([start/0, connect/2, exec_command/3, close/1, get_args/0]).

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

close(Conn) ->
    ssh:close(Conn),
    {ok, nil}.
