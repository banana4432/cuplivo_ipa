//
//  BackgroundKeepAliveManager.swift
//  Runner
//
//  Advanced iOS background keep-alive, ported from the OpenMinis
//  BackgroundKeepAliveManager design. Keeps the process alive while a
//  generation task is running and the app is in the background through
//  three cooperating mechanisms:
//
//   1. Silent audio keep-alive — an AVAudioEngine playing an inaudible
//      looping track (UIBackgroundModes: audio). This is the primary
//      long-lived leg: while it plays, iOS does not suspend the process,
//      so finite background tasks can be re-armed instead of dying.
//
//   2. Location keep-alive — coarse CLLocationManager updates (5s
//      heartbeat on iOS 16, continuous CLLocationUpdate.liveUpdates on
//      iOS 17+ with CLBackgroundActivitySession, UIBackgroundModes:
//      location). Armed only 15s after the app enters the background so
//      brief background blips never spin up location.
//
//   3. Finite background task coordination — AppDelegate consults
//      `keepAliveEffective` when its UIBackgroundTask expires: when the
//      silent-audio leg is active it re-arms the task instead of letting
//      the agent loop die.
//
//  All legs are gated on user toggles pushed from Dart via the
//  `app.ios_keepalive` MethodChannel. Nothing starts behind the user's
//  back.
//

import AVFoundation
import CoreLocation
import Flutter
import UIKit

@MainActor
final class BackgroundKeepAliveManager: NSObject, CLLocationManagerDelegate {
  static let shared = BackgroundKeepAliveManager()

  static let channelName = "app.ios_keepalive"

  // MARK: - Configuration (pushed from Dart)

  private(set) var masterEnabled = false
  private(set) var silentAudioEnabled = false
  private(set) var locationEnabled = false
  private(set) var liveActivityPrivacyMode = false

  // MARK: - Runtime state

  private(set) var sessionActive = false
  private(set) var appIsInBackground = false
  private(set) var silentAudioActive = false
  private(set) var locationUpdating = false
  private(set) var backgroundLocationArmed = false
  private var backgroundLocationArmTimer: Timer?
  private var locationTimer: Timer?
  private var bgActivitySession: Any?
  private var liveUpdatesTask: Task<Void, Never>?

  // MARK: - Interruption tracking

  private(set) var interruptionCount = 0
  private(set) var lastInterruptedAt: Date?

  // MARK: - Silent audio

  private var audioEngine: AVAudioEngine?
  private var silentPlayerNode: AVAudioPlayerNode?
  private var silentAudioActivationRetries = 0
  private var silentAudioSuspendCount = 0
  private var pendingSilentAudioStop: DispatchWorkItem?

  // MARK: - Location

  private let locationManager = CLLocationManager()
  private var locationAuthStatus: CLAuthorizationStatus = .notDetermined
  private var pendingLocationAuthResult: FlutterResult?

  private static let backgroundLocationArmDelay: TimeInterval = 15.0
  private static let locationHeartbeatInterval: TimeInterval = 5.0
  private static let maxActivationRetries = 3
  private static let activationRetryDelay: TimeInterval = 0.5
  private static let silentAudioStopDebounce: TimeInterval = 1.5
  private static let routeChangeReevalDelay: TimeInterval = 0.5

  private override init() {
    super.init()
    locationManager.delegate = self
    locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    locationManager.pausesLocationUpdatesAutomatically = false
    if #available(iOS 14.0, *) {
      locationAuthStatus = locationManager.authorizationStatus
    } else {
      locationAuthStatus = CLLocationManager.authorizationStatus()
    }
    // A CLBackgroundActivitySession outlives process death by design; if the
    // previous process was force-killed without invalidating it, iOS keeps
    // the system location indicator pinned. Retract any orphan on cold start.
    if #available(iOS 17.0, *) {
      let probe = CLBackgroundActivitySession()
      probe.invalidate()
    }
    observeLifecycle()
    observeAudioInterruptions()
  }

  // MARK: - MethodChannel

  func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "configure":
      let args = call.arguments as? [String: Any] ?? [:]
      configure(
        masterEnabled: args["masterEnabled"] as? Bool ?? false,
        silentAudioEnabled: args["silentAudioEnabled"] as? Bool ?? false,
        locationEnabled: args["locationEnabled"] as? Bool ?? false,
        liveActivityPrivacyMode: args["liveActivityPrivacyMode"] as? Bool ?? false
      )
      result(true)
    case "beginSession":
      sessionActive = true
      evaluateKeepAlive(caller: "beginSession")
      result(true)
    case "endSession":
      sessionActive = false
      evaluateKeepAlive(caller: "endSession")
      result(true)
    case "getStatus":
      result(statusMap())
    case "requestLocationAuthorization":
      requestLocationAuthorization(result: result)
    case "suspendSilentAudio":
      suspendSilentAudio()
      result(true)
    case "resumeSilentAudio":
      resumeSilentAudio()
      result(true)
    case "recordInterruption":
      recordInterruption()
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Lifecycle

  private func observeLifecycle() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(didEnterBackground),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(willEnterForeground),
      name: UIApplication.willEnterForegroundNotification,
      object: nil
    )
  }

  @objc private func didEnterBackground() {
    appIsInBackground = true
    evaluateKeepAlive(caller: "didEnterBackground")
    scheduleBackgroundLocationArming()
  }

  @objc private func willEnterForeground() {
    appIsInBackground = false
    backgroundLocationArmed = false
    backgroundLocationArmTimer?.invalidate()
    backgroundLocationArmTimer = nil
    evaluateKeepAlive(caller: "willEnterForeground")
    cleanupLocationStateOnForeground()
  }

  // MARK: - Audio interruption / route-change recovery

  private func observeAudioInterruptions() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAudioInterruption(_:)),
      name: AVAudioSession.interruptionNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleRouteChange(_:)),
      name: AVAudioSession.routeChangeNotification,
      object: nil
    )
  }

  @objc private func handleAudioInterruption(_ note: Notification) {
    guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
    if type == .ended {
      // Interruption over (e.g. phone call finished) — reclaim the session.
      evaluateKeepAlive(caller: "interruptionEnded")
    }
  }

  @objc private func handleRouteChange(_ note: Notification) {
    // Route changes (headphones unplugged, Bluetooth drop, …) can tear down
    // our audio session. Re-evaluate shortly after to restart if wanted.
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.routeChangeReevalDelay) { [weak self] in
      self?.evaluateKeepAlive(caller: "routeChange")
    }
  }

  // MARK: - Configuration

  func configure(
    masterEnabled: Bool,
    silentAudioEnabled: Bool,
    locationEnabled: Bool,
    liveActivityPrivacyMode: Bool
  ) {
    self.masterEnabled = masterEnabled
    self.silentAudioEnabled = silentAudioEnabled
    self.locationEnabled = locationEnabled
    self.liveActivityPrivacyMode = liveActivityPrivacyMode
    evaluateKeepAlive(caller: "configure")
  }

  // MARK: - Status

  var keepAliveEffective: Bool {
    silentAudioActive || locationUpdating
  }

  var isLocationAuthorized: Bool {
    locationAuthStatus == .authorizedAlways || locationAuthStatus == .authorizedWhenInUse
  }

  private var survivalTier: String {
    let locationLeg = masterEnabled && locationEnabled && isLocationAuthorized
    let audioLeg = masterEnabled && silentAudioEnabled
    if locationLeg || audioLeg { return "extended" }
    return "short"
  }

  private func statusMap() -> [String: Any] {
    [
      "masterEnabled": masterEnabled,
      "silentAudioEnabled": silentAudioEnabled,
      "locationEnabled": locationEnabled,
      "liveActivityPrivacyMode": liveActivityPrivacyMode,
      "sessionActive": sessionActive,
      "appIsInBackground": appIsInBackground,
      "silentAudioActive": silentAudioActive,
      "locationUpdating": locationUpdating,
      "locationArmed": backgroundLocationArmed,
      "locationAuthorized": isLocationAuthorized,
      "survivalTier": survivalTier,
      "interruptionCount": interruptionCount,
      "lastInterruptedAt": lastInterruptedAt?.timeIntervalSince1970 ?? 0,
    ]
  }

  // MARK: - Keep-alive decision

  private func evaluateKeepAlive(caller: String) {
    let shouldPlay = masterEnabled && silentAudioEnabled && sessionActive
      && appIsInBackground && silentAudioSuspendCount == 0
    if shouldPlay && !silentAudioActive {
      cancelPendingSilentAudioStop()
      startSilentAudio()
    } else if !shouldPlay && silentAudioActive {
      requestStopSilentAudio(transientForeground: !appIsInBackground)
    }
    evaluateLocationUpdates()
    evaluateBackgroundActivitySession()
  }

  // MARK: - Silent audio keep-alive

  private func startSilentAudio(reason: String = "evaluate") {
    guard !silentAudioActive else { return }
    silentAudioActivationRetries = 0

    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
      try session.setActive(true)
    } catch {
      scheduleSilentAudioActivationRetry()
      return
    }

    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    engine.attach(player)

    let sampleRate: Double = 44100
    let frameCount = AVAudioFrameCount(sampleRate)
    guard let format = AVAudioFormat(
      standardFormatWithSampleRate: sampleRate, channels: 1
    ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
      return
    }
    buffer.frameLength = frameCount
    // Zero-filled buffer = pure silence.

    engine.connect(player, to: engine.mainMixerNode, format: format)
    engine.mainMixerNode.outputVolume = 0.001

    do {
      try engine.start()
      player.scheduleBuffer(buffer, at: nil, options: .loops)
      player.play()
      audioEngine = engine
      silentPlayerNode = player
      silentAudioActive = true
    } catch {
      scheduleSilentAudioActivationRetry()
    }
  }

  private func scheduleSilentAudioActivationRetry() {
    silentAudioActivationRetries += 1
    guard silentAudioActivationRetries < Self.maxActivationRetries else {
      silentAudioActivationRetries = 0
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.activationRetryDelay) { [weak self] in
      guard let self else { return }
      let stillWanted = self.masterEnabled && self.silentAudioEnabled
        && self.sessionActive && self.appIsInBackground
        && self.silentAudioSuspendCount == 0 && !self.silentAudioActive
      guard stillWanted else { return }
      self.startSilentAudio(reason: "activationRetry")
    }
  }

  /// Stop silent audio, debounced when the trigger is a transient foreground
  /// blip (app switcher peek, call ended, Control Center, …) — a background
  /// signal arriving within the window cancels the stop. Other triggers
  /// (session ended, media suspend, toggle off) stop immediately.
  private func requestStopSilentAudio(transientForeground: Bool) {
    guard transientForeground else {
      cancelPendingSilentAudioStop()
      stopSilentAudio()
      return
    }
    guard pendingSilentAudioStop == nil else { return }
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.pendingSilentAudioStop = nil
      // Re-check the world at fire time: if we went back to background (or
      // any other reason now keeps it playing), do NOT stop.
      let stillForeground = !self.appIsInBackground
      let stillActive = self.masterEnabled && self.silentAudioEnabled
        && self.sessionActive && self.silentAudioSuspendCount == 0
      if stillForeground || !stillActive {
        self.stopSilentAudio()
      }
    }
    pendingSilentAudioStop = work
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Self.silentAudioStopDebounce, execute: work
    )
  }

  private func cancelPendingSilentAudioStop() {
    pendingSilentAudioStop?.cancel()
    pendingSilentAudioStop = nil
  }

  private func stopSilentAudio() {
    silentAudioActivationRetries = 0
    guard silentAudioActive else { return }
    silentPlayerNode?.stop()
    audioEngine?.stop()
    silentPlayerNode = nil
    audioEngine = nil
    silentAudioActive = false
    do {
      try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    } catch {
      // Ignore — session teardown failures are harmless.
    }
  }

  /// Temporary suspend while user media (TTS / audio player) is active.
  /// Called from Dart around media playback; counter-based so nested
  /// play/pause sequences balance correctly.
  func suspendSilentAudio() {
    silentAudioSuspendCount += 1
    if silentAudioActive {
      stopSilentAudio()
    }
  }

  func resumeSilentAudio() {
    silentAudioSuspendCount = max(0, silentAudioSuspendCount - 1)
    if silentAudioSuspendCount == 0 && silentAudioActive == false {
      evaluateKeepAlive(caller: "resumeSilentAudio")
    }
  }

  // MARK: - Interruption tracking

  func recordInterruption() {
    interruptionCount += 1
    lastInterruptedAt = Date()
  }

  // MARK: - Location keep-alive

  private func scheduleBackgroundLocationArming() {
    guard appIsInBackground else { return }
    guard !backgroundLocationArmed, backgroundLocationArmTimer == nil else { return }
    let delay = Self.backgroundLocationArmDelay
    let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.backgroundLocationArmTimer = nil
        guard self.appIsInBackground else { return }
        self.backgroundLocationArmed = true
        self.evaluateLocationUpdates()
        self.evaluateBackgroundActivitySession()
      }
    }
    backgroundLocationArmTimer = timer
    RunLoop.current.add(timer, forMode: .common)
  }

  private func evaluateLocationUpdates() {
    let shouldUpdate = masterEnabled && locationEnabled && sessionActive
      && appIsInBackground && backgroundLocationArmed && isLocationAuthorized

    if shouldUpdate && !locationUpdating {
      locationManager.allowsBackgroundLocationUpdates = true
      locationManager.showsBackgroundLocationIndicator = false
      locationUpdating = true
      locationManager.requestLocation()
      let timer = Timer(timeInterval: Self.locationHeartbeatInterval, repeats: true) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.locationManager.requestLocation()
        }
      }
      locationTimer = timer
      RunLoop.current.add(timer, forMode: .common)
    } else if !shouldUpdate && locationUpdating {
      locationTimer?.invalidate()
      locationTimer = nil
      locationUpdating = false
      locationManager.allowsBackgroundLocationUpdates = false
    }
  }

  /// iOS 17+: continuous live-updates stream + CLBackgroundActivitySession.
  /// The liveUpdates(.otherNavigation) stream is what keeps the blue
  /// location indicator on screen continuously (and the process alive) —
  /// single-shot requestLocation() heartbeats do not.
  private func evaluateBackgroundActivitySession() {
    let shouldRun = masterEnabled && locationEnabled && isLocationAuthorized
      && sessionActive && appIsInBackground && backgroundLocationArmed
    if shouldRun && liveUpdatesTask == nil {
      startBackgroundActivitySession()
    } else if !shouldRun {
      stopBackgroundActivitySession()
    }
  }

  private func startBackgroundActivitySession() {
    guard liveUpdatesTask == nil else { return }
    if #available(iOS 17.0, *) {
      let session = CLBackgroundActivitySession()
      bgActivitySession = session
      liveUpdatesTask = Task { @MainActor [weak self] in
        guard let self else { return }
        do {
          let updates = CLLocationUpdate.liveUpdates(.otherNavigation)
          for try await update in updates {
            guard !Task.isCancelled else { break }
            // Location data is intentionally discarded — merely receiving
            // updates keeps the process (and indicator) alive.
          }
        } catch {
          // Transient stream errors are fine; next evaluation retries.
        }
        self.liveUpdatesTask = nil
      }
    }
  }

  private func stopBackgroundActivitySession() {
    liveUpdatesTask?.cancel()
    liveUpdatesTask = nil
    if #available(iOS 17.0, *), let session = bgActivitySession as? CLBackgroundActivitySession {
      session.invalidate()
      bgActivitySession = nil
    }
  }

  private func cleanupLocationStateOnForeground() {
    locationTimer?.invalidate()
    locationTimer = nil
    if locationUpdating {
      locationUpdating = false
      locationManager.allowsBackgroundLocationUpdates = false
    }
    stopBackgroundActivitySession()
  }

  func requestLocationAuthorization(result: @escaping FlutterResult) {
    if isLocationAuthorized {
      result(true)
      return
    }
    // Denied / restricted: requesting again never shows a prompt and the
    // delegate may not fire — resolve immediately so Dart doesn't hang.
    switch locationAuthStatus {
    case .denied, .restricted:
      result(false)
      return
    default:
      break
    }
    pendingLocationAuthResult = result
    if #available(iOS 14.0, *) {
      switch locationAuthStatus {
      case .notDetermined:
        locationManager.requestWhenInUseAuthorization()
      default:
        locationManager.requestAlwaysAuthorization()
      }
    } else {
      locationManager.requestAlwaysAuthorization()
    }
  }

  // MARK: - CLLocationManagerDelegate

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    if #available(iOS 14.0, *) {
      locationAuthStatus = manager.authorizationStatus
    }
    if let pending = pendingLocationAuthResult {
      pendingLocationAuthResult = nil
      pending(isLocationAuthorized)
    }
    evaluateKeepAlive(caller: "locationAuthChanged")
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    // Heartbeat locations are intentionally discarded — only the act of
    // receiving updates keeps the process alive.
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    // A transient failure is fine; the heartbeat timer keeps retrying.
  }
}
