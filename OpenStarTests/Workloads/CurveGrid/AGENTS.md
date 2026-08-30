# CurveGrid test owner scope

The future CurveGrid capability owner may modify only `OpenStar/Workloads/CurveGrid/` and this matching test folder.

Do not modify `OpenStar.xcodeproj/**`, `OpenStar/WorkerCore/**`, the central workload catalog, `OpenStar/WorkloadRouter.swift`, existing shared tests, another workload folder, `OpenStarKernels.metal`, or the Linux worker repository.

If a required shared capability is missing, stop and report it rather than expanding scope.
