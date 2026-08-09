//
//  ContentView.swift
//  OpenStar
//
//  Created by Cody Peter on 8/9/26.
//

import SwiftUI

struct ContentView: View {
    @State private var manager =
        ContributionManager()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    contributionCard
                    performanceCard
                    networkCard
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
                "Help process open scientific workloads using idle compute on this device."
            )
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .padding(.vertical)
    }

    private var contributionCard: some View {
        VStack(spacing: 18) {
            HStack {
                VStack(
                    alignment: .leading,
                    spacing: 4
                ) {
                    Text("Node Status")
                        .font(.headline)

                    Text(manager.statusText)
                        .foregroundStyle(
                            manager.errorMessage == nil
                                ? Color.secondary
                                : Color.red
                        )
                }

                Spacer()

                if manager.isContributing {
                    ProgressView()
                }
            }

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
            RoundedRectangle(
                cornerRadius: 18
            )
        )
    }

    private var performanceCard: some View {
        VStack(
            alignment: .leading,
            spacing: 14
        ) {
            Text("GPU Performance")
                .font(.headline)

            if let gflops =
                manager.lastGFLOPS {
                HStack(
                    alignment:
                        .firstTextBaseline
                ) {
                    Text(
                        gflops,
                        format:
                            .number.precision(
                                .fractionLength(1)
                            )
                    )
                    .font(
                        .system(
                            size: 38,
                            weight: .bold,
                            design: .rounded
                        )
                    )
                    .monospacedDigit()

                    Text("GFLOP/s")
                        .foregroundStyle(
                            .secondary
                        )
                }
            } else {
                Text(
                    "Waiting for the first network work unit."
                )
                .foregroundStyle(
                    .secondary
                )
            }

            if let best =
                manager.bestGFLOPS {
                infoRow(
                    "Best",
                    String(
                        format: "%.1f GFLOP/s",
                        best
                    )
                )
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(
            RoundedRectangle(
                cornerRadius: 18
            )
        )
    }

    private var networkCard: some View {
        VStack(
            alignment: .leading,
            spacing: 14
        ) {
            Text("Network")
                .font(.headline)

            infoRow(
                "Registered",
                manager.isRegistered
                    ? "Yes"
                    : "No"
            )

            infoRow(
                "Node",
                String(
                    manager.nodeID
                        .uuidString
                        .prefix(8)
                )
            )

            if let project =
                manager.currentProject {
                infoRow(
                    "Project",
                    project
                )
            }

            if let workID =
                manager.currentWorkUnitID {
                infoRow(
                    "Work Unit",
                    String(
                        workID
                            .uuidString
                            .prefix(8)
                    )
                )
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(
            RoundedRectangle(
                cornerRadius: 18
            )
        )
    }

    private var deviceCard: some View {
        VStack(
            alignment: .leading,
            spacing: 14
        ) {
            Text("This Device")
                .font(.headline)

            infoRow(
                "Platform",
                manager.capabilities.platform
            )

            infoRow(
                "Hardware",
                manager.capabilities
                    .machineIdentifier
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
                    manager.capabilities
                        .memoryGB
                )
            )

            infoRow(
                "Thermal State",
                manager.capabilities
                    .thermalState
            )

            infoRow(
                "Power",
                manager.capabilities
                    .powerState
            )
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(
            RoundedRectangle(
                cornerRadius: 18
            )
        )
    }

    private var statisticsCard: some View {
        VStack(
            alignment: .leading,
            spacing: 14
        ) {
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
                "GPU Compute Time",
                String(
                    format: "%.2f sec",
                    manager.totalComputeSeconds
                )
            )

            if let duration =
                manager.lastWorkUnitDuration {
                infoRow(
                    "Last Work Unit",
                    String(
                        format: "%.3f sec",
                        duration
                    )
                )
            }

            if let checksum =
                manager.lastChecksum {
                infoRow(
                    "Result Checksum",
                    String(
                        format: "%.3f",
                        checksum
                    )
                )
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(
            RoundedRectangle(
                cornerRadius: 18
            )
        )
    }

    private func infoRow(
        _ title: String,
        _ value: String
    ) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(
                    .secondary
                )

            Spacer()

            Text(value)
                .multilineTextAlignment(
                    .trailing
                )
                .monospacedDigit()
        }
    }
}

#Preview {
    ContentView()
}
