# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Project scaffold.
- Diagnostics: persistent structured log with error capture, `/kin status`,
  `/kin log`, `/kin debug`, `/kin report` (copy box) and `/kin report send <name>`
  (in-game delivery with an accept prompt), `/kin reports` inbox.
- Message transport with chunking, priorities, throttle and lockdown handling;
  timers only run while there is something to send.
- `/kin test` measurements for message limits, whisper delivery, messaging
  lockdown, encoding sizes, identities, game events and calendar access.
- `scripts/kinship-diag.py` to decode reports, read SavedVariables and merge logs
  from several clients into one timeline.
- luacheck config, `scripts/lint.ps1` and CI (lint, TOC check, decoder self-test).
