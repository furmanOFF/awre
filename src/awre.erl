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
-export([start_client/0]).
-export([stop_client/1,stop_client/3]).

-export([connect/2]).
-export([connect/4, connect/5]).

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



%% connecting to a (remote) router (for peer)

%% @doc start a connection server to handle a connection to a router.
%% The connection can be either remote or local within the VM.
-spec start_client() -> {ok,Con :: pid()}.
start_client() ->
  supervisor:start_child(awre_sup,[[]]).

%% @doc stop the given connection
%% TODO: implement
-spec stop_client(ConPid :: pid(),Details :: list(),Reason :: binary()) -> ok.
stop_client(ConPid,Details,Reason) ->
  gen_server:cast(ConPid,{shutdown,Details,Reason}).

-spec stop_client(ConPid :: pid()) -> ok.
stop_client(ConPid) ->
  gen_server:cast(ConPid,{shutdown,#{},goodbye_and_out}).

%% @doc Connect to a router in the VM.
%% The connection will be established to the local router in the VM.
-spec connect(ConPid :: pid(), Realm :: binary()) -> {ok, SessionId :: non_neg_integer(), RouterDetails :: list()}.
connect(ConPid, Realm) ->
  gen_server:call(ConPid,{awre_call, {connect, undefined, Realm, undefined}}).

%% @doc connect to a remote router.
%% Connect to the router at the given uri Uri to the realm Realm.
%% The connection will be established by using the encoding Encoding for serialization.
-spec connect(ConPid :: pid(), Uri :: string(), Realm :: binary(), Encoding :: raw_json | raw_msgpack) -> 
  {ok, SessionId :: non_neg_integer(), RouterDetails :: list()}.
connect(ConPid, Uri, Realm, Encoding) ->
  gen_server:call(ConPid, {awre_call, {connect, Uri, Realm, Encoding}}).

%% Connect to the router at the given host Host on port Port to the realm Realm.
%% The connection will be established by using the encoding Encoding for serialization.
-spec connect(ConPid :: pid(), Host :: string(), Port :: non_neg_integer(), Realm :: binary(), Encoding :: raw_json | raw_msgpack) -> 
  {ok, SessionId :: non_neg_integer(), RouterDetails :: list()}.
connect(ConPid, Host, Port, Realm, Encoding) ->
  gen_server:call(ConPid,{awre_call, {connect, {Host, Port}, Realm, Encoding}}).


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
