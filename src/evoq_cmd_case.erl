%% @doc Persistence-level CMD test harness — Layer B.
%%
%% Layer A (`evoq_aggregate_spec') proves command LOGIC purely: the right
%% events for the right state. It is blind to whether those events actually
%% PERSIST when dispatched for real — the half where a malformed stream id, a
%% swallowed dispatch error, or a mis-wired adapter hides. Layer B closes that
%% gap by replaying a command sequence through the REAL dispatch path
%% (`evoq_command_router') against the in-memory `mem_evoq' adapter, then reading
%% the stream back to prove the events landed.
%%
%% mem-evoq is a real `evoq_event_store' adapter with no Khepri / Ra / disk,
%% so this runs at unit-test speed. `evoq_aggregate' persists via the globally
%% configured adapter (`evoq_event_store:get_adapter/0'), so `with_mem_store/1'
%% swaps that to `mem_evoq_adapter' for the duration of the test and restores
%% it after. The aggregate's `handle_call' appends synchronously before
%% replying `{ok, Version, Events}', so a read-back right after a successful
%% dispatch sees the persisted events.
%%
%% == Usage ==
%% ```
%% evoq_cmd_case:with_mem_store(fun(StoreId) ->
%%     Sid = my_aggregate:stream_id(<<"thing-1">>),
%%     Scenario = [{open, #{...}}, {close, #{...}}],
%%     ok = evoq_cmd_case:dispatch_all(my_aggregate, Sid, Scenario, StoreId),
%%     evoq_cmd_case:assert_stream(StoreId, Sid,
%%         [<<"opened">>, <<"closed">>])
%% end).
%% '''
%%
%% A scenario step is `{CmdType, Payload}' OR the Layer-A 4-tuple
%% (`{CmdType, Payload, _Expect, _Pred}'), so the SAME scenario list drives
%% both layers; Layer B ignores the pure-assertion slots.
%% @end
-module(evoq_cmd_case).

-export([with_mem_store/1, with_mem_store/2]).
-export([dispatch_all/4, dispatch_one/4]).
-export([assert_stream/3, read_stream_types/2]).
-export([assert_valid_stream_id/1]).

-define(READ_LIMIT, 10000).

%%====================================================================
%% Fixture
%%====================================================================

%% @doc Start a fresh in-memory store, point evoq at the mem-evoq adapter,
%% run `Fun(StoreId)', then tear down (stop the store, restore the previous
%% adapter). Returns whatever `Fun' returns. The StoreId is unique per call.
-spec with_mem_store(fun((atom()) -> Result)) -> Result.
with_mem_store(Fun) ->
    with_mem_store(Fun, #{}).

%% @doc As `with_mem_store/1' with store options (e.g. `#{integrity => ...}'),
%% passed through to `mem_evoq:start_store/2'.
-spec with_mem_store(fun((atom()) -> Result), map()) -> Result.
with_mem_store(Fun, StoreOpts) when is_function(Fun, 1), is_map(StoreOpts) ->
    {ok, _} = application:ensure_all_started(evoq),
    {ok, _} = application:ensure_all_started(mem_evoq),
    PrevAdapter = previous_adapter(),
    evoq_event_store:set_adapter(mem_evoq_adapter),
    StoreId = unique_store_id(),
    {ok, _Pid} = mem_evoq:start_store(StoreId, StoreOpts),
    try
        Fun(StoreId)
    after
        catch mem_evoq:stop_store(StoreId),
        restore_adapter(PrevAdapter)
    end.

previous_adapter() ->
    case application:get_env(evoq, event_store_adapter) of
        {ok, A} -> {set, A};
        undefined -> unset
    end.

restore_adapter({set, A}) -> evoq_event_store:set_adapter(A);
restore_adapter(unset)    -> application:unset_env(evoq, event_store_adapter).

unique_store_id() ->
    N = erlang:unique_integer([positive, monotonic]),
    list_to_atom("evoq_testkit_store_" ++ integer_to_list(N)).

%%====================================================================
%% Dispatch
%%====================================================================

%% @doc Dispatch every command in the scenario through the real dispatch path,
%% asserting each one PERSISTS (`{ok, _Version, _Events}'). A non-ok dispatch
%% raises — the swallowed `catch dispatch' that hides "nothing got stored"
%% bugs is structurally impossible here. Validates the stream id up front
%% (reckon-db rejects malformed ids at append, so an invalid id would make
%% every dispatch fail at the store boundary).
-spec dispatch_all(module(), binary(), [tuple()], atom()) -> ok.
dispatch_all(AggMod, StreamId, Scenario, StoreId)
        when is_atom(AggMod), is_binary(StreamId),
             is_list(Scenario), is_atom(StoreId) ->
    ok = assert_valid_stream_id(StreamId),
    lists:foreach(
      fun(Step) ->
          dispatch_one(AggMod, StreamId, step_command(Step), StoreId)
      end, Scenario),
    ok.

%% @doc Dispatch a single command and assert it persisted.
-spec dispatch_one(module(), binary(), {atom(), map()}, atom()) -> ok.
dispatch_one(AggMod, StreamId, {CmdType, Payload}, StoreId)
        when is_atom(CmdType), is_map(Payload) ->
    %% The aggregate runtime passes Command#evoq_command.payload verbatim to
    %% execute/2, and aggregates match on `command_type' INSIDE the payload
    %% map (the convention vehicle_aggregate etc. use). So carry it in the
    %% payload, exactly as evoq_aggregate_spec does on the pure path.
    CommandPayload = Payload#{command_type => command_type_bin(CmdType)},
    Command = evoq_command:new(CmdType, AggMod, StreamId, CommandPayload),
    case evoq_command_router:dispatch(Command, #{store_id => StoreId}) of
        {ok, _Version, _Events} -> ok;
        {error, Reason} ->
            erlang:error({dispatch_failed,
                          #{command => CmdType, stream_id => StreamId,
                            reason => Reason}})
    end.

%% A Layer-A step is {CmdType, Payload, _Expect, _Pred}; a bare step is
%% {CmdType, Payload}. Accept both so one scenario drives both layers.
step_command({CmdType, Payload}) -> {CmdType, Payload};
step_command({CmdType, Payload, _Expect, _Pred}) -> {CmdType, Payload}.

command_type_bin(B) when is_binary(B) -> B;
command_type_bin(A) when is_atom(A)   -> atom_to_binary(A, utf8).

%%====================================================================
%% Read-back assertions
%%====================================================================

%% @doc Assert the persisted stream holds EXACTLY these event types, in order.
%% This is the assertion that distinguishes "dispatch returned ok" from "the
%% events actually landed".
-spec assert_stream(atom(), binary(), [binary()]) -> ok.
assert_stream(StoreId, StreamId, ExpectedTypes) ->
    Actual = read_stream_types(StoreId, StreamId),
    case Actual =:= ExpectedTypes of
        true  -> ok;
        false -> erlang:error({stream_mismatch,
                               #{stream_id => StreamId,
                                 expected => ExpectedTypes,
                                 actual => Actual}})
    end.

%% @doc The event types persisted under a stream, oldest first.
-spec read_stream_types(atom(), binary()) -> [binary()].
read_stream_types(StoreId, StreamId) ->
    case evoq_event_store:read(StoreId, StreamId, 0, ?READ_LIMIT, forward) of
        {ok, Events} -> [maps:get(event_type, E) || E <- Events];
        {error, {stream_not_found, _}} -> [];
        {error, Reason} -> erlang:error({stream_read_failed, StreamId, Reason})
    end.

%%====================================================================
%% Stream-id guard
%%====================================================================

%% @doc Assert that StreamId is a valid reckon-db stream id. reckon-db rejects
%% ids not matching `^[a-z]{1,32}-[a-f0-9]{32}$' at append time, so an
%% aggregate that uses (say) a human id as its stream id fails on the very
%% first real dispatch. Calling this in a test catches that explicitly —
%% mem-evoq itself does NOT enforce the format, so this guard is what makes
%% Layer B faithful to reckon-db on that point.
-spec assert_valid_stream_id(binary()) -> ok.
assert_valid_stream_id(StreamId) ->
    case reckon_gater_stream_id:validate(StreamId) of
        ok -> ok;
        {error, Reason} ->
            erlang:error({invalid_stream_id, Reason, StreamId,
                          <<"must match ^[a-z]{1,32}-[a-f0-9]{32}$">>})
    end.
