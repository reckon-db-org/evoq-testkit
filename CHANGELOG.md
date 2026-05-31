# Changelog

All notable changes to **evoq-testkit** are documented here.

## [Unreleased]

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
