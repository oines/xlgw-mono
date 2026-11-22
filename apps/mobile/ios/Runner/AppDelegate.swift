import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "HarborDailyReminder") {
      let channel = FlutterMethodChannel(
        name: "harbor/wellbeing/daily",
        binaryMessenger: registrar.messenger()
      )
      channel.setMethodCallHandler { call, reply in
        let center = UNUserNotificationCenter.current()
        let identifier = "harbor.wellbeing.daily"
        func respond(_ value: Any?) {
          DispatchQueue.main.async { reply(value) }
        }
        switch call.method {
        case "isEnabled":
          center.getPendingNotificationRequests { requests in
            respond(requests.contains(where: { $0.identifier == identifier }))
          }
        case "setEnabled":
          guard call.arguments as? Bool == true else {
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
            respond(false)
            return
          }
          center.requestAuthorization(options: [.alert]) { allowed, error in
            guard allowed, error == nil else {
              respond(false)
              return
            }
            let content = UNMutableNotificationContent()
            content.title = "心灵港湾"
            content.body = "早安。今天也可以按自己的节奏来。"
            let trigger = UNCalendarNotificationTrigger(
              dateMatching: DateComponents(hour: 7, minute: 30),
              repeats: true
            )
            center.add(
              UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
            ) { error in
              respond(error == nil)
            }
          }
        default:
          reply(FlutterMethodNotImplemented)
        }
      }
    }
  }
}
