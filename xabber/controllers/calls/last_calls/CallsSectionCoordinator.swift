//
//  CallsSectionCoordinator.swift
//  xabber
//
//  Created by Codex on 25.05.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import Foundation

struct CallsSectionCoordinator {
    struct Controllers {
        let categoriesController: CallsCategoriesViewController?
        let listController: LastCallsViewController
    }

    static func makeControllers(
        regularWidth: Bool,
        leftMenuDelegate: LeftMenuSelectRootScreenDelegate? = nil
    ) -> Controllers {
        let listController = LastCallsViewController()
        listController.leftMenuDelegate = leftMenuDelegate

        guard regularWidth else {
            return Controllers(categoriesController: nil, listController: listController)
        }

        let categoriesController = CallsCategoriesViewController()
        wire(
            categoriesController: categoriesController,
            listController: listController,
            leftMenuDelegate: leftMenuDelegate
        )

        return Controllers(categoriesController: categoriesController, listController: listController)
    }

    static func wire(
        categoriesController: CallsCategoriesViewController,
        listController: LastCallsViewController,
        leftMenuDelegate: LeftMenuSelectRootScreenDelegate?
    ) {
        categoriesController.filterDelegate = listController
        categoriesController.leftMenuDelegate = leftMenuDelegate
        listController.leftMenuDelegate = leftMenuDelegate
    }
}
