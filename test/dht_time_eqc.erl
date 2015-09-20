-module(dht_time_eqc).
-compile(export_all).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_component.hrl").

-type time() :: integer().
-type time_ref() :: integer().

-record(state, {
	time = 0 :: time(),
	timers = [] :: [{time(), {time_ref(), term(), term()}}],
	time_ref = 0 :: time_ref()
}).

api_spec() ->
    #api_spec {
      language = erlang,
      modules = [
        #api_module {
          name = dht_time,
          functions = [
            #api_fun { name = convert_time_unit, arity = 3 },
            #api_fun { name = monotonic_time, arity = 0 },
            #api_fun { name = send_after, arity = 3 },
            #api_fun { name = cancel_timer, arity = 1 }
          ]}
      ]
    }.
    
gen_initial_state() ->
    #state { time = int() }.

initial_state() -> #state{}.

%% ADVANCING TIME
%% ------------------------------------

advance_time(_Advance) -> ok.
advance_time_args(_S) ->
    T = frequency([
        {10, ?LET(K, nat(), K+1)},
        {10, ?LET({K, N}, {nat(), nat()}, (N+1)*1000 + K)},
        {10, ?LET({K, N, M}, {nat(), nat(), nat()}, (M+1)*60*1000 + N*1000 + K)},
        {1, ?LET({K, N, Q}, {nat(), nat(), nat()}, (Q*17)*60*1000 + N*1000 + K)}
    ]),
    [T].

%% Advancing time transitions the system into a state where the time is incremented
%% by A.
advance_time_next(#state { time = T } = State, _, [A]) -> State#state { time = T+A }.
advance_time_return(_S, [_]) -> ok.

advance_time_features(_S, _, _) -> [{dht_time, advance_time}].

%% TRIGGERING OF TIMERS
%% ------------------------------------
%%
%% This is to be used by another component as:
%% ?APPLY(dht_time, trigger, []) in a callout specification. This ensures the given command can
%% only be picked if you can trigger the timer.

can_fire(#state { time = T, timers = TS }, Ref) ->
     case lists:keyfind(Ref, 2, TS) of
         false -> false;
         {TP, _, _, _} -> T >= TP
     end.
   
trigger_pre(S, [{tref, Ref}]) -> can_fire(S, Ref).
    
trigger_return(#state { timers = TS }, [{tref, Ref}]) ->
    case lists:keyfind(Ref, 2, TS) of
        {_TP, _Ref, _Pid, Msg} -> Msg
    end.
    
trigger_next(#state { timers = TS } = S, _, [{tref, Ref}]) ->
    S#state{ timers = lists:keydelete(Ref, 2, TS) }.

can_fire_msg(#state { time = T, timers = TS }, Msg) ->
    case lists:keyfind(Msg, 4, TS) of
        false -> false;
        {TP, _, _, _} -> T >= TP
    end.
    
trigger_msg_pre(S, [Msg]) -> can_fire_msg(S, Msg).
trigger_msg_return(_S, [Msg]) -> Msg.
    
trigger_msg_next(#state { timers = TS } = S, _, [Msg]) ->
    {_, Ref, _, _} = lists:keyfind(Msg, 4, TS),
    S#state{ timers = lists:keydelete(Ref, 2, TS) }.

%% INTERNAL CALLS IN THE MODEL
%% -------------------------------------------
%%
%% All these calls are really "wrappers" such that if you call into the timing model, you obtain
%% faked time.

monotonic_time_callers() -> [dht_routing_meta_eqc, dht_routing_table_eqc, dht_state_eqc].

monotonic_time_callouts(#state {time = T }, []) ->
    ?CALLOUT(dht_time, monotonic_time, [], T),
    ?RET(T).

monotonic_time_return(#state { time = T }, []) -> T.

convert_time_unit_callers() -> [dht_routing_meta_eqc, dht_routing_table_eqc, dht_state_eqc].

convert_time_unit_callouts(_S, [T, From, To]) ->
    ?CALLOUT(dht_time, convert_time_unit, [T, From, To], T),
    case {From, To} of
        {native, milli_seconds} -> ?RET(T);
        {milli_seconds, native} -> ?RET(T);
        FT -> ?FAIL({convert_time_unit, FT})
    end.

send_after_callers() -> [dht_routing_meta_eqc, dht_routing_table_eqc, dht_state_eqc, dht_net_eqc].

send_after_callouts(#state { time_ref = Ref}, [Timeout, Reg, Msg]) when is_atom(Reg) ->
    ?CALLOUT(dht_time, send_after, [Timeout, Reg, Msg], {tref, Ref}),
    ?RET({tref, Ref});
send_after_callouts(#state { time_ref = Ref}, [Timeout, Pid, Msg]) when is_pid(Pid) ->
    ?CALLOUT(dht_time, send_after, [Timeout, ?WILDCARD, Msg], {tref, Ref}),
    ?RET({tref, Ref}).

send_after_next(#state { time = T, time_ref = Ref, timers = TS } = S, _, [Timeout, Pid, Msg]) ->
    TriggerPoint = T + Timeout,
    S#state { time_ref = Ref + 1, timers = TS ++ [{TriggerPoint, Ref, Pid, Msg}] }.

cancel_timer_callers() -> [dht_routing_meta_eqc, dht_net].

cancel_timer_callouts(S, [{tref, TRef}]) ->
    Return = cancel_timer_rv(S, TRef),
    ?CALLOUT(dht_time, cancel_timer, [{tref, TRef}], Return),
    ?RET(Return).

cancel_timer_rv(#state { time = T, timers = TS }, TRef) ->
    case lists:keyfind(TRef, 2, TS) of
        false -> false;
        {TriggerPoint, TRef, _Pid, _Msg} -> monus(TriggerPoint, T)
    end.

cancel_timer_next(#state { timers = TS } = S, _, [{tref, TRef}]) ->
    S#state { timers = lists:keydelete(TRef, 2, TS) }.

%% HELPER ROUTINES
%% ----------------------------------------

%% A monus operation is a subtraction for natural numbers
monus(A, B) when A > B -> A - B;
monus(A, B) when A =< B -> 0.

%% PROPERTY
%% ----------------------------------

%% The property here is a pretty dummy property as we don't need a whole lot for this to work.

%% Use a common postcondition for all commands, so we can utilize the valid return
%% of each command.
postcondition_common(S, Call, Res) ->
    eq(Res, return_value(S, Call)).

%% Main property, just verify that the commands are in sync with reality.
prop_component_correct() ->
    ?SETUP(fun() ->
        eqc_mocking:start_mocking(api_spec()),
        fun() -> ok end
    end,
    ?FORALL(St, gen_initial_state(),
    ?FORALL(Cmds, commands(?MODULE, St),
      begin
        {H,S,R} = run_commands(?MODULE, Cmds),
        pretty_commands(?MODULE, Cmds, {H,S,R},
            aggregate(with_title('Commands'), command_names(Cmds),
            collect(eqc_lib:summary('Length'), length(Cmds),
            aggregate(with_title('Features'), eqc_statem:call_features(H),
            features(eqc_statem:call_features(H),
                R == ok)))))
      end))).

%% Helper for showing states of the output:
t() -> t(5).

t(Secs) ->
    eqc:quickcheck(eqc:testing_time(Secs, eqc_statem:show_states(prop_component_correct()))).