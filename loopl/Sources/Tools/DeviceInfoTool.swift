import Foundation
import UIKit

public struct DeviceInfoTool: AgentTool {
    public init() {}
    public let name = "device_info"
    public let description = "Battery level and state, available memory for this app, total RAM, OS version, offline-mode flag and thermal state of this iPhone."
    public let parameters: JSONValue = ["type": "object", "properties": [:], "required": []]
    public func call(_ args: [String: JSONValue]) async throws -> String {
        let info = await MainActor.run { () -> [String] in
            let dev = UIDevice.current
            dev.isBatteryMonitoringEnabled = true
            let battery = dev.batteryLevel < 0 ? "unknown" : "\(Int(dev.batteryLevel * 100))%"
            let state: String = switch dev.batteryState { case .charging: "charging"; case .full: "full"; case .unplugged: "unplugged"; default: "unknown" }
            let thermal: String = switch ProcessInfo.processInfo.thermalState { case .nominal: "nominal"; case .fair: "fair"; case .serious: "serious"; case .critical: "critical"; @unknown default: "unknown" }
            return ["model: \(dev.model) (\(dev.systemName) \(dev.systemVersion))",
                    "battery: \(battery) \(state)",
                    "memory available to this app: \(MemoryBudget.label(MemoryBudget.available))",
                    "physical RAM: \(MemoryBudget.label(MemoryBudget.physical))",
                    "thermal: \(thermal)",
                    "offline mode: \(NetworkPolicy.isOffline ? "on" : "off")",
                    "low power mode: \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off")"]
        }
        return info.joined(separator: "\n")
    }
}
