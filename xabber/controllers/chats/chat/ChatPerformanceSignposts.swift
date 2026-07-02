//
//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//
//

import Foundation
import os.signpost

enum ChatPerformanceSignpostPhase: String, CaseIterable {
    case chatOpenToFirstFrame = "chat.open_to_first_frame"
    case mapDataset = "chat.map_dataset"
    case datasourceDiff = "chat.datasource_diff"
    case datasourceApply = "chat.datasource_apply"
    case layoutApply = "chat.layout_apply"
    case scrollProcessing = "chat.scroll_processing"
    case sendToLocalRow = "chat.send_to_local_row"

    var signpostName: StaticString {
        switch self {
        case .chatOpenToFirstFrame:
            return "chat.open_to_first_frame"
        case .mapDataset:
            return "chat.map_dataset"
        case .datasourceDiff:
            return "chat.datasource_diff"
        case .datasourceApply:
            return "chat.datasource_apply"
        case .layoutApply:
            return "chat.layout_apply"
        case .scrollProcessing:
            return "chat.scroll_processing"
        case .sendToLocalRow:
            return "chat.send_to_local_row"
        }
    }
}

enum ChatPerformanceSignposts {
    static let subsystem = "com.xabber.ios.chat"
    static let category = "performance"

    private static let log = OSLog(subsystem: subsystem, category: category)

    struct Interval {
        let phase: ChatPerformanceSignpostPhase

        private let signpostID: OSSignpostID
        private var didEnd = false

        fileprivate init(phase: ChatPerformanceSignpostPhase) {
            self.phase = phase
            let signpostID = OSSignpostID(log: ChatPerformanceSignposts.log)
            self.signpostID = signpostID
            os_signpost(
                .begin,
                log: ChatPerformanceSignposts.log,
                name: phase.signpostName,
                signpostID: signpostID
            )
        }

        var isActive: Bool {
            !didEnd
        }

        @discardableResult
        mutating func end() -> Bool {
            guard !didEnd else {
                return false
            }

            didEnd = true
            os_signpost(
                .end,
                log: ChatPerformanceSignposts.log,
                name: phase.signpostName,
                signpostID: signpostID
            )
            return true
        }
    }

    static func begin(_ phase: ChatPerformanceSignpostPhase) -> Interval {
        Interval(phase: phase)
    }

    @discardableResult
    static func measure<T>(
        _ phase: ChatPerformanceSignpostPhase,
        _ body: () throws -> T
    ) rethrows -> T {
        var interval = begin(phase)
        defer {
            interval.end()
        }
        return try body()
    }
}
