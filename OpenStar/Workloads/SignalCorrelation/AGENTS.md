# SignalCorrelation capability owner scope

The future SignalCorrelation capability owner may modify only this production folder and the matching `OpenStarTests/Workloads/SignalCorrelation/` test folder.

Do not modify `OpenStar.xcodeproj/**`, `OpenStar/WorkerCore/**`, the central workload catalog, `OpenStar/WorkloadRouter.swift`, existing shared tests, another workload folder, `OpenStarKernels.metal`, or the Linux worker repository.

Keep this worker generic and domain-neutral. Put any future Metal implementation in a uniquely named file in this folder and use uniquely prefixed functions. If a required shared capability is missing, stop and report it rather than expanding scope.
