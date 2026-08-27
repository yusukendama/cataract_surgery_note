import Flutter
import Foundation
import UIKit

final class AnalysisTimeEventStreamHandler: NSObject, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?
  private var observers: [NSObjectProtocol] = []

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    removeObservers()
    eventSink = events
    let center = NotificationCenter.default
    observers = [
      center.addObserver(
        forName: UIApplication.significantTimeChangeNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in self?.emitChange() },
      center.addObserver(
        forName: NSNotification.Name.NSSystemTimeZoneDidChange,
        object: nil,
        queue: .main
      ) { [weak self] _ in self?.emitChange() },
    ]
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    removeObservers()
    return nil
  }

  private func emitChange() {
    eventSink?(["kind": "contextChanged"])
  }

  private func removeObservers() {
    let center = NotificationCenter.default
    for observer in observers {
      center.removeObserver(observer)
    }
    observers.removeAll()
  }

  deinit {
    removeObservers()
  }
}
