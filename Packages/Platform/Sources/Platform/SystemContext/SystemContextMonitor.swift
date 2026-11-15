import AppKit
import CoreAudio
import Foundation
import IOKit.ps
import Kit
import KitHosting

/// Feeds a ``SystemContextCenter`` from the Mac: power source changes from IOKit, display changes
/// from AppKit, the default output device from CoreAudio, the frontmost app from a
/// ``FrontmostTracker``, and session starts from wake and screen unlock notifications. Read-only;
/// nothing here prompts.
///
/// CoreAudio runs on a private queue, never on the main thread: the first CoreAudio call in a
/// process starts the audio system and waited 35 to 39 ms on macOS 27.2.
@MainActor public final class SystemContextMonitor {
    private let center: SystemContextCenter
    private let frontmost: FrontmostTracker
    private let clock: any ClockService
    private let audio: AudioWatch
    private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []
    private var powerSource: CFRunLoopSource?
    private var frontmostTask: Task<Void, Never>?

    /// - Parameter audioRoute: Reads where sound plays, on the monitor's audio queue. Nil reads the
    ///   default output device.
    public init(
        center: SystemContextCenter, frontmost: FrontmostTracker, clock: any ClockService,
        audioRoute: (@Sendable () -> SystemContext.AudioRoute)? = nil
    ) {
        self.center = center
        self.frontmost = frontmost
        self.clock = clock
        audio = AudioWatch(center: center, readRoute: audioRoute ?? { SystemReadings.audioRoute() })
    }

    /// Stops listening when the monitor goes away without ``stop()``. Without this the power
    /// source kept an unretained pointer to the freed monitor and the frontmost stream stayed open.
    isolated deinit {
        stop()
    }

    /// True between ``start()`` and ``stop()``.
    public var isRunning: Bool { frontmostTask != nil }

    /// Reads everything once and starts listening. Calling it again does nothing. The audio route
    /// arrives shortly after, from the audio queue.
    public func start() {
        guard !isRunning else { return }
        let app = frontmost.current
        center.update { context in
            context.frontmostBundleID = app?.bundleID
            context.onBattery = SystemReadings.isOnBattery()
            context.displayCount = SystemReadings.displayCount()
            context.isFocusOn = false
        }
        startPower()
        audio.start()
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [center] in
            let count = SystemReadings.displayCount()
            center.update { $0.displayCount = count }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didWakeNotification) { [weak self] in self?.sessionStarted() }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in self?.sessionStarted() }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked")) {
            [weak self] in self?.sessionStarted()
        }
        let changes = frontmost.changes()
        frontmostTask = Task { [center] in
            for await app in changes {
                center.update { $0.frontmostBundleID = app?.bundleID }
            }
        }
    }

    /// Stops listening. The audio listeners go on the audio queue, in order with any start.
    public func stop() {
        for observer in observers {
            observer.center.removeObserver(observer.token)
        }
        observers = []
        if let powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .defaultMode)
            CFRunLoopSourceInvalidate(powerSource)
        }
        powerSource = nil
        audio.stop()
        frontmostTask?.cancel()
        frontmostTask = nil
    }

    private func sessionStarted() {
        center.sessionStarted(at: clock.now)
    }

    private func observe(
        _ notifications: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor () -> Void
    ) {
        let token = notifications.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated(handler)
        }
        observers.append((notifications, token))
    }

    private func startPower() {
        // The run loop source holds this object unretained; stop() removes it before release.
        let context = Unmanaged.passUnretained(self).toOpaque()
        let source = IOPSNotificationCreateRunLoopSource(
            { context in
                guard let context, Thread.isMainThread else { return }
                let monitor = Unmanaged<SystemContextMonitor>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { monitor.powerChanged() }
            }, context)?.takeRetainedValue()
        guard let source else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        powerSource = source
    }

    private func powerChanged() {
        let onBattery = SystemReadings.isOnBattery()
        center.update { $0.onBattery = onBattery }
    }
}

/// The audio half of the monitor: the route read and the CoreAudio listeners, all on one private
/// serial queue.
nonisolated final class AudioWatch: @unchecked Sendable {
    private let center: SystemContextCenter
    private let readRoute: @Sendable () -> SystemContext.AudioRoute
    private let queue = DispatchQueue(label: "platform.system-context.audio", qos: .utility)
    /// On `queue`.
    private var isRunning = false
    /// On `queue`.
    private var deviceListener: AudioObjectPropertyListenerBlock?
    /// On `queue`.
    private var dataSource: (device: AudioObjectID, listener: AudioObjectPropertyListenerBlock)?

    init(center: SystemContextCenter, readRoute: @escaping @Sendable () -> SystemContext.AudioRoute) {
        self.center = center
        self.readRoute = readRoute
    }

    private static let defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private static let dataSourceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDataSource, mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    /// Reads the route and listens for a new default output device, and for a new data source on
    /// the current one, which is how the built-in device reports headphones. Returns at once.
    func start() {
        queue.async { [self] in
            guard !isRunning else { return }
            isRunning = true
            routeChanged()
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.outputDeviceChanged() }
            var address = Self.defaultOutputAddress
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
                == noErr
            {
                deviceListener = listener
            }
            watchDataSource()
        }
    }

    /// Removes the listeners on the queue. Returns at once: the queue may still be starting the
    /// audio system, which takes tens of milliseconds.
    func stop() {
        queue.async { [self] in
            isRunning = false
            if let deviceListener {
                var address = Self.defaultOutputAddress
                AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject), &address, queue, deviceListener)
            }
            deviceListener = nil
            stopWatchingDataSource()
        }
    }

    /// On `queue`.
    private func outputDeviceChanged() {
        guard isRunning else { return }
        watchDataSource()
        routeChanged()
    }

    /// On `queue`.
    private func routeChanged() {
        let route = readRoute()
        center.update { $0.audioRoute = route }
    }

    /// Moves the data source listener to the current default output device. On `queue`.
    private func watchDataSource() {
        stopWatchingDataSource()
        guard let device = SystemReadings.defaultOutputDevice() else { return }
        var address = Self.dataSourceAddress
        guard AudioObjectHasProperty(device, &address) else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.isRunning else { return }
            self.routeChanged()
        }
        if AudioObjectAddPropertyListenerBlock(device, &address, queue, listener) == noErr {
            dataSource = (device, listener)
        }
    }

    /// On `queue`.
    private func stopWatchingDataSource() {
        guard let dataSource else { return }
        var address = Self.dataSourceAddress
        AudioObjectRemovePropertyListenerBlock(dataSource.device, &address, queue, dataSource.listener)
        self.dataSource = nil
    }
}
