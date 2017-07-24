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

%% @private
-module(awre_con).
-behaviour(gen_server).

%% API.
-export([start_link/4]).

%% gen_server
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-define(CLIENT_DETAILS, #{
  callee => #{features => #{}},
  caller => #{features => #{}},
  publisher => #{features => #{}},
  subscriber => #{features => #{}}
}).

-record(state, {
  ets = undefined,
  owner :: pid(),
  monitor :: pid(),
  goodbye_sent = false,
  transport = {none,none},
  subscribe_id=1,
  unsubscribe_id=1,
  publish_id=1,
  register_id=1,
  unregister_id=1,
  call_id=1
}).

-record(ref, {
  key = {none, none},
  req = undefined,
  method = undefined,
  ref= undefined,
  args = []
}).

-record(subscription,{
  id = undefined,
  mfa = undefined,
  pid=undefined
}).

-record(registration,{
  id = undefined,
  mfa = undefined,
  pid = undefined
}).

%% API
-spec start_link(Pid :: pid(), Uri :: string() | {inet:hostname(), inet:port_number()}, Realm::binary(), Opts::#{}) -> {ok, pid()}.
start_link(Pid, Uri, Realm, Opts) when is_binary(Realm) ->
  gen_server:start_link(?MODULE, {Pid, Uri, Realm, Opts}, []).

%% gen_server
init({Pid, Uri, Realm, Opts}) ->
  {Trans, TState} = awre_transport:init(#{
    awre_con => self(), uri => Uri, realm => Realm, options => Opts,
    version => awre:get_version(), client_details => ?CLIENT_DETAILS
  }),
  Ref = monitor(process, Pid),
  {ok, #state{
    ets = ets:new(con_data, [set, protected, {keypos, 2}]),
    owner = Pid,
    monitor = Ref,
    transport = {Trans, TState}
  }}.

handle_call({awre_call, Msg}, From, State) ->
  handle_message_from_client(Msg, From, State);
handle_call(Msg, _From, State) ->
  error_logger:warning_msg("unexpected call: ~w~n", [Msg]),
  {noreply, State}.

handle_cast({shutdown, Details, Reason}, #state{goodbye_sent=GS,transport= {TMod,TState}}=State) ->
  NewState = case GS of
  true ->
    State;
  false ->
    {ok,NewTState} = TMod:send_to_router({goodbye,Details,Reason},TState),
    State#state{transport={TMod,NewTState}}
  end,
  {noreply,NewState#state{goodbye_sent=true}};
handle_cast(Msg, State) ->
  error_logger:warning_msg("cast: ~w~n", [Msg]),
	{noreply, State}.

handle_info(Data,#state{transport = {T,TState}} = State) ->
  case T:handle_info(Data, TState) of
    {noreply, NewTState} ->
      {noreply, State#state{transport={T, NewTState}}};
    {reply, Reply, NewTState} ->
      handle_reply(Reply, State#state{transport={T, NewTState}});
    {stop, Reason, Reply, NewTState1} ->
      NewTState2 = case handle_reply(Reply, State#state{transport={T, NewTState1}}) of
        {_, S} -> S;
        {_, _, S} -> S
      end,
      {stop, Reason, State#state{transport={T, NewTState2}}};
    {stop, Reason, NewTState} ->
      {stop, Reason, State#state{transport={T, NewTState}}}
  end;
handle_info({'DOWN', _Ref, process, _Owner, Reason}, S=#state{monitor=_Ref}) ->
    {stop, {owner_gone, Reason}, S#state{monitor=undefined, owner=undefined}};
handle_info(Info, State) ->
  error_logger:warning_msg("info: ~w~n", [Info]),
	{noreply, State}.

terminate(_Reason, #state{transport={TMod, TState}}) ->
  ok = TMod:shutdown(TState).

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%
handle_message_from_client({subscribe,Options,Topic,Mfa}, {Pid, _}, State) ->
  {RequestId, NewState} = send_and_ref({subscribe, request_id, Options, Topic}, Pid, #{mfa => Mfa}, State),
  {reply, {ok, RequestId}, NewState};
handle_message_from_client({unsubscribe, SubscriptionId}, {Pid, _}, State) ->
  {RequestId, NewState} = send_and_ref({unsubscribe, request_id, SubscriptionId}, Pid, #{sub_id=>SubscriptionId}, State),
  {reply, {ok, RequestId}, NewState};
handle_message_from_client({publish, Options, Topic, Arguments, ArgumentsKw}, {Pid, _}, State) ->
  {RequestId, NewState} = send_and_ref({publish, request_id, Options, Topic, Arguments, ArgumentsKw}, Pid, #{}, State),
  {reply, {ok, RequestId}, NewState};
handle_message_from_client({register, Options, Procedure, Mfa}, {Pid, _}, State) ->
  {RequestId, NewState} = send_and_ref({register, request_id, Options, Procedure}, Pid, #{mfa=>Mfa}, State),
  {reply, {ok, RequestId}, NewState};
handle_message_from_client({unregister, RegistrationId}, {Pid, _}, State) ->
  {RequestId, NewState} = send_and_ref({unregister, request_id, RegistrationId}, Pid, #{reg_id => RegistrationId}, State),
  {reply, {ok, RequestId}, NewState};
handle_message_from_client({call,Options,Procedure,Arguments,ArgumentsKw}, {Pid, _}, State) ->
  {RequestId, NewState} = send_and_ref({call, request_id, Options, Procedure, Arguments, ArgumentsKw}, Pid, #{}, State),
  {reply, {ok, RequestId}, NewState};
handle_message_from_client({yield,_,_,_,_}=Msg, _From, State) ->
  {ok, NewState} = send_to_router(Msg,State),
  {reply, ok, NewState};
handle_message_from_client({error,invocation,RequestId,ArgsKw,ErrorUri}, _From, State) ->
  {ok, NewState} = send_to_router({error, invocation, RequestId, #{}, ErrorUri, [], ArgsKw}, State),
  {reply, ok, NewState}.

%% handle Messages from transport one by one
handle_reply([Msg|T], State) ->
  case handle_message_from_router(Msg, State) of
    {ok, NewState} ->
      handle_reply(T, NewState);
    {stop, Reason, State} ->
      {stop, Reason, State}
  end;
handle_reply([], State) ->
  {noreply, State}.

handle_message_from_router({welcome, SessionId, RouterDetails}, S=#state{owner=Pid}) ->
  Pid ! {awre_welcome, self(), SessionId, RouterDetails},
  {ok, S};
handle_message_from_router({abort, Details, Reason}, S=#state{owner=Pid}) ->
  Pid ! {awre_abort, self(), Details, Reason},
  {stop, Reason, S};
handle_message_from_router({stop, _, Reason}, State) ->
  {stop, Reason, State};
handle_message_from_router({goodbye,_Details,_Reason},#state{goodbye_sent=GS}=State) ->
  NewState = case GS of
    true -> 
      State;
    false ->
      {ok,NState} = send_to_router({goodbye,[],goodbye_and_out},State),
      NState
  end,
  {stop, normal, NewState};

handle_message_from_router({subscribed, RequestId, SubscriptionId}, #state{ets=Ets}=State) ->
  {Pid, Args} = get_ref(subscribe, RequestId, State),
  Mfa = maps:get(mfa,Args),
  ets:insert_new(Ets,#subscription{id=SubscriptionId,mfa=Mfa,pid=Pid}),
  Pid ! {awre_subscribed, self(), RequestId, SubscriptionId},
  {ok, State};
handle_message_from_router({unsubscribed, RequestId}, #state{ets=Ets}=State) ->
  {Pid, Args} = get_ref(unsubscribe, RequestId, State),
  SubscriptionId = maps:get(sub_id, Args),
  ets:delete(Ets, SubscriptionId),
  Pid ! {awre_unsubscribed, self(), RequestId},
  {ok, State};

handle_message_from_router({event,SubscriptionId,PublicationId,Details},State) ->
  handle_message_from_router({event,SubscriptionId,PublicationId,Details,undefined,undefined},State);
handle_message_from_router({event,SubscriptionId,PublicationId,Details,Arguments},State) ->
  handle_message_from_router({event,SubscriptionId,PublicationId,Details,Arguments,undefined},State);
handle_message_from_router({event,SubscriptionId,PublicationId,Details,Arguments,ArgumentsKw}, #state{ets=Ets}=State) ->
  [#subscription{
    id = SubscriptionId,
    mfa = Mfa,
    pid = Pid
  }] = ets:lookup(Ets, SubscriptionId),
  case Mfa of
    undefined ->
      % send it to user process
      Pid ! {awre_event, self(), SubscriptionId, PublicationId, Details, Arguments, ArgumentsKw};
    {M,F,S}  ->
      try
        erlang:apply(M,F,[Details,Arguments,ArgumentsKw,S])
      catch
        Error:Reason -> 
          Pid ! {awre_event_error, self(), Error, Reason, erlang:get_stacktrace()}
      end
  end,
  {ok, State};
handle_message_from_router({result,RequestId,Details},State) ->
  handle_message_from_router({result,RequestId,Details,undefined,undefined},State);
handle_message_from_router({result,RequestId,Details,Arguments},State) ->
  handle_message_from_router({result,RequestId,Details,Arguments,undefined},State);
handle_message_from_router({result,RequestId,Details,Arguments,ArgumentsKw},State) ->
  {Pid, _} = get_ref(call, RequestId, State),
  Pid ! {awre_result, self(), RequestId, Details, Arguments, ArgumentsKw},
  {ok, State};

handle_message_from_router({registered,RequestId,RegistrationId},#state{ets=Ets}=State) ->
  {Pid, Args} = get_ref(register, RequestId, State),
  Mfa = maps:get(mfa,Args),
  ets:insert_new(Ets,#registration{id=RegistrationId, mfa=Mfa, pid=Pid}),
  Pid ! {awre_registered, self(), RequestId, RegistrationId},
  {ok, State};

handle_message_from_router({unregistered,RequestId},#state{ets=Ets}=State) ->
  {Pid, Args} = get_ref(unregister, RequestId,State),
  RegistrationId = maps:get(reg_id,Args),
  ets:delete(Ets,RegistrationId),
  Pid ! {awre_unregistered, self(), RequestId},
  {ok, State};

handle_message_from_router({invocation,RequestId,RegistrationId,Details},State) ->
  handle_message_from_router({invocation,RequestId,RegistrationId,Details,undefined,undefined},State);
handle_message_from_router({invocation,RequestId,RegistrationId,Details,Arguments},State) ->
  handle_message_from_router({invocation,RequestId,RegistrationId,Details,Arguments,undefined},State);
handle_message_from_router({invocation,RequestId,RegistrationId,Details,Arguments,ArgumentsKw}, #state{ets=Ets}=State) ->
  [#registration{
    id = RegistrationId,
    mfa = Mfa,
    pid=Pid}] = ets:lookup(Ets,RegistrationId),
  NewState = case Mfa of
   undefined ->
      % send it to the user process
      Pid ! {awre_invocation, self(), RequestId, RegistrationId, Details, Arguments, ArgumentsKw},
      State;
    {M,F,S}  ->
      try erlang:apply(M,F,[Details,Arguments,ArgumentsKw,S]) of
        {ok,Options,ResA,ResAKw} ->
          {ok, NState} = send_to_router({yield,RequestId,Options,ResA,ResAKw},State),
          NState;
        {error,Details,Uri,Arguments,ArgumentsKw} ->
          {ok, NState} = send_to_router({error,invocation,RequestId,Details,Uri,Arguments,ArgumentsKw},State),
          NState;
        Other ->
          {ok, NState} = send_to_router({error,invocation,RequestId,#{<<"result">> => Other },invalid_argument,undefined,undefined},State),
          NState
      catch
        Error:Reason ->
          {ok, NState} = send_to_router({error,invocation,RequestId,#{<<"reason">> => io_lib:format("~p:~p",[Error,Reason])},invalid_argument,undefined,undefined},State),
          NState
      end
  end,
  {ok, NewState};

handle_message_from_router({error,call,RequestId,Details,Error},State) ->
  handle_message_from_router({error,call,RequestId,Details,Error,undefined,undefined},State);
handle_message_from_router({error,call,RequestId,Details,Error,Arguments},State) ->
  handle_message_from_router({error,call,RequestId,Details,Error,Arguments,undefined},State);
handle_message_from_router({error,call,RequestId,Details,Error,Arguments,ArgumentsKw},State) ->
  {Pid, _} = get_ref(call, RequestId, State),
  Pid ! {awre_error, self(), RequestId, Details, Error, Arguments, ArgumentsKw},
  {ok, State}.

%
% Session Scope IDs
%
%     ERROR.Request
%     PUBLISH.Request
%     PUBLISHED.Request
%     SUBSCRIBE.Request
%     SUBSCRIBED.Request
%     UNSUBSCRIBE.Request
%     UNSUBSCRIBED.Request
%     CALL.Request
%     CANCEL.Request
%     RESULT.Request
%     REGISTER.Request
%     REGISTERED.Request
%     UNREGISTER.Request
%     UNREGISTERED.Request
%     INVOCATION.Request
%     INTERRUPT.Request
%     YIELD.Request
%
% IDs in the session scope SHOULD be incremented by 1 beginning with 1
% (for each direction - Client-to-Router and Router-to-Client)
%

send_and_ref(Msg, Pid, Args, State0) ->
  Method = element(1, Msg),
  {RequestId, State1} = request_id(Method, State0),
  set_ref(Method, RequestId, Pid, Args, State1),
  {ok, State2} = send_to_router(setelement(2, Msg, RequestId), State1),
  {RequestId, State2}.

send_to_router(Msg, State=#state{transport={TMod,TState0}}) ->
  {ok, TState1} = TMod:send_to_router(Msg, TState0),
  {ok, State#state{transport={TMod, TState1}}}.

request_id(subscribe, State) ->
      Id = State#state.subscribe_id,
      {Id, State#state{subscribe_id = Id+1}};
request_id(unsubscribe, State) ->
      Id = State#state.unsubscribe_id,
      {Id, State#state{unsubscribe_id = Id+1}};
request_id(publish, State) ->
      Id = State#state.publish_id,
      {Id, State#state{publish_id = Id+1}};
request_id(register, State) ->
      Id = State#state.register_id,
      {Id, State#state{register_id = Id+1}};
request_id(unregister, State) ->
      Id = State#state.unregister_id,
      {Id, State#state{unregister_id = Id+1}};
request_id(call, State) ->
      Id = State#state.call_id,
      {Id, State#state{call_id = Id+1}}.

set_ref(Method, RequestId, Pid, Args, #state{ets=Ets}) ->
  true = ets:insert_new(Ets, #ref{key={Method, RequestId}, ref=Pid, args=Args}).

get_ref(Method, ReqId, #state{ets=Ets}) ->
  Key = {Method, ReqId},
  [#ref{ref=Pid, args=Args}] = ets:lookup(Ets, Key),
  ets:delete(Ets, Key),
  {Pid, Args}.
