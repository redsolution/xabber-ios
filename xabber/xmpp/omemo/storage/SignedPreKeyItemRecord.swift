//
//  SignedPreKeyItemRecord.swift
//  clandestino
//
//  Created by Игорь Болдин on 23.03.2023.
//  Copyright © 2023 Igor Boldin. All rights reserved.
//

import Foundation
import Curve25519Kit

struct SignedPreKeyItemRecord {
    let key: ECKeyPair
    let signature: Data
}
