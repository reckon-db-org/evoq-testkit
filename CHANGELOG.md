# Changelog

All notable changes to **evoq-testkit** are documented here.

## [0.1.1] - 2026-07-03

### Fixed

- Track evoq 1.23's module rename: dispatch through `evoq_command_router`
  instead of the removed `evoq_dispatcher`. Under evoq >= 1.23 the Layer B
  harness (`evoq_cmd_case`) crashed `{undef, evoq_dispatcher:dispatch/2}` on
  every command; now green against evoq 1.23.0. Consumers on `evoq ~> 1.19`
  that resolve to 1.23 (e.g. hecate-parksim) need this.

## [0.1.0]

### Added

- `evoq_aggregate_spec` (Layer A): sequence-driven pure aggregate test spec.
  Inject a command sequence; after each command assert expected events, no
  unexpected events (exact match), no failure (or the expected error reason),
  and a state predicate. State threads via `apply/2`. Two forms: tuple-list
  `run/3` and an eager builder (`new`/`given_events`/`exec`/`emits`/`state`/
  `fails_with`/`done`). Pure — no store, no processes.
- Self-tests covering the happy paths, state threading, `given_events`
  seeding, and every failure mode (the spec must fail loudly when an
  expectation is violated).
