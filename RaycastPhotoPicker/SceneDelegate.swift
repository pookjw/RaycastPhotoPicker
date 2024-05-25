//
//  SceneDelegate.swift
//  RaycastPhotoPicker
//
//  Created by Jinwoo Kim on 5/19/24.
//

import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        let window: UIWindow = .init(windowScene: scene as! UIWindowScene)
        let rootViewController: ViewController = .init()
        let navigationController: UINavigationController = .init(rootViewController: rootViewController)
        window.rootViewController = navigationController
        self.window = window
        window.makeKeyAndVisible()
    }
}
