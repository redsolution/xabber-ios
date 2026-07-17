import UIKit

struct ChatMessageFrameGeometry {
    let name: String
    let frame: CGRect
}

enum ChatMessageFrameGeometryViolation: Equatable {
    case nonFinite(name: String)
    case negativeSize(name: String)
    case outsideContainer(name: String)
}

enum ChatMessageFrameGeometryValidator {
    static func violations(
        frames: [ChatMessageFrameGeometry],
        containerBounds: CGRect,
        tolerance: CGFloat = 0.5
    ) -> [ChatMessageFrameGeometryViolation] {
        let allowedBounds = containerBounds.insetBy(dx: -tolerance, dy: -tolerance)
        return frames.compactMap { geometry in
            let frame = geometry.frame
            guard frame.origin.x.isFinite,
                  frame.origin.y.isFinite,
                  frame.size.width.isFinite,
                  frame.size.height.isFinite else {
                return .nonFinite(name: geometry.name)
            }
            guard frame.size.width >= 0, frame.size.height >= 0 else {
                return .negativeSize(name: geometry.name)
            }
            guard frame.minX >= allowedBounds.minX,
                  frame.minY >= allowedBounds.minY,
                  frame.maxX <= allowedBounds.maxX,
                  frame.maxY <= allowedBounds.maxY else {
                return .outsideContainer(name: geometry.name)
            }
            return nil
        }
    }

    static func assertValid(
        frames: [ChatMessageFrameGeometry],
        containerBounds: CGRect,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
#if DEBUG
        let failures = violations(frames: frames, containerBounds: containerBounds)
        guard !failures.isEmpty else { return }
        let frameSummary = frames.map { "\($0.name)=\($0.frame)" }
        assertionFailure(
            "Invalid chat message geometry: \(failures); container=\(containerBounds); frames=\(frameSummary)",
            file: file,
            line: line
        )
#endif
    }
}
