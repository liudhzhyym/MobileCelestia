//
//  SettingsCoordinatorController.swift
//  CelestiaMobile
//
//  Created by 李林峰 on 2020/2/24.
//  Copyright © 2020 李林峰. All rights reserved.
//

import UIKit

class SettingsCoordinatorController: UIViewController {

    private var main: SettingsMainViewController!
    private var navigation: UINavigationController!

    override var preferredContentSize: CGSize {
        set {}
        get { return CGSize(width: 300, height: 300) }
    }

    override func loadView() {
        view = UIView()
        view.backgroundColor = .darkBackground
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        setup()
    }

}

private extension SettingsCoordinatorController {
    func setup() {
        main = SettingsMainViewController(selection: { [weak self] (item) in
            guard let self = self else { return }
            switch item.type {
            case .checkmarks(let masterKey, let items):
                let controller = SettingCheckViewController(item: SettingCheckViewController.Item(title: item.name, masterKey: masterKey, subitems: items))
                self.navigation.pushViewController(controller, animated: true)
            }
        })
        navigation = UINavigationController(rootViewController: main)

        install(navigation)

        navigation.navigationBar.barStyle = .black
        navigation.navigationBar.titleTextAttributes?[.foregroundColor] = UIColor.darkLabel
    }
}
