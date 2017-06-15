%%
%% Copyright (c) 2015 Bas Wegh
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in all
%% copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
%% SOFTWARE.
%%


-module(awre).


%% API for connecting to a router (either local or remote)
-export([connect/1, connect/3, connect/4]).
-export([shutdown/1, shutdown/3]).

-export([await_connect/1, await_connect/2, await_connect/3]).

-export([subscribe/3,subscribe/4]).
-export([unsubscribe/2]).
-export([publish/3,publish/4,publish/5]).

-export([register/3,register/4]).
-export([unregister/2]).
-export([call/3,call/4,call/5]).
-export([yield/3,yield/4,yield/5]).
-export([error/5]).


-export([get_version/0]).

%% @doc returns the version string for the application, used as agent description
-spec get_version() -> Version::binary().
get_version() ->
  Ver = case application:get_key(vsn) of
    {ok, V} -> list_to_binary(V);
    _ -> <<"UNKNOWN">>
  end,
  << <<"Awre-">>/binary, Ver/binary >>.



%% @doc Connect to a router in the VM.
%% The connection will be established to the local router in the VM.
-spec connect(Realm :: binary()) -> {ok, Con :: pid()}.
connect(Realm) ->
  supervisor:start_child(awre_sup, [self(), undefined, Realm, undefined]).

%% @doc connect to a remote router.
%% Connect to the router at the given uri Uri to the realm Realm.
%% The connection will be established by using the encoding Encoding for serialization.
-spec connect(Uri :: string(), Realm :: binary(), Encoding :: json | msgpack) -> {ok, Con :: pid()}.
connect(Uri, Realm, Encoding) ->
  supervisor:start_child(awre_sup, [self(), Uri, Realm, Encoding]).

%% Connect to the router at the given host Host on port Port to the realm Realm.
%% The connection will be established by using the encoding Encoding for serialization.
-spec connect(Host :: inet:hostname(), Port :: inet:port_number(), Realm :: binary(), Encoding :: raw_json | raw_msgpack) -> {ok, Con :: pid()}.
connect(Host, Port, Realm, Encoding) ->
  supervisor:start_child(awre_sup, [self(), {Host, Port}, Realm, Encoding]).

%% @doc shutdown given connection
%% TODO: implement
-spec shutdown(ConPid :: pid(), Details :: list(), Reason :: binary()) -> ok.
shutdown(ConPid, Details, Reason) ->
  gen_server:cast(ConPid, {shutdown, Details, Reason}).

-spec shutdown(ConPid :: pid()) -> ok.
shutdown(ConPid) ->
  gen_server:cast(ConPid, {shutdown, #{}, goodbye_and_out}).


-spec await_connect(pid()) -> 
  {ok, integer(), map()} | {abort, map(), atom()} | {error, term()}.
await_connect(ServerPid) ->
  MRef = monitor(process, ServerPid),
  Res = await_connect(ServerPid, 5000, MRef),
  demonitor(MRef, [flush]),
  Res.

-spec await_connect(pid(), reference() | timeout()) -> 
  {ok, integer(), map()} | {abort, map(), atom()} | {error, term()}.
await_connect(ServerPid, MRef) when is_reference(MRef) ->
  await_connect(ServerPid, 5000, MRef);
await_connect(ServerPid, Timeout) ->
  MRef = monitor(process, ServerPid),
  Res = await_connect(ServerPid, Timeout, MRef),
  demonitor(MRef, [flush]),
  Res.

-spec await_connect(pid(), timeout(), reference()) -> 
  {ok, integer(), map()} | {abort, map(), atom()} | {error, term()}.
await_connect(ServerPid, Timeout, MRef) ->
  receive
    {awre_welcome, SessionId, RouterDetails} -> 
      {ok, SessionId, RouterDetails};
    {awre_abort, Details, Reason} -> 
      {abort, Details, Reason};
    {'DOWN', MRef, process, ServerPid, Reason} ->
      {error, Reason}
  after Timeout ->
    {error, timeout}
  end.

%% @doc Subscribe to an event.
%% subscribe to the event Topic.
%% On an event the Mfa wil be called as:
%% Module:Function(Details, Arguments, ArgumentsKw, Argument),
%% the last Argument will be the one from the Mfa, given at subscription time.
-spec subscribe(ConPid :: pid(), Options :: list(), Topic :: binary(), Mfa :: {atom,atom,any()} | undefined) -> {ok,SubscriptionId :: non_neg_integer()}.
subscribe(ConPid,Options,Topic,Mfa) ->
  gen_server:call(ConPid,{awre_call,{subscribe,Options,Topic,Mfa}}).


%% @doc Subscribe to an event.
-spec subscribe(ConPid :: pid(), Options :: list(), Topic :: binary()) -> {ok,SubscriptionId :: non_neg_integer()}.
subscribe(ConPid,Options,Topic) ->
  subscribe(ConPid,Options,Topic,undefined).


%% @doc Unsubscribe from an event.
-spec unsubscribe(ConPid :: pid(), SubscriptionId :: non_neg_integer()) -> ok.
unsubscribe(ConPid,SubscriptionId) ->
  gen_server:call(ConPid,{awre_call,{unsubscribe,SubscriptionId}}).

%% @doc Publish an event.
-spec publish(ConPid :: pid(), Options :: list(), Topic :: binary()) -> ok.
publish(ConPid,Options,Topic) ->
  publish(ConPid,Options,Topic,undefined,undefined).

%% @doc Publish an event.
-spec publish(ConPid :: pid(), Options :: list(), Topic :: binary(), Arguments :: list() | undefined) -> ok.
publish(ConPid,Options,Topic,Arguments)->
  publish(ConPid,Options,Topic,Arguments,undefined).

%% @doc Publish an event.
-spec publish(ConPid :: pid(), Options :: list(), Topic :: binary(), Arguments :: list() | undefined, ArgumentsKw :: list() | undefined) -> ok.
publish(ConPid,Options,Topic,Arguments,ArgumentsKw) ->
  gen_server:call(ConPid,{awre_call,{publish,Options,Topic,Arguments,ArgumentsKw}}).

%% @doc Register a remote procedure.
-spec register(ConPid :: pid(), Options :: list(), Procedure :: binary()) -> {ok, RegistrationId :: non_neg_integer() }.
register(ConPid,Options,Procedure) ->
  register(ConPid,Options,Procedure,undefined).

%% @doc Register a remote procedure.
-spec register(ConPid :: pid(), Options :: list(), Procedure :: binary(), Mfa :: {atom,atom,any()}|undefined) -> {ok, RegistrationId :: non_neg_integer() }.
register(ConPid,Options,Procedure,Mfa) ->
  gen_server:call(ConPid,{awre_call,{register,Options,Procedure,Mfa}}).

%% @doc Unregister a remote procedure.
-spec unregister(ConPid :: pid(), RegistrationId :: non_neg_integer()) -> ok.
unregister(ConPid,RegistrationId) ->
  gen_server:call(ConPid,{awre_call,{unregister, RegistrationId}}).


%% @doc Call a remote procedure.
-spec call(ConPid :: pid(), Options :: list(), ProcedureUrl :: binary()) -> {ok, Details :: list(), ResA :: list() | undefined, ResAKw :: list() | undefined}.
call(ConPid,Options,ProcedureUrl) ->
  call(ConPid,Options,ProcedureUrl,undefined,undefined).

%% @doc Call a remote procedure.
-spec call(ConPid :: pid(), Options :: list(), ProcedureUrl :: binary(), Arguments::list()) -> {ok, Details :: list(), ResA :: list() | undefined, ResAKw :: list() | undefined}.
call(ConPid,Options,ProcedureUrl,Arguments) ->
  call(ConPid,Options,ProcedureUrl,Arguments,undefined).

%% @doc Call a remote procedure.
-spec call(ConPid :: pid(), Options :: list(), ProcedureUrl :: binary(), Arguments::list() | undefined , ArgumentsKw :: list() | undefined) -> {ok, Details :: list(), ResA :: list() | undefined, ResAKw :: list() | undefined}.
call(ConPid,Options,ProcedureUrl,Arguments,ArgumentsKw) ->
  gen_server:call(ConPid,{awre_call,{call,Options,ProcedureUrl,Arguments,ArgumentsKw}}).


%% @doc Return the result to a call.
-spec yield(ConPid :: pid(), RequestId :: non_neg_integer(), Details :: list() ) -> ok.
yield(ConPid,RequestId,Details) ->
  yield(ConPid,RequestId,Details,undefined,undefined).

%% @doc Return the result to a call.
-spec yield(ConPid :: pid(), RequestId :: non_neg_integer(), Details :: list(), Arguments :: list() ) -> ok.
yield(ConPid,RequestId,Details,Arguments) ->
  yield(ConPid,RequestId,Details,Arguments,undefined).

%% @doc Return the result to a call.
-spec yield(ConPid :: pid(), RequestId :: non_neg_integer(), Details :: list(), Arguments :: list() | undefined, ArgumentsKw :: list() | undefined ) -> ok.
yield(ConPid,RequestId,Details,Arguments,ArgumentsKw) ->
  gen_server:call(ConPid,{awre_call,{yield,RequestId,Details,Arguments,ArgumentsKw}}).

%% @doc Return an error from a call.
error(ConPid,RequestId,ErrorType,Reason,ErrorUri) ->
  ReasonStr = iolist_to_binary(io_lib:format("~p:~p",[ErrorType,Reason])),
  StackTraceStr = iolist_to_binary(io_lib:format("~p", [erlang:get_stacktrace()])),
  ArgsKw = #{<<"reason">> => ReasonStr,
            <<"stacktrace">> => StackTraceStr},
  gen_server:call(ConPid, {awre_call,{error,invocation,RequestId,ArgsKw,ErrorUri}}).
