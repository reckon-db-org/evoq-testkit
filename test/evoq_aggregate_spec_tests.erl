%%% @doc Tests for evoq_aggregate_spec (Layer A — the pure CMD spec).
%%%
%%% Uses a tiny lamp aggregate (off -> on -> off, refuses illegal
%%% transitions) to exercise the four assertions, both forms, and the
%%% failure modes — the spec itself MUST fail loudly when an expectation is
%%% violated, otherwise it gives false confidence.
-module(evoq_aggregate_spec_tests).
-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Aggregate under test: a lamp. This module also implements the
%% evoq_aggregate-shaped callbacks the pure spec uses (init/1,
%% execute/2, apply/2). State = #{on => boolean()}.
%%====================================================================

-define(AGG, ?MODULE).

init(_AggId) -> {ok, #{on => false}}.

execute(#{on := false}, #{command_type := <<"turn_on">>}) ->
    {ok, [#{event_type => <<"lamp_turned_on">>}]};
execute(#{on := true}, #{command_type := <<"turn_on">>}) ->
    {error, already_on};
execute(#{on := true}, #{command_type := <<"turn_off">>}) ->
    {ok, [#{event_type => <<"lamp_turned_off">>}]};
execute(#{on := false}, #{command_type := <<"turn_off">>}) ->
    {error, already_off};
execute(_State, #{command_type := Other}) ->
    {error, {unknown_command, Other}}.

apply(State, #{event_type := <<"lamp_turned_on">>})  -> State#{on := true};
apply(State, #{event_type := <<"lamp_turned_off">>}) -> State#{on := false};
apply(State, _)                                       -> State.

is_on(#{on := V}) -> V.

%%====================================================================
%% Tuple-list form
%%====================================================================

tuple_happy_path_test() ->
    ok = evoq_aggregate_spec:run(?AGG, <<"lamp-1">>, [
        {turn_on,  #{}, evoq_aggregate_spec:expect([<<"lamp_turned_on">>]),
                        fun is_on/1},
        {turn_off, #{}, evoq_aggregate_spec:expect([<<"lamp_turned_off">>]),
                        fun(S) -> not is_on(S) end}
    ]).

tuple_expected_error_test() ->
    ok = evoq_aggregate_spec:run(?AGG, <<"lamp-1">>, [
        {turn_off, #{}, evoq_aggregate_spec:expect_error(already_off),
                        evoq_aggregate_spec:unchanged()}
    ]).

tuple_state_threads_across_steps_test() ->
    %% turn_on, then turn_on again must be rejected — proves state from
    %% step 1 reaches step 2.
    ok = evoq_aggregate_spec:run(?AGG, <<"lamp-1">>, [
        {turn_on, #{}, evoq_aggregate_spec:expect([<<"lamp_turned_on">>]), fun is_on/1},
        {turn_on, #{}, evoq_aggregate_spec:expect_error(already_on),
                       evoq_aggregate_spec:unchanged()}
    ]).

%%====================================================================
%% Builder form
%%====================================================================

builder_happy_path_test() ->
    S0 = evoq_aggregate_spec:new(?AGG, <<"lamp-1">>),
    S1 = evoq_aggregate_spec:emits(
           evoq_aggregate_spec:exec(S0, turn_on, #{}),
           [<<"lamp_turned_on">>]),
    S2 = evoq_aggregate_spec:state(S1, fun is_on/1),
    S3 = evoq_aggregate_spec:fails_with(
           evoq_aggregate_spec:exec(S2, turn_on, #{}),
           already_on),
    ok = evoq_aggregate_spec:done(S3).

builder_emits_nothing_form_compiles_test() ->
    %% Lamp always emits on a valid command, so just check the API exists
    %% and that an unmatched expectation (events vs none) is caught.
    ?assertError({event_mismatch, _},
        begin
            S0 = evoq_aggregate_spec:new(?AGG, <<"lamp-1">>),
            evoq_aggregate_spec:emits_nothing(
                evoq_aggregate_spec:exec(S0, turn_on, #{}))
        end).

%%====================================================================
%% The spec must FAIL when an expectation is violated
%%====================================================================

wrong_event_is_caught_test() ->
    ?assertError({event_mismatch, _},
        evoq_aggregate_spec:run(?AGG, <<"lamp-1">>, [
            {turn_on, #{}, evoq_aggregate_spec:expect([<<"wrong_event">>]),
                           evoq_aggregate_spec:unchanged()}
        ])).

unexpected_extra_event_is_caught_test() ->
    %% Expected [] but turn_on emits one event — exact match catches it.
    ?assertError({event_mismatch, _},
        evoq_aggregate_spec:run(?AGG, <<"lamp-1">>, [
            {turn_on, #{}, evoq_aggregate_spec:expect([]),
                           evoq_aggregate_spec:unchanged()}
        ])).

unexpected_failure_is_caught_test() ->
    %% Expected an event, but the command was rejected.
    ?assertError({expected_events_got_error, _},
        evoq_aggregate_spec:run(?AGG, <<"lamp-1">>, [
            {turn_off, #{}, evoq_aggregate_spec:expect([<<"lamp_turned_off">>]),
                            evoq_aggregate_spec:unchanged()}
        ])).

wrong_error_reason_is_caught_test() ->
    ?assertError({wrong_error, _},
        evoq_aggregate_spec:run(?AGG, <<"lamp-1">>, [
            {turn_off, #{}, evoq_aggregate_spec:expect_error(some_other_reason),
                            evoq_aggregate_spec:unchanged()}
        ])).

bad_state_predicate_is_caught_test() ->
    ?assertError({state_predicate_failed, _},
        evoq_aggregate_spec:run(?AGG, <<"lamp-1">>, [
            {turn_on, #{}, evoq_aggregate_spec:expect([<<"lamp_turned_on">>]),
                           fun(S) -> not is_on(S) end}
        ])).

unasserted_command_is_caught_test() ->
    %% exec twice without an assertion between → error.
    S0 = evoq_aggregate_spec:new(?AGG, <<"lamp-1">>),
    S1 = evoq_aggregate_spec:exec(S0, turn_on, #{}),
    ?assertError({unasserted_command, _},
                 evoq_aggregate_spec:exec(S1, turn_off, #{})).

done_with_unasserted_command_is_caught_test() ->
    S0 = evoq_aggregate_spec:new(?AGG, <<"lamp-1">>),
    S1 = evoq_aggregate_spec:exec(S0, turn_on, #{}),
    ?assertError({unasserted_command, _}, evoq_aggregate_spec:done(S1)).

%%====================================================================
%% given_events seeds state
%%====================================================================

given_events_seeds_state_test() ->
    %% Pretend the lamp is already on; turn_on must then be rejected.
    S0 = evoq_aggregate_spec:given_events(
           evoq_aggregate_spec:new(?AGG, <<"lamp-1">>),
           [#{event_type => <<"lamp_turned_on">>}]),
    S1 = evoq_aggregate_spec:fails_with(
           evoq_aggregate_spec:exec(S0, turn_on, #{}), already_on),
    ok = evoq_aggregate_spec:done(S1).
