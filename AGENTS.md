# OpenStar Agent Rules

OpenStar is an open-source distributed science system.

## Architecture

- Workers are generic compute workers.
- Workers must not contain astronomy-specific logic.
- The Mac is not a special science orchestrator.
- The coordinator manages projects and work units.
- Science-specific workflows prepare inputs and interpret outputs.

## Engineering rules

- Make the smallest coherent change.
- Do not weaken tests to make them pass.
- Run relevant tests after changes.
- Preserve reproducibility and provenance.
- Never fabricate scientific results.
- Do not modify frozen scientific evidence.
- Prefer reusable OpenStar infrastructure over target-specific scripts.

## Current direction

Blind C investigation is complete through v20.28.
Do not continue manually extending Blind C.
Do not restore the premature v20.29 targeted-observation ingest work.

The goal is to make OpenStar autonomously produce science using generic distributed workers.

