import Flutter
import UIKit

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

    let channel = FlutterMethodChannel(
      name: "offline_ai/model_installer",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )

    channel.setMethodCallHandler { call, result in
      guard call.method == "installModel" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard
        let args = call.arguments as? [String: Any],
        let assetName = args["assetName"] as? String,
        let destPath = args["destPath"] as? String
      else {
        result(FlutterError(code: "bad_args", message: "assetName and destPath are required", details: nil))
        return
      }

      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let key = FlutterDartProject.lookupKey(forAsset: assetName)
          guard let sourcePath = Bundle.main.path(forResource: key, ofType: nil) else {
            throw NSError(domain: "offline_ai", code: 1, userInfo: [
              NSLocalizedDescriptionKey: "Bundled asset not found: \(assetName)"
            ])
          }

          let destination = URL(fileURLWithPath: destPath)
          try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
          )
          if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
          }
          try FileManager.default.copyItem(atPath: sourcePath, toPath: destination.path)
          DispatchQueue.main.async { result(true) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "copy_failed", message: error.localizedDescription, details: nil))
          }
        }
      }
    }
  }
}
