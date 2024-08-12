//
//  NotificationsControllerFilterProtocol.swift
//  xabber
//
//  Created by Игорь Болдин on 07.08.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation

protocol NotificationsControllerFilterProtocol {
    func shouldFilterBy(account: String?)
    func shouldFilterBy(category: String?)
}
