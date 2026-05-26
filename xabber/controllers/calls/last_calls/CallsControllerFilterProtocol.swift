//
//  CallsControllerFilterProtocol.swift
//  xabber
//
//  Created by Codex on 25.05.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import Foundation

protocol CallsControllerFilterProtocol: AnyObject {
    func shouldFilterBy(category: String?)
}
