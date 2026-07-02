%% @doc Sequence-driven CMD (aggregate) test spec — Layer A (pure).
%%
%% Inject a sequence of commands into an aggregate and, after EACH command,
%% assert the four things that matter for a command-side domain:
%%
%% <ol>
%%   <li>the aggregate emitted the EXPECTED events,</li>
%%   <li>the aggregate emitted NO UNEXPECTED events,</li>
%%   <li>the aggregate did NOT fail (unless the step expects an error),</li>
%%   <li>the aggregate is in the CORRECT state.</li>
%% </ol>
%%
%% (1)+(2) are a single check: the emitted event-type list is compared
%% EXACTLY (in order) to the expected list, so an extra event is a mismatch —
%% "no unexpected events" comes for free.
%%
%% This layer is PURE: it drives `Mod:init/1', `Mod:execute/2' and
%% `Mod:apply/2' directly with no event store, no processes. State threads
%% through the sequence by folding each command's emitted events via
%% `apply/2', so command N runs against the state left by commands 1..N-1 —
%% true sequence semantics. This mirrors exactly what the runtime does:
%% `evoq_aggregate' calls `Module:execute(AggState, Command#evoq_command.payload)'
%% then folds events with `Module:apply/2'. We pass the command type to the
%% handler the same way the dispatch path does — as `command_type' inside the
%% payload map.
%%
%% == Two equivalent forms ==
%%
%% Tuple-list (table-drivable):
%% ```
%% evoq_aggregate_spec:run(vehicle_aggregate, <<"veh-...">>, [
%%   {commission_vehicle, #{vehicle_id => Id, ...},
%%        expect([<<"vehicle_commissioned">>]),
%%        fun(S) -> vehicle_state:is_commissioned(S) end},
%%   {pick_up_passenger, #{vehicle_id => Id},
%%        expect_error(vehicle_not_dispatched),
%%        unchanged()}
%% ]).
%% '''
%%
%% Builder (readable for long scenarios — thread the spec):
%% ```
%% S0 = evoq_aggregate_spec:new(vehicle_aggregate, Id),
%% S1 = evoq_aggregate_spec:emits(
%%        evoq_aggregate_spec:exec(S0, commission_vehicle, #{...}),
%%        [<<"vehicle_commissioned">>]),
%% S2 = evoq_aggregate_spec:state(S1, fun vehicle_state:is_commissioned/1),
%% ok = evoq_aggregate_spec:done(S2).
%% '''
%%
%% Both raise `erlang:error/1' on the first failed assertion, so they slot
%% straight into eunit/common_test.
%%
%% NOTE: the persistence half (does the command actually persist through
%% `evoq_command_router' against a real store, with a valid stream id?) is Layer
%% B — see `evoq_cmd_case'. The four pure assertions here CANNOT catch a
%% persistence/stream-id bug.
%% @end
-module(evoq_aggregate_spec).

%% Tuple-list form
-export([run/3]).
-export([expect/1, expect_error/1, unchanged/0]).

%% Builder form
-export([new/2, given_events/2, exec/3, emits/2, emits_nothing/1,
         state/2, fails_with/2, done/1]).

-export_type([spec/0, step/0, expectation/0, state_pred/0]).

%%====================================================================
%% Types
%%====================================================================

-opaque spec() :: #{
    mod   := module(),
    id    := binary(),
    state := term(),
    %% result of the most-recent exec/3 not yet consumed by an
    %% assertion; `none' once consumed (or before the first exec).
    last  := none
           | {ok, [map()]}
           | {error, term()}
           | {caught, atom(), term()}
}.

-type expectation() :: {events, [binary()]} | {error, term()}.
-type state_pred()  :: fun((State :: term()) -> boolean()) | unchanged | any.
-type step()        :: {CmdType :: atom(), Payload :: map(),
                        expectation(), state_pred()}.

%%====================================================================
%% Tuple-list form
%%====================================================================

%% @doc Run a whole scenario against a fresh aggregate. Each step asserts
%% events (exact), no-error-vs-expected-error, and the state predicate.
%% Returns `ok' or raises on the first failure.
-spec run(module(), binary(), [step()]) -> ok.
run(Mod, Id, Scenario) when is_atom(Mod), is_binary(Id), is_list(Scenario) ->
    Final = lists:foldl(fun run_step/2, new(Mod, Id), Scenario),
    done(Final).

run_step({CmdType, Payload, Expect, Pred}, Spec) ->
    Executed = exec(Spec, CmdType, Payload),
    Asserted = assert_expectation(Executed, Expect),
    assert_state(Asserted, Pred).

assert_expectation(Spec, {events, Types}) -> emits(Spec, Types);
assert_expectation(Spec, {error, Reason}) -> fails_with(Spec, Reason).

assert_state(Spec, unchanged) -> Spec;
assert_state(Spec, any)       -> Spec;
assert_state(Spec, Pred) when is_function(Pred, 1) -> state(Spec, Pred).

%% @doc Convenience constructor for the tuple form's expectation slot.
-spec expect([binary()]) -> expectation().
expect(Types) when is_list(Types) -> {events, Types}.

%% @doc Convenience constructor: this step is expected to be rejected.
-spec expect_error(term()) -> expectation().
expect_error(Reason) -> {error, Reason}.

%% @doc The "don't assert state" marker for the tuple form's last slot.
-spec unchanged() -> unchanged.
unchanged() -> unchanged.

%%====================================================================
%% Builder form
%%====================================================================

%% @doc A fresh spec: initialises aggregate state via `Mod:init/1'.
-spec new(module(), binary()) -> spec().
new(Mod, Id) when is_atom(Mod), is_binary(Id) ->
    {ok, State} = Mod:init(Id),
    #{mod => Mod, id => Id, state => State, last => none}.

%% @doc Seed state by folding prior events (the "given" of given/when/then),
%% as if they had already been applied. Uses `Mod:apply/2'.
-spec given_events(spec(), [map()]) -> spec().
given_events(#{mod := Mod, state := State} = Spec, Events) when is_list(Events) ->
    Spec#{state := fold(Mod, State, Events)}.

%% @doc Run one command against the current state. Does NOT thread state yet
%% — the following `emits/2' (or `fails_with/2') consumes the result. Running
%% two commands without an assertion between them is an error: every command
%% must be asserted (the whole point of the spec).
-spec exec(spec(), atom(), map()) -> spec().
exec(#{last := none, mod := Mod, state := State} = Spec, CmdType, Payload)
        when is_atom(CmdType), is_map(Payload) ->
    CommandMap = Payload#{command_type => to_binary(CmdType)},
    Result =
        try Mod:execute(State, CommandMap) of
            {ok, Events} when is_list(Events) -> {ok, Events};
            {error, Reason}                   -> {error, Reason};
            Other -> erlang:error({bad_execute_return, CmdType, Other})
        catch
            Class:Err -> {caught, Class, Err}
        end,
    Spec#{last := Result};
exec(#{last := Pending}, CmdType, _Payload) ->
    erlang:error({unasserted_command, #{next => CmdType, pending => Pending}}).

%% @doc Assert the last command emitted EXACTLY these event types (in order),
%% then fold those events into state. Covers assertions (1), (2) and (3).
-spec emits(spec(), [binary()]) -> spec().
emits(#{last := {ok, Events}, mod := Mod, state := State} = Spec, ExpectedTypes) ->
    ok = assert_event_types(ExpectedTypes, Events),
    Spec#{state := fold(Mod, State, Events), last := none};
emits(#{last := {error, Reason}}, ExpectedTypes) ->
    erlang:error({expected_events_got_error,
                  #{expected => ExpectedTypes, error => Reason}});
emits(#{last := {caught, Class, Err}}, ExpectedTypes) ->
    erlang:error({execute_crashed,
                  #{expected => ExpectedTypes, class => Class, error => Err}});
emits(#{last := none}, _) ->
    erlang:error(no_command_to_assert).

%% @doc Assert the last command emitted no events at all.
-spec emits_nothing(spec()) -> spec().
emits_nothing(Spec) -> emits(Spec, []).

%% @doc Assert a predicate over the CURRENT (post-fold) aggregate state —
%% assertion (4). Use the state module's public accessors, not record
%% internals (test behaviour, not implementation).
-spec state(spec(), fun((term()) -> boolean())) -> spec().
state(#{state := State} = Spec, Pred) when is_function(Pred, 1) ->
    case Pred(State) of
        true  -> Spec;
        false -> erlang:error({state_predicate_failed, State});
        Other -> erlang:error({state_predicate_not_boolean, Other})
    end.

%% @doc Assert the last command FAILED with this exact reason (a legitimate
%% precondition rejection). State is left unchanged.
-spec fails_with(spec(), term()) -> spec().
fails_with(#{last := {error, Reason}} = Spec, Reason) ->
    Spec#{last := none};
fails_with(#{last := {error, Other}}, Reason) ->
    erlang:error({wrong_error, #{expected => Reason, got => Other}});
fails_with(#{last := {ok, Events}}, Reason) ->
    erlang:error({expected_error_got_events,
                  #{expected => Reason, events => event_types(Events)}});
fails_with(#{last := {caught, Class, Err}}, Reason) ->
    erlang:error({execute_crashed,
                  #{expected_error => Reason, class => Class, error => Err}});
fails_with(#{last := none}, _) ->
    erlang:error(no_command_to_assert).

%% @doc Terminal: assert there is no un-asserted command left, return `ok'.
-spec done(spec()) -> ok.
done(#{last := none}) -> ok;
done(#{last := Pending}) -> erlang:error({unasserted_command, Pending}).

%%====================================================================
%% Internal
%%====================================================================

fold(Mod, State, Events) ->
    lists:foldl(fun(E, Acc) -> Mod:apply(Acc, E) end, State, Events).

%% Exact, order-sensitive comparison — this is what makes "expected" and
%% "no unexpected" a single assertion.
assert_event_types(Expected, Events) ->
    Actual = event_types(Events),
    case Actual =:= Expected of
        true  -> ok;
        false -> erlang:error({event_mismatch,
                               #{expected => Expected, actual => Actual}})
    end.

event_types(Events) -> [maps:get(event_type, E) || E <- Events].

to_binary(B) when is_binary(B) -> B;
to_binary(A) when is_atom(A)   -> atom_to_binary(A, utf8).
