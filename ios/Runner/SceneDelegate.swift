import Flutter
import UIKit

final class SceneDelegate: FlutterSceneDelegate {
  private var appDelegate: AppDelegate? {
    UIApplication.shared.delegate as? AppDelegate
  }

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(
      scene,
      willConnectTo: session,
      options: connectionOptions
    )
    appDelegate?.connectSceneWindow(
      window,
      isActive: scene.activationState == .foregroundActive,
      protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable
    )
  }

  override func sceneWillResignActive(_ scene: UIScene) {
    appDelegate?.sceneWillResignActive(window: window)
    super.sceneWillResignActive(scene)
  }

  override func sceneDidEnterBackground(_ scene: UIScene) {
    appDelegate?.sceneDidEnterBackground(window: window)
    super.sceneDidEnterBackground(scene)
  }

  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    appDelegate?.sceneDidBecomeActive(
      window: window,
      protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable
    )
  }

  override func sceneDidDisconnect(_ scene: UIScene) {
    let disconnectedWindow = window
    super.sceneDidDisconnect(scene)
    appDelegate?.disconnectSceneWindow(disconnectedWindow)
  }
}
