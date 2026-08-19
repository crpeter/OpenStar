//
//  ContentView.swift
//  OpenStar
//

import SwiftUI

struct ContentView: View {
    @State private var manager = ContributionManager()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    contributionCard
                    projectCard
                    lastResultCard
                    networkCard
                    workloadCard
                    deviceCard
                    statisticsCard
                }
                .frame(maxWidth: 700)
                .padding()
            }
            .navigationTitle("OpenStar")
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 44))

            Text("Contribute your compute")
                .font(.title2.bold())

            Text(
                "Run compatible distributed workloads using this device."
            )
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .padding(.vertical)
    }

    private var contributionCard: some View {
        VStack(spacing: 18) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Worker Activity")
                        .font(.headline)

                    Text(manager.statusText)
                        .font(.title3.bold())
                        .foregroundStyle(
                            manager.errorMessage == nil
                                ? Color.primary
                                : Color.red
                        )
                        .lineLimit(1)

                    Text(activityContext)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if manager.currentWorkUnitID != nil {
                    ProgressView()
                        .controlSize(.large)
                        .accessibilityLabel("Worker is processing work")
                }
            }
            .frame(height: 76)

            Button {
                if manager.isContributing {
                    manager.stop()
                } else {
                    manager.start()
                }
            } label: {
                Label(
                    manager.isContributing
                        ? "Stop Contributing"
                        : "Start Contributing",
                    systemImage:
                        manager.isContributing
                        ? "stop.fill"
                        : "play.fill"
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(
            RoundedRectangle(cornerRadius: 18)
        )
    }

    private var activityContext: String {
        if let errorMessage = manager.errorMessage {
            return errorMessage
        }

        if let project = manager.currentProject,
           let workload = manager.currentWorkloadID {
            return "\(project)  ·  \(workload)"
        }

        if manager.isContributing {
            return manager.availability == .available
                ? "Looking for compatible work"
                : "Device environment unavailable"
        }

        return "Ready to contribute"
    }

    private var projectCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Current Project")
                .font(.headline)

            if let status = manager.projectStatus {
                infoRow(
                    "Project",
                    status.projectID
                )

                if let targetName = status.targetName,
                   !targetName.isEmpty {
                    infoRow(
                        "Display Target",
                        targetName
                    )
                }

                infoRow(
                    "Workload",
                    status.workloadID
                )

                infoRow(
                    "Project Progress",
                    "\(Int(status.progress * 100))%"
                )

                infoRow(
                    "Completed",
                    "\(status.completedWorkUnits) / \(status.totalWorkUnits)"
                )

                infoRow(
                    "Pending",
                    "\(status.pendingWorkUnits)"
                )

                infoRow(
                    "Assigned",
                    "\(status.assignedWorkUnits)"
                )

                infoRow(
                    "Retries",
                    "\(status.retryCount)"
                )

                if let failed = status.failedWorkUnits {
                    infoRow(
                        "Failed",
                        "\(failed)"
                    )
                }
            } else {
                Text(
                    "Connect to the coordinator to load the current project."
                )
                .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(
            RoundedRectangle(cornerRadius: 18)
        )
    }

    private var lastResultCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Last Workload Result")
                .font(.headline)

            if let summary = manager.lastResultSummary {
                Text(summary.title)
                    .font(.subheadline.bold())

                ForEach(summary.fields) { field in
                    infoRow(
                        field.label,
                        field.value
                    )
                }
            } else {
                Text(
                    "No completed workload result yet."
                )
                .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(
            RoundedRectangle(cornerRadius: 18)
        )
    }

    private var networkCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Network")
                .font(.headline)

            infoRow(
                "Registered",
                manager.isRegistered ? "Yes" : "No"
            )

            infoRow(
                "Node",
                String(
                    manager.nodeID.uuidString.prefix(8)
                )
            )

            if let project = manager.currentProject {
                infoRow(
                    "Project",
                    project
                )
            }

            if let workloadID = manager.currentWorkloadID {
                infoRow(
                    "Workload",
                    workloadID
                )
            }

            if let workID = manager.currentWorkUnitID {
                infoRow(
                    "Work Unit",
                    String(
                        workID.uuidString.prefix(8)
                    )
                )
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(
            RoundedRectangle(cornerRadius: 18)
        )
    }

    private var workloadCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Supported Workloads")
                .font(.headline)

            if manager.supportedWorkloads.isEmpty {
                Text("No workload plugins are available.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(
                    manager.supportedWorkloads,
                    id: \.workloadID
                ) { capability in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(capability.workloadID)
                            .font(.subheadline.bold())

                        Text(
                            capability.executionBackends
                                .map(\.id)
                                .joined(separator: ", ")
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        if let validatorID = capability.validatorID {
                            Text("Validator: \(validatorID)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(
            RoundedRectangle(cornerRadius: 18)
        )
    }

    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("This Device")
                .font(.headline)

            infoRow(
                "Platform",
                manager.capabilities.platform
            )

            infoRow(
                "Hardware",
                manager.capabilities.machineIdentifier
            )

            infoRow(
                "GPU",
                manager.capabilities.gpuName
            )

            infoRow(
                "CPU Cores",
                "\(manager.capabilities.processorCount)"
            )

            infoRow(
                "Memory",
                String(
                    format: "%.1f GB",
                    manager.capabilities.memoryGB
                )
            )

            infoRow(
                "Thermal State",
                manager.capabilities.thermalState
            )

            infoRow(
                "Power",
                manager.capabilities.powerState
            )
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(
            RoundedRectangle(cornerRadius: 18)
        )
    }

    private var statisticsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Contribution")
                .font(.headline)

            infoRow(
                "Work Units Completed",
                "\(manager.unitsCompleted)"
            )

            infoRow(
                "Server Accepted",
                "\(manager.unitsAccepted)"
            )

            infoRow(
                "Compute Time",
                String(
                    format: "%.3f sec",
                    manager.totalComputeSeconds
                )
            )

            if let duration = manager.lastWorkUnitDuration {
                infoRow(
                    "Last Work Unit",
                    String(
                        format: "%.4f sec",
                        duration
                    )
                )
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(
            RoundedRectangle(cornerRadius: 18)
        )
    }

    private func infoRow(
        _ title: String,
        _ value: String
    ) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)

            Spacer()

            Text(value)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(minHeight: 20)
    }
}

#Preview {
    ContentView()
}
