import Darwin
import Foundation

public enum MemoryPressure: Int, Sendable, Comparable {
    case normal = 1, warning = 2, critical = 4
    public static func < (a: MemoryPressure, b: MemoryPressure) -> Bool { a.rawValue < b.rawValue }
    public var label: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }
}

/// R-9: the same numbers Activity Monitor shows.
public struct MemoryStatus: Sendable, Equatable {
    public var total: UInt64
    public var used: UInt64
    public var swapUsed: UInt64
    public var swapTotal: UInt64
    public var pressure: MemoryPressure

    public static func current() -> MemoryStatus {
        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &size, nil, 0)

        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var page: vm_size_t = 0
        host_page_size(mach_host_self(), &page)
        var used: UInt64 = 0
        if kr == KERN_SUCCESS {
            let app = UInt64(vm.internal_page_count) &- UInt64(vm.purgeable_count)
            used = (app + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * UInt64(page)
        }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        var level: Int32 = 1
        var levelSize = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0)

        return MemoryStatus(total: total, used: min(used, total), swapUsed: swap.xsu_used, swapTotal: swap.xsu_total,
                            pressure: MemoryPressure(rawValue: Int(level)) ?? .normal)
    }
}
