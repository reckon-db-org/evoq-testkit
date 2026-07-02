%%% @doc Tests for evoq_cmd_case (Layer B — persistence via mem-evoq).
%%%
%%% Drive a real `lamp_aggregate' through the real `evoq_command_router' against
%%% the in-memory mem-evoq adapter, then read the stream back. These prove the
%%% events actually PERSIST — the half Layer A cannot see.
-module(evoq_cmd_case_tests).
-include_lib("eunit/include/eunit.hrl").

sid(Name) -> lamp_aggregate:stream_id(Name).

%%====================================================================
%% Happy path: dispatch a sequence, the events land in order
%%====================================================================

dispatch_persists_events_test() ->
    evoq_cmd_case:with_mem_store(fun(StoreId) ->
        Sid = sid(<<"lamp-a">>),
        Scenario = [{turn_on, #{}}, {turn_off, #{}}, {turn_on, #{}}],
        ok = evoq_cmd_case:dispatch_all(lamp_aggregate, Sid, Scenario, StoreId),
        evoq_cmd_case:assert_stream(StoreId, Sid,
            [<<"lamp_turned_on">>, <<"lamp_turned_off">>, <<"lamp_turned_on">>])
    end).

%% The SAME 4-tuple scenario Layer A uses also drives Layer B (the pure
%% assertion slots are ignored here).
shared_scenario_shape_test() ->
    evoq_cmd_case:with_mem_store(fun(StoreId) ->
        Sid = sid(<<"lamp-shared">>),
        Scenario = [
            {turn_on,  #{}, evoq_aggregate_spec:expect([<<"lamp_turned_on">>]),
                            fun lamp_aggregate:is_on/1},
            {turn_off, #{}, evoq_aggregate_spec:expect([<<"lamp_turned_off">>]),
                            evoq_aggregate_spec:unchanged()}
        ],
        ok = evoq_cmd_case:dispatch_all(lamp_aggregate, Sid, Scenario, StoreId),
        evoq_cmd_case:assert_stream(StoreId, Sid,
            [<<"lamp_turned_on">>, <<"lamp_turned_off">>])
    end).

%%====================================================================
%% A rejected command must surface (dispatch_all raises, never swallows)
%%====================================================================

rejected_command_raises_test() ->
    ?assertError({dispatch_failed, _},
        evoq_cmd_case:with_mem_store(fun(StoreId) ->
            Sid = sid(<<"lamp-rej">>),
            evoq_cmd_case:dispatch_all(lamp_aggregate, Sid, [{turn_off, #{}}], StoreId)
        end)).

%%====================================================================
%% Stream-id guard — today's-bug class, at the dispatch boundary
%%====================================================================

malformed_stream_id_is_rejected_test() ->
    %% A human id like "lamp-a" is NOT a valid reckon stream id. dispatch_all
    %% validates up front and raises rather than failing opaquely at the store.
    %% This is exactly the parksim stream-id bug, caught in a test.
    ?assertError({invalid_stream_id, _, _, _},
        evoq_cmd_case:with_mem_store(fun(StoreId) ->
            evoq_cmd_case:dispatch_all(lamp_aggregate, <<"lamp-a">>,
                                       [{turn_on, #{}}], StoreId)
        end)).

valid_stream_id_passes_guard_test() ->
    ok = evoq_cmd_case:assert_valid_stream_id(sid(<<"x">>)).

%%====================================================================
%% read_stream_types on an empty/unknown stream
%%====================================================================

empty_stream_reads_as_nil_test() ->
    evoq_cmd_case:with_mem_store(fun(StoreId) ->
        [] = evoq_cmd_case:read_stream_types(StoreId, sid(<<"never-written">>)),
        ok
    end).

%%====================================================================
%% assert_stream catches a mismatch (the framework must fail loudly)
%%====================================================================

assert_stream_catches_mismatch_test() ->
    ?assertError({stream_mismatch, _},
        evoq_cmd_case:with_mem_store(fun(StoreId) ->
            Sid = sid(<<"lamp-mm">>),
            ok = evoq_cmd_case:dispatch_all(lamp_aggregate, Sid, [{turn_on, #{}}], StoreId),
            evoq_cmd_case:assert_stream(StoreId, Sid, [<<"wrong_event">>])
        end)).
