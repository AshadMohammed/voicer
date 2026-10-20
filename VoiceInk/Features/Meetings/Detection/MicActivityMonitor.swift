import CoreAudio
import Foundation

/// One process that has audio input running right now.
struct MicProcess: Hashable, Sendable {
    let pid: pid_t
    let bundleID: String   // "" when Core Audio doesn't report one
}

/// Watches which processes have the microphone open, through Core Audio process objects.
/// Voicer's own process is always left out.
final class MicActivityMonitor: @unchecked Sendable {

    /// Called on the main queue with the full current set, only when it changes.
    /// Also called once right after `start()`.
    var onChange: ((Set<MicProcess>) -> Void)?

    private let queue = DispatchQueue(label: "com.prakashjoshipax.voiceink.MicActivityMonitor")
    private var started = false
    private var timer: DispatchSourceTimer?
    private var lastPublished = Set<MicProcess>()
    private let selfPID = getpid()

    // Listeners we installed, keyed by process object ID so we can remove them.
    private var processListenerBlock: AudioObjectPropertyListenerBlock?
    private var perObjectBlocks: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var knownObjects = Set<AudioObjectID>()

    init() {}

    /// Start monitoring. Idempotent.
    func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            installSystemListener()
            refreshObjectListeners()
            readAndPublish()
            startTimer()
        }
    }

    /// Stop monitoring. Idempotent; removes every listener and the timer.
    func stop() {
        queue.async { [self] in
            guard started else { return }
            started = false
            stopTimer()
            removeAllObjectListeners()
            removeSystemListener()
            lastPublished = []
        }
    }

    /// A one-off read of who has input running now. Safe from any thread. Excludes Voicer's own process.
    static func currentProcesses() -> Set<MicProcess> {
        let selfPID = getpid()
        var set = Set<MicProcess>()
        for obj in processObjectList() {
            guard isRunningInput(obj) else { continue }
            let pid = pidForObject(obj)
            guard pid != selfPID else { continue }
            let bundle = bundleIDForObject(obj)
            set.insert(MicProcess(pid: pid, bundleID: bundle))
        }
        return set
    }

    // MARK: - System object listener (process-object list changes)

    private func installSystemListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.queue.async {
                self?.refreshObjectListeners()
                self?.readAndPublish()
            }
        }
        processListenerBlock = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
    }

    private func removeSystemListener() {
        guard let block = processListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        processListenerBlock = nil
    }

    // MARK: - Per-object listeners (isRunningInput)

    private func refreshObjectListeners() {
        let current = Set(Self.processObjectList())
        let added = current.subtracting(knownObjects)
        let removed = knownObjects.subtracting(current)

        for obj in removed {
            removeObjectListener(obj)
        }
        for obj in added {
            addObjectListener(obj)
        }
        knownObjects = current
    }

    private func addObjectListener(_ obj: AudioObjectID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.queue.async {
                self?.readAndPublish()
            }
        }
        perObjectBlocks[obj] = block
        AudioObjectAddPropertyListenerBlock(obj, &address, queue, block)
    }

    private func removeObjectListener(_ obj: AudioObjectID) {
        guard let block = perObjectBlocks.removeValue(forKey: obj) else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(obj, &address, queue, block)
    }

    private func removeAllObjectListeners() {
        for obj in knownObjects {
            removeObjectListener(obj)
        }
        knownObjects = []
    }

    // MARK: - Timer (safety net)

    private func startTimer() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 3, repeating: 3)
        source.setEventHandler { [weak self] in
            self?.refreshObjectListeners()
            self?.readAndPublish()
        }
        source.resume()
        timer = source
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - Read and publish

    private func readAndPublish() {
        let processes = Self.currentProcesses()
        guard processes != lastPublished else { return }
        lastPublished = processes
        let callback = onChange
        DispatchQueue.main.async {
            callback?(processes)
        }
    }

    // MARK: - Core Audio helpers

    private static func processObjectList() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else { return [] }
        return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func isRunningInput(_ obj: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(obj, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    private static func pidForObject(_ obj: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        AudioObjectGetPropertyData(obj, &address, 0, nil, &size, &pid)
        return pid
    }

    private static func bundleIDForObject(_ obj: AudioObjectID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfStr: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &address, 0, nil, &size, &cfStr) == noErr,
              let retained = cfStr?.takeRetainedValue() else { return "" }
        return retained as String
    }
}
