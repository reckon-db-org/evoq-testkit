# evoq-testkit

Domain (command-side) test framework for [evoq](https://github.com/reckon-db-org/evoq)
aggregates.

## Why this exists

Testing an evoq aggregate well means proving two different things:

1. **Logic** — given a prior history, a command produces exactly the right
   events (and no others), or is correctly rejected, and leaves the aggregate
   in the right state.
2. **Persistence** — that same command, dispatched for real, actually lands its
   events in the store (with a valid stream id) and the projection folds them.

evoq ships `evoq_test_assertions` for one-shot decision checks. evoq-testkit
adds what was missing:

- **`evoq_aggregate_spec`** (Layer A, pure) — inject a *sequence* of commands
  and, after each one, assert the four things that matter:
  1. the expected events were emitted,
  2. **no unexpected** events were emitted (exact match),
  3. the command did not fail (or failed with the expected reason),
  4. the aggregate is in the correct state.
  State threads through the sequence by folding events via `apply/2`, with no
  event store and no processes — milliseconds per scenario.

- **`evoq_cmd_case`** (Layer B, persistence) — replay the *same* scenario
  through `evoq_command_router` against the in-memory
  [mem-evoq](https://github.com/reckon-db-org/mem-evoq) adapter, then read the
  stream back to prove the events persisted and (optionally) the projection
  folded them. This is the layer that catches "dispatch returned ok but nothing
  was stored" bugs — e.g. a malformed stream id rejected at the store boundary.

It lives in its own repo (not in evoq) because Layer B depends on mem-evoq,
which already depends on evoq — a separate package keeps the graph a clean DAG.

## Installation

```erlang
%% rebar.config — add to your TEST profile
{profiles, [
    {test, [
        {deps, [{evoq_testkit, "~> 0.1"}]}
    ]}
]}.
```

## Layer A — pure aggregate spec

Tuple-list form (table-drivable):

```erlang
evoq_aggregate_spec:run(my_aggregate, <<"agg-...">>, [
  {open_account, #{id => Id, owner => <<"alice">>},
       evoq_aggregate_spec:expect([<<"account_opened">>]),
       fun(S) -> my_state:is_open(S) end},
  {deposit, #{id => Id, amount => 100},
       evoq_aggregate_spec:expect([<<"funds_deposited">>]),
       fun(S) -> my_state:balance(S) =:= 100 end},
  {withdraw, #{id => Id, amount => 999},
       evoq_aggregate_spec:expect_error(insufficient_funds),
       evoq_aggregate_spec:unchanged()}
]).
```

Builder form (readable for long scenarios):

```erlang
S0 = evoq_aggregate_spec:new(my_aggregate, Id),
S1 = evoq_aggregate_spec:emits(
       evoq_aggregate_spec:exec(S0, open_account, #{owner => <<"alice">>}),
       [<<"account_opened">>]),
S2 = evoq_aggregate_spec:state(S1, fun my_state:is_open/1),
ok = evoq_aggregate_spec:done(S2).
```

The builder is deliberately strict: running a command without asserting it
before the next command raises — every command must be checked.

## Layer B — persistence (coming)

```erlang
evoq_cmd_case:with_mem_store(fun(StoreId) ->
    ok = evoq_cmd_case:dispatch_all(my_aggregate, Id, Scenario, StoreId),
    evoq_cmd_case:assert_stream(StoreId, my_aggregate:stream_id(Id),
        [<<"account_opened">>, <<"funds_deposited">>])
end).
```

## License

Apache-2.0.
