-module(awre_trans_ws).
-behaviour(awre_transport).

%% awre_transport
-export([init/1]).
-export([send_to_router/2]).
-export([handle_info/2]).
-export([shutdown/2]).

-record(state,{
    path::iodata(),
    gun::pid(),
    monitor::reference(),
    enc::msgpack|json, 
    mode::text|binary,
    realm, version, client_details,
    last_error :: term()
}).

-define(SCHEME_DEFAULTS, [{scheme_defaults, [{ws, 80}, {wss, 443}]}]).

%% awre_transport
init(#{uri:=Uri, realm:=Realm, version:=Version, client_details:=Details, options:=Opts}) ->
    {ok, {_Scheme, _, Host, Port, Path, _}} = http_uri:parse(Uri, ?SCHEME_DEFAULTS),
    Encoding = maps:get(encoding, Opts, msgpack),
    GunOpts = gun_opts(maps:to_list(Opts), #{protocols => [http]}),
    {ok, Pid} = gun:open(Host, Port, GunOpts),
    {ok, #state{
        path = Path, 
        gun = Pid, 
        monitor = monitor(process, Pid),
        enc = Encoding,
        mode = case Encoding of 
            %TODO: handle other encodings
            msgpack -> binary;
            json -> text
        end,
        realm = Realm,
        version = Version,
        client_details = Details
    }}.

send_to_router(Message, S=#state{gun=Pid, enc=Enc, mode=Mode}) ->
    Buff = wamper_protocol:serialize(Message, Enc),
    gun:ws_send(Pid, {Mode, Buff}),
    {ok, S}.

handle_info({gun_up, Pid, _}, S=#state{gun=Pid, enc=Enc, path=Path}) ->
    Handler = case Enc of 
        msgpack -> {<<"wamp.2.msgpack">>, gun_ws_handler};
        json -> {<<"wamp.2.json">>, gun_ws_handler}
    end,
    gun:ws_upgrade(Pid, Path, [], #{
        protocols => [Handler],
        compress => true
    }),
    {noreply, S};
handle_info({gun_ws_upgrade, _Pid, ok, _}, S=#state{gun=_Pid, realm=Realm, version=Version, client_details=Details}) ->
    send_to_router({hello, Realm, #{agent => Version, roles => Details}}, S),
    {noreply, S};

handle_info({gun_response, _Pid, _, _, Status, Headers}, S=#state{gun=_Pid}) ->
    {reply, [{error, #{status => Status, headers => Headers}, ws_error}], S#state{
        last_error = {http, Status}
    }};
handle_info({gun_error, _Pid, _, Reason}, S=#state{gun=_Pid}) ->
    {reply, [{error, #{reason => Reason}, ws_error}], S#state{
        last_error = Reason
    }};

handle_info({gun_down, _Pid, _, _, _, _}, S=#state{gun=_Pid}) ->
    {noreply, S};
handle_info({'DOWN', _Ref, process, _Pid, Reason}, S=#state{monitor=_Ref, gun=_Pid, last_error=undefined}) ->
    {stop, {gun_down, Reason}, [{abort, #{reason => Reason}, gun_down}], S#state{gun=undefined, monitor=undefined}};
handle_info({'DOWN', _Ref, process, _Pid, _}, S=#state{monitor=_Ref, gun=_Pid, last_error=LastError}) ->
    {stop, {ws_error, LastError}, [{abort, #{reason => LastError}, ws_error}], S#state{gun=undefined, monitor=undefined}};

handle_info({gun_ws, _Pid, {_Mode, Frame}}, S=#state{gun=_Pid, enc=Enc, mode=_Mode}) ->
    {Messages, <<>>} = wamper_protocol:deserialize(Frame, Enc),
    {reply, Messages, S};
handle_info(_, State) ->
    {noreply, State}.   

shutdown(_Reason, #state{gun=undefined}) ->
    ok;
shutdown(normal, #state{gun=Pid, monitor=Ref}) ->
    demonitor(Ref),
    gun:shutdown(Pid),
    ok;
shutdown(_Reason, #state{gun=Pid, monitor=Ref}) ->
    demonitor(Ref),
    gun:close(Pid),
    ok.

%%
gun_opts([{ip, Ip} | Opts], Acc) ->
    gun_opts(Opts, maps:update_with(transport_opts, 
        fun(Val) -> [{ip, Ip} | Val] end, 
        [{ip, Ip}], Acc));
gun_opts([{retry, R} | T], Acc) when is_integer(R), R >= 0 ->
    gun_opts(T, Acc#{retry => R});
gun_opts([{retry_timeout, T} | Opts], Acc) when is_integer(T), T >= 0 ->
    gun_opts(Opts, Acc#{retry_timeout => T});
gun_opts([_ | Opts], Acc) -> 
    gun_opts(Opts, Acc);
gun_opts([], Acc) -> 
    Acc.
