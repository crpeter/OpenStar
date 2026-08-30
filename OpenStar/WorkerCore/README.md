# Apple worker workload composition

`WorkloadCatalog` is the single composition root for generic workloads on the
Apple worker. Each prewired module factory owns its implementation beneath its
corresponding `OpenStar/Workloads/` folder, so implementing a module does not
require changing the catalog or router.

Workload-specific Metal kernels must also live in that workload's folder, in a
uniquely named `.metal` file whose functions have a workload-unique prefix.
They must not be added to `OpenStarKernels.metal`.

The current coordinator contract requires `WorkUnit.workloadID`. Optional
dataset, payload, and result schema identities can accompany capabilities and
work units without changing legacy JSON. Result submissions echo a work unit's
optional result schema identity so the immutable contract remains traceable.
