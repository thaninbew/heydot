import Darwin
import Foundation

/// The listener's own cost, separate from the rest of the app (UI, web view, sockets).
///
/// CPU: every piece of listener work measures the CPU time its own thread spent on it
/// (`CLOCK_THREAD_CPUTIME_ID` before and after): the input tap callback (format conversion to 16 kHz) and
/// the processing block (keyword spotting decode, level metering, tuning segmentation). The sum only grows;
/// readers turn deltas into percent of one core per wall-second.
///
/// Memory: an estimate, labelled as one in the UI. It is the physical-footprint growth measured while the
/// first keyword model loaded (never less than the model files on disk), times the models loaded now, plus
/// the bounded audio queue. Allocator reuse and other threads make the footprint delta approximate.
public enum ListenerMeter {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var nanoseconds: UInt64 = 0
    nonisolated(unsafe) private static var modelBytes: Int?
    nonisolated(unsafe) private static var loadedModels = 0

    /// Upper bound of queued audio: 8 blocks of up to ~1.4 k Float samples, plus the tap's 2048-frame buffer.
    static let bufferBytes = 8 * 1_400 * 4 + 2048 * 4 * 2

    /// Total CPU seconds spent on listener work since launch.
    public static var cpuSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(nanoseconds) / 1_000_000_000
    }

    /// Estimated bytes held by the listener now; 0 when no model is loaded.
    public static var estimatedBytes: Int {
        lock.lock(); defer { lock.unlock() }
        guard loadedModels > 0 else { return 0 }
        return (modelBytes ?? 0) * loadedModels + bufferBytes
    }

    /// The per-model estimate once a model has loaded (for diagnostics).
    public static var modelEstimateBytes: Int? {
        lock.lock(); defer { lock.unlock() }
        return modelBytes
    }

    /// Runs `work` and adds the CPU time this thread spent in it.
    @inline(__always)
    static func measure<T>(_ work: () throws -> T) rethrows -> T {
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        defer {
            let spent = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- start
            lock.lock(); nanoseconds &+= spent; lock.unlock()
        }
        return try work()
    }

    /// Wraps a model load: the first one measures footprint growth for the memory estimate.
    static func loadingModel<T>(filesOnDisk: Int, _ load: () throws -> T) rethrows -> T {
        lock.lock(); let measured = modelBytes != nil; lock.unlock()
        let before = measured ? 0 : footprint()
        let value = try load()
        lock.lock()
        if modelBytes == nil { modelBytes = max(filesOnDisk, footprint() - before) }
        loadedModels += 1
        lock.unlock()
        return value
    }

    static func unloadedModel() {
        lock.lock(); loadedModels = max(0, loadedModels - 1); lock.unlock()
    }

    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return r == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}
