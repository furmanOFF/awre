-module(awre_trans_ws).
-behaviour(awre_transport).

%% awre_transport
-export([init/1]).
-export([send_to_router/2]).
-export([handle_info/2]).
-export([shutdown/1]).

-record(state,{
    path::iodata(),
    awre::pid(),
    gun::pid(),
    enc::msgpack|json, 
    mode::text|binary,
    realm, version, client_details
}).

%% awre_transport
init(#{awre_con:=Con, uri:=Uri, enc:=Encoding, realm:=Realm, version:=Version, client_details:=Details}) ->
    Opts = [{scheme_defaults, [{ws, 80}, {wss, 443}]}],
    {ok, {_Scheme, _, Host, Port, Path, _}} = http_uri:parse(Uri, Opts),
    {ok, Pid} = gun:open(Host, Port, #{protocols => [http]}),
    link(Pid),
    {ok, #state{
        path = Path,
        awre = Con, 
        gun = Pid, 
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
    {ok, S};
handle_info({gun_ws_upgrade, _Pid, ok, _}, S=#state{gun=_Pid, realm=Realm, version=Version, client_details=Details}) ->
    send_to_router({hello, Realm, #{agent => Version, roles => Details}}, S);
handle_info({gun_response, _Pid, _, _, Status, Headers}, S=#state{ gun=_Pid, awre=Con}) ->
    awre_con:send_to_client(Con, {abort, #{status => Status, headers => Headers}, ws_upgrade_failed}),
    {ok, S};
handle_info({gun_error, _Pid, _, Reason}, S=#state{gun=_Pid, awre=Con}) ->
    awre_con:send_to_client(Con, {abort, #{reason => Reason}, ws_upgrade_failed}),
    {ok, S};
handle_info({gun_down, _Pid, _, _, _, _}, S=#state{gun=_Pid}) ->
    {ok, S};
handle_info({gun_ws, _Pid, {_Mode, Frame}}, S=#state{awre=Con, gun=_Pid, enc=Enc, mode=_Mode}) ->
    {Messages, <<>>} = wamper_protocol:deserialize(Frame, Enc),
    lists:foreach(fun(Msg) -> awre_con:send_to_client(Con, Msg) end, Messages),
    {ok, S};
handle_info(_, State) ->
    {ok, State}.   

shutdown(#state{gun=Pid}) ->
    unlink(Pid),
    gun:close(Pid),
    ok.

%%


