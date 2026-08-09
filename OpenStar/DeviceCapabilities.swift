//
//  DeviceCapabilities 2.swift
//  OpenStar
//
//  Created by Cody Peter on 8/9/26.
//


//
//  DeviceCapabilities.swift
//  OpenStar
//
//  Created by Cody Peter on 8/9/26.
//

import Foundation
import Metal
import Darwin

#if os(iOS)
import UIKit
#endif

struct DeviceCapabilities {
    let platform: String
    let machineIdentifier: String
    let gpuName: String
    let processorCount: Int
    let memoryGB: Double
    let thermalState: String
    let powerState: String

    @MainActor
    static func current() -> DeviceCapabilities {
        let processInfo = ProcessInfo.processInfo

        let memoryGB =
            Double(processInfo.physicalMemory) /
            1_073_741_824

        let gpuName =
            MTLCreateSystemDefaultDevice()?.name
            ?? "Unknown"

        return DeviceCapabilities(
            platform: platformName,
            machineIdentifier: hardwareIdentifier(),
            gpuName: gpuName,
            processorCount: processInfo.activeProcessorCount,
            memoryGB: memoryGB,
            thermalState: thermalStateName(processInfo.thermalState),
            powerState: currentPowerState()
        )
    }

    var networkCapabilities: NodeCapabilities {
        NodeCapabilities(
            platform: platform,
            hardwareIdentifier: machineIdentifier,
            gpuName: gpuName,
            processorCount: processorCount,
            memoryGB: memoryGB
        )
    }

    private static var platformName: String {
#if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad
            ? "iPadOS"
            : "iOS"
#elseif os(macOS)
        return "macOS"
#else
        return "Apple"
#endif
    }

    private static func hardwareIdentifier() -> String {
        var size: size_t = 0

        sysctlbyname(
            "hw.machine",
            nil,
            &size,
            nil,
            0
        )

        var machine = [CChar](
            repeating: 0,
            count: Int(size)
        )

        sysctlbyname(
            "hw.machine",
            &machine,
            &size,
            nil,
            0
        )

        return String(cString: machine)
    }

    private static func thermalStateName(
        _ state: ProcessInfo.ThermalState
    ) -> String {
        switch state {
        case .nominal:
            return "Nominal"

        case .fair:
            return "Fair"

        case .serious:
            return "Serious"

        case .critical:
            return "Critical"

        @unknown default:
            return "Unknown"
        }
    }

    @MainActor
    private static func currentPowerState() -> String {
#if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true

        let level = UIDevice.current.batteryLevel

        let percent = level >= 0
            ? "\(Int(level * 100))%"
            : "Unknown"

        switch UIDevice.current.batteryState {
        case .charging:
            return "\(percent) · Charging"

        case .full:
            return "\(percent) · Full"

        case .unplugged:
            return "\(percent) · Battery"

        default:
            return percent
        }
#else
        return "System Managed"
#endif
    }
}