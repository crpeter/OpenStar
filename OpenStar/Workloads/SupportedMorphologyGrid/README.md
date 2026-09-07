# SupportedMorphologyGrid CPU worker

This separately identified workload admits only numerically valid candidates
with observational support for every component in every applicable series.
It does not attach an interpretation to the fitted result.

| Identity | Frozen value |
| --- | --- |
| workloadID | `openstar.supported-morphology-grid.v1` |
| datasetSchemaID | `openstar.dataset.supported-morphology-grid.v1` |
| payloadSchemaID | `openstar.payload.supported-morphology-grid-shard.v1` |
| resultSchemaID | `openstar.result.supported-morphology-grid-shard.v1` |
| executionContractID | `openstar.supported-morphology-grid-execution.v1` |
| executionContractVersion | `1.0` |
| validatorID | `openstar.supported-morphology-grid.local-double.v1` |
| supportPolicyID | `openstar.morphology-support.two-effective-widths.v1` |
| morphologyFamilyID | `openstar.microlensing-residual-morphology.v1` |
| componentTemplateFamilyID | `openstar.curve-family.symmetric-radial-amplification.v1` |

The CPU handler requests batches of 8 and decodes a batch's dataset once.
Ordinary folders use the project's existing synchronized inclusion. No package
or project-file changes are needed.

The private numerical adapter checks the new dataset identities and required
string policy before constructing a v1 numerical view. Nested series, grid,
and axis decoding, finite and JSON-safe bounds, canonical sample ordering,
independent center pairs, fits, parameter counts, information criteria, and
winner comparison come from the existing MorphologyGrid implementation.
Top-level dataset extensions remain allowed. Work-unit identity tuples and
dataset IDs must match; the old and new handlers do not accept each other's
work units.

The payload has exactly `morphologyFamilyID`, `modelClassID`, `supportPolicyID`,
`gridStartIndex`, and `gridCount`. The result contains those five fields plus
`bestCandidate`, `evaluatedCandidateCount`, `invalidCandidateCount`, and
`supportRejectedCandidateCount`. The candidate's nested v1 shape is unchanged.

Candidates are visited in increasing original index order. Numerical rejection
increments only `invalidCandidateCount`. For each numerically valid candidate,
each component uses these separate operations:

```text
scale = exp(logScale)
shape = exp(logShape)
effectiveWidth = scale * shape
radius = 2.0 * effectiveWidth
```

Center must be finite; scale, shape, width, and radius must be finite and
positive. A series supplies support if at least one observation has weight > 0
and `abs(coordinate - center) <= radius`. Every component must pass in every
series. Independent datasets contain exactly one series. Ordered doublets use
`positiveCenter = negativeCenter + separation`. Fitted amplitudes, including
zero, do not change this rule. No threshold or sign configuration is accepted.
Unsupported numerical candidates increment only `supportRejectedCandidateCount`.
Eligible candidates use the unchanged v1 comparison, including the `1e-9`
relative objective tolerance and deterministic global-index tie-breaking.

`evaluatedCandidateCount` equals `gridCount`. Subtracting both rejection counts
gives the eligible count. Zero eligible candidates produce successful work with
`bestCandidate: null`. Cancellation is recoverable, checked before every
candidate and periodically while scanning support observations. Evaluation
state is local to each call and follows v1 nonisolated/Sendable conventions.

## Portable conformance examples

These are source-specified expectations, not results from an executed run.
The matching Apple fixtures are in
`OpenStarTests/Workloads/SupportedMorphologyGrid/SupportedMorphologyGridFixtures.swift`.

A complete small dataset for rejection accounting:

```json
{
  "id": "generic-supported-grid",
  "datasetSchemaID": "openstar.dataset.supported-morphology-grid.v1",
  "morphologyFamilyID": "openstar.microlensing-residual-morphology.v1",
  "componentTemplateFamilyID": "openstar.curve-family.symmetric-radial-amplification.v1",
  "executionContractID": "openstar.supported-morphology-grid-execution.v1",
  "executionContractVersion": "1.0",
  "supportPolicyID": "openstar.morphology-support.two-effective-widths.v1",
  "modelClassID": "POSITIVE_PULSE_ONLY",
  "series": [{
    "genericSeriesID": "series-001",
    "coordinates": [3, 4, 5, 6, 7, 8, 9, 10],
    "values": [0, 1, 2, 3, 2, 1, 0, 1],
    "inverseVariances": [1, 1, 1, 1, 1, 1, 1, 1]
  }],
  "morphologyGrid": {
    "centerAxis": {"start": 0, "step": 4, "count": 2},
    "logScaleAxis": {"start": 0, "step": 1, "count": 1},
    "logShapeAxis": {"values": [0]}
  },
  "candidatesPerWorkUnit": 2
}
```

For the shard at index 0 with count 1, the exact payload and result are:

```json
{
  "morphologyFamilyID": "openstar.microlensing-residual-morphology.v1",
  "modelClassID": "POSITIVE_PULSE_ONLY",
  "supportPolicyID": "openstar.morphology-support.two-effective-widths.v1",
  "gridStartIndex": 0,
  "gridCount": 1
}
```

```json
{
  "morphologyFamilyID": "openstar.microlensing-residual-morphology.v1",
  "modelClassID": "POSITIVE_PULSE_ONLY",
  "supportPolicyID": "openstar.morphology-support.two-effective-widths.v1",
  "gridStartIndex": 0,
  "gridCount": 1,
  "bestCandidate": null,
  "evaluatedCandidateCount": 1,
  "invalidCandidateCount": 0,
  "supportRejectedCandidateCount": 1
}
```

With the same dataset, the full shard has counts `(2, 0, 1)` and winner index
1. Counts below are `(evaluated, invalid, supportRejected)`:

| Variant | Shard start/count | Counts | Winner index |
| --- | --- | --- | --- |
| Base dataset | 1 / 1 | (1, 0, 0) | 1 |
| Set logScaleAxis to start -700, step 700, count 2; candidatesPerWorkUnit 4 | 0 / 4 | (4, 2, 1) | 3 |
| Same mixed-validity grid | 0 / 3 | (3, 2, 1) | null |
| Same mixed-validity grid | 0 / 1 | (1, 1, 0) | null |
| Base grid; coordinates [7,8,9,10,11,12,13,14] | 0 / 2 | (2, 0, 2) | null |

For nondegenerate fit comparisons, define the fixture basis in this exact order:

```text
z = coordinate - center
uSquared = 1.0 + z * z
basis = (uSquared + 2.0) / (sqrt(uSquared) * sqrt(uSquared + 4.0))
value = 0.75 + 2.5 * basis(coordinate, positiveCenter)
```

Use coordinates `[3,4,5,6,7,8,9,10]` and unit weights. Generating at center 0
makes index 0 the unsupported numerical winner of the base grid; this workload
must instead return index 1 with counts `(2,0,1)`. Generating at center 4 gives
a supported fit at index 1. Do not require exact zero WRSS for either fitted
model; use the frozen v1 objective tolerances.

For doublets, compute values as `0.75`, then add
`-1.5 * basis(coordinate, negativeCenter)`, then add
`2.5 * basis(coordinate, positiveCenter)`. All log-scale and log-shape axes are
singletons at zero (linear scale axes, explicit shape arrays).

| Model and axes | Coordinates and generated centers | Counts | Winner |
| --- | --- | --- | --- |
| Ordered: negative center 10; separation start 4, step 4, count 2 | [8,9,10,11,12,13,14,15]; negative 10, positive 14 | (2,0,1) | index 0, positive center derived as 14 |
| Independent: center start 0, step 4, count 3 | [3,4,5,6,7,8,9,10]; negative 4, positive 8 | (3,0,2) | index 2, pair (4,8) |
| Independent: same grid, partial shard start 1, count 2 | same samples | (2,0,1) | index 2 |

Independent center pairs are `(0,4)`, `(0,8)`, `(4,8)` in that order; equal or
reversed pairs are absent. Shape is the fastest-changing axis within each pair.

Geometric boundary examples with logs zero: a component at 0 accepts a
positive-weight observation at either -2 or +2; the next representable value
outside either boundary is rejected. Weight zero at the center cannot supply
support. An ordered doublet at 10 with separation 4 accepts an observation at
12 for both components. Each series must satisfy these checks separately,
even if an amplitude is fitted as zero.

## Required local validation and cross-implementation comparison

Tests and builds were not run during implementation. From the repository root,
select exactly these focused suites on an available local simulator (replace
`LOCAL_SIMULATOR_UDID` with its ID):

```sh
xcodebuild test \
  -project OpenStar.xcodeproj \
  -scheme OpenStar \
  -destination 'platform=iOS Simulator,id=LOCAL_SIMULATOR_UDID' \
  -only-testing:OpenStarTests/SupportedMorphologyGridWorkloadTests \
  -only-testing:OpenStarTests/SupportedMorphologyGridWireTests \
  -only-testing:OpenStarTests/WorkloadCatalogTests
```

Before any live run, compare the server and Apple fixtures on the same inputs.
That comparison is pending the separately developed server implementation and
local validation. Compare identities, exact field sets, model/axis order,
shard ranges, both rejection counts, nullability, winner indices, parameter
values, per-series fits and signs, sample counts, parameter counts, WRSS, BIC,
and defined/undefined AICc. Use the unchanged v1 floating-point tolerances;
integers, booleans, strings, field sets, and nullability must agree exactly.
