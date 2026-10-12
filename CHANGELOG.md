# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Project scaffold.
- Four commands: `/kin` (status), `/kin test` (runs every measurement
  automatically as a numbered pipeline: plan, one OK/FAIL/SKIP line per step,
  summary). It adapts to the situation: guild chat, group chat or a private
  test channel for round trips, and when other Kinship players answer it also
  tests whispers, message receipt and a 4 KB transfer with them (other clients
  answer automatically, rate-limited, test data only)., `/kin report [name]` (copy a diagnostic
  report, or send it to a player in game with an accept prompt; falls back to
  guild chat when a whisper gets no answer), `/kin log` (log window).
- Persistent structured log with error capture.
- Message transport with chunking, priorities, throttle and lockdown handling;
  timers only run while there is something to send.
- `scripts/kinship-diag.py` to decode reports, read SavedVariables and merge logs
  from several clients into one timeline.
- luacheck config, `scripts/lint.ps1` and CI (lint, TOC check, decoder self-test).
