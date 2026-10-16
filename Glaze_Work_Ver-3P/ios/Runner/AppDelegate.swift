import Flutter
import UIKit
import WebKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let backgroundAudio = BackgroundAudioManager()
  private let systemSettingsChannelName = "app.glaze.flutter/system_settings"
  private let powerSaveEventsChannelName = "app.glaze.flutter/power_save_events"
  private let powerSaveStreamHandler = PowerSaveStreamHandler()
  private let hiddenWebViewsChannelName = "app.glaze.flutter/hidden_webviews"
  private var hideTimer: Timer?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let didFinishLaunching = super.application(
      application,
      didFinishLaunchingWithOptions: launchOptions
    )

    NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.startHideBurst()
    }

    return didFinishLaunching
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    return super.application(app, open: url, options: options)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    if let settingsRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "GlazeSystemSettings") {
      let settingsChannel = FlutterMethodChannel(
        name: systemSettingsChannelName,
        binaryMessenger: settingsRegistrar.messenger()
      )
      settingsChannel.setMethodCallHandler { [weak self] call, result in
        switch call.method {
        case "openNotificationSettings":
          self?.openNotificationSettings()
          result(nil)
        case "isPowerSaveMode":
          result(ProcessInfo.processInfo.isLowPowerModeEnabled)
        default:
          result(FlutterMethodNotImplemented)
        }
      }

      FlutterEventChannel(
        name: powerSaveEventsChannelName,
        binaryMessenger: settingsRegistrar.messenger()
      ).setStreamHandler(powerSaveStreamHandler)
    }

    if let hiddenRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "GlazeHiddenWebViews") {
      let hiddenChannel = FlutterMethodChannel(
        name: hiddenWebViewsChannelName,
        binaryMessenger: hiddenRegistrar.messenger()
      )
      hiddenChannel.setMethodCallHandler { [weak self] call, result in
        switch call.method {
        case "hide":
          self?.hideDesktopSizedWebViews()
          self?.startHideBurst()
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "GlazeBackgroundAudio") else { return }
    let channel = FlutterMethodChannel(
      name: "com.hydall.glaze/background_audio",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      switch call.method {
      case "start":
        self?.backgroundAudio.start()
        result(nil)
      case "stop":
        self?.backgroundAudio.stop()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// The CrushOn site reader drives hidden WKWebViews. On iOS the plugin can leave
  /// one attached to the key window, where it paints over the app (the site's
  /// art popping up full-screen while you scroll the catalog).
  ///
  /// How a reader view is recognised (the old rule was "wider than 900pt", which
  /// never matched when the plugin sized the view to the screen):
  ///   1. it carries the reader's marker comment in its injected user script
  ///      (set from Dart, invisible to the website), or
  ///   2. on iPhone only: it is >= 900pt wide (nothing real is that wide there).
  ///
  /// Hiding keeps the view alive (alpha 0, not isHidden) so its JavaScript and
  /// scrolling keep working, and also pushes it behind everything and off-screen
  /// so a stray alpha reset can never show it.
  private static let readerMarker = "GLAZE_HIDDEN_READER"

  private func isReaderWebView(_ view: UIView) -> Bool {
    guard let web = view as? WKWebView else { return false }
    for script in web.configuration.userContentController.userScripts
    where script.source.contains(AppDelegate.readerMarker) {
      return true
    }
    return UIDevice.current.userInterfaceIdiom == .phone && web.bounds.width >= 900
  }

  /// Returns how many reader views were found (and hidden).
  @discardableResult
  private func hideDesktopSizedWebViews() -> Int {
    var found = 0
    for scene in UIApplication.shared.connectedScenes {
      guard let windowScene = scene as? UIWindowScene else { continue }
      for window in windowScene.windows {
        found += hideReaderWebViews(in: window)
      }
    }
    return found
  }

  private func hideReaderWebViews(in view: UIView) -> Int {
    if isReaderWebView(view) {
      view.alpha = 0
      view.isUserInteractionEnabled = false
      view.layer.zPosition = -1
      let away = CGAffineTransform(translationX: -20000, y: 0)
      if view.transform != away { view.transform = away }
      view.superview?.sendSubviewToBack(view)
      return 1
    }
    var found = 0
    for sub in view.subviews {
      found += hideReaderWebViews(in: sub)
    }
    return found
  }

  /// Keeps catching reader views for as long as any exist (plus 15 s after the
  /// last one). The reader keeps scrolling for many seconds per request, so a
  /// short fixed burst left the view exposed. The timer runs in the .common
  /// modes so it also fires while the user is touching / scrolling.
  private func startHideBurst() {
    hideTimer?.invalidate()
    var quietTicks = 0
    let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] timer in
      guard let self = self else {
        timer.invalidate()
        return
      }
      if self.hideDesktopSizedWebViews() > 0 {
        quietTicks = 0
      } else {
        quietTicks += 1
      }
      if quietTicks >= 60 {
        timer.invalidate()
        self.hideTimer = nil
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    hideTimer = timer
  }

  private func openNotificationSettings() {
    let urlString: String
    if #available(iOS 16.0, *) {
      urlString = UIApplication.openNotificationSettingsURLString
    } else {
      urlString = UIApplication.openSettingsURLString
    }

    guard let url = URL(string: urlString), UIApplication.shared.canOpenURL(url) else {
      return
    }

    UIApplication.shared.open(url)
  }
}

/// Pushes Low Power Mode on every change. Polling cannot see the moment the
/// phone flips, which is the only thing "follow the system" is about;
/// `NSProcessInfoPowerStateDidChange` is the notification that can.
private class PowerSaveStreamHandler: NSObject, FlutterStreamHandler {
  private var sink: FlutterEventSink?

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    sink = events
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(powerStateChanged),
      name: Notification.Name.NSProcessInfoPowerStateDidChange,
      object: nil
    )
    // Seed the stream so a listener that attached after a change still starts
    // from the truth rather than from its own default.
    events(ProcessInfo.processInfo.isLowPowerModeEnabled)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    NotificationCenter.default.removeObserver(self)
    sink = nil
    return nil
  }

  @objc private func powerStateChanged() {
    sink?(ProcessInfo.processInfo.isLowPowerModeEnabled)
  }
}
