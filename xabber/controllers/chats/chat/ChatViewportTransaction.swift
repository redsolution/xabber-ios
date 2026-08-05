//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//

import UIKit

struct ChatViewportAnchor: Equatable {
    let primary: String
    let viewportRelativeMinY: CGFloat
}

struct ChatViewportSnapshotDiff: Equatable {
    let oldItemCount: Int
    let newItemCount: Int
    let insertedItemCount: Int
    let deletedItemCount: Int
    let movedItemCount: Int
    let reloadedItemCount: Int
    let contentOnlyItemCount: Int

    init(
        oldItemCount: Int,
        newItemCount: Int,
        insertedItemCount: Int = 0,
        deletedItemCount: Int = 0,
        movedItemCount: Int = 0,
        reloadedItemCount: Int = 0,
        contentOnlyItemCount: Int = 0
    ) {
        self.oldItemCount = oldItemCount
        self.newItemCount = newItemCount
        self.insertedItemCount = insertedItemCount
        self.deletedItemCount = deletedItemCount
        self.movedItemCount = movedItemCount
        self.reloadedItemCount = reloadedItemCount
        self.contentOnlyItemCount = contentOnlyItemCount
    }
}

struct ChatViewportContentChanges: OptionSet, Equatable {
    let rawValue: Int

    static let reload = ChatViewportContentChanges(rawValue: 1 << 0)
    static let structural = ChatViewportContentChanges(rawValue: 1 << 1)
    static let contentOnly = ChatViewportContentChanges(rawValue: 1 << 2)
}

struct ChatViewportLayoutChanges: OptionSet, Equatable {
    let rawValue: Int

    static let invalidateLayout = ChatViewportLayoutChanges(rawValue: 1 << 0)
    static let reconfigureItems = ChatViewportLayoutChanges(rawValue: 1 << 1)
}

enum ChatViewportAnchorStrategy: Equatable {
    case none
    case message(ChatViewportAnchor)
    case preserveContentOffset(CGFloat)
    case bottom
}

struct ChatViewportInsetDelta: Equatable {
    let top: CGFloat
    let left: CGFloat
    let bottom: CGFloat
    let right: CGFloat

    static let zero = ChatViewportInsetDelta(top: 0, left: 0, bottom: 0, right: 0)

    init(initial: UIEdgeInsets, final: UIEdgeInsets) {
        self.init(
            top: final.top - initial.top,
            left: final.left - initial.left,
            bottom: final.bottom - initial.bottom,
            right: final.right - initial.right
        )
    }

    private init(top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }
}

struct ChatViewportTransactionDiagnostics: Equatable {
    let snapshotDiff: ChatViewportSnapshotDiff
    let contentChanges: ChatViewportContentChanges
    let layoutChanges: ChatViewportLayoutChanges
    let insetDelta: ChatViewportInsetDelta
    let anchorStrategy: ChatViewportAnchorStrategy
    let forcedLayoutCount: Int
    let programmaticOffsetMutationCount: Int
    let finalAlignmentCorrectionCount: Int
    let nextRunLoopCorrectionCount: Int
    let anchorError: CGFloat?
    let automaticOffsetMutationSuppressedByUserInteraction: Bool
}

enum ChatViewportTransactionFailure: Error, Equatable {
    case targetMissing(primary: String)
    case alignmentUnresolved(target: String, error: CGFloat)
    case superseded
}

enum ChatViewportTransactionResult: Equatable {
    case committed(ChatViewportTransactionDiagnostics)
    case failed(ChatViewportTransactionFailure, ChatViewportTransactionDiagnostics)
}

enum ChatViewportTransactionTargetPolicy {
    struct PreservedContentOffsetDecision: Equatable {
        let targetOffsetY: CGFloat
        let isSafetyClamp: Bool
    }

    static func targetContentOffsetY(
        anchor: ChatViewportAnchor,
        resolvedAnchorMinY: CGFloat,
        minimumContentOffsetY: CGFloat,
        maximumContentOffsetY: CGFloat
    ) -> CGFloat {
        min(
            max(resolvedAnchorMinY - anchor.viewportRelativeMinY, minimumContentOffsetY),
            maximumContentOffsetY
        )
    }

    static func preservedContentOffsetDecision(
        requestedOffsetY: CGFloat,
        minimumContentOffsetY: CGFloat,
        maximumContentOffsetY: CGFloat
    ) -> PreservedContentOffsetDecision {
        let normalizedMaximumOffsetY = max(minimumContentOffsetY, maximumContentOffsetY)
        let targetOffsetY = min(
            max(requestedOffsetY, minimumContentOffsetY),
            normalizedMaximumOffsetY
        )
        return PreservedContentOffsetDecision(
            targetOffsetY: targetOffsetY,
            isSafetyClamp: requestedOffsetY < minimumContentOffsetY ||
                requestedOffsetY > normalizedMaximumOffsetY
        )
    }
}

/// Owns one datasource/layout/viewport commit. UIKit may perform internal layout
/// work, but app-issued forced layouts and programmatic offset mutations are
/// deliberately bounded and exposed through diagnostics.
final class ChatViewportTransaction {
    let snapshotDiff: ChatViewportSnapshotDiff
    let contentChanges: ChatViewportContentChanges
    let layoutChanges: ChatViewportLayoutChanges
    let anchorStrategy: ChatViewportAnchorStrategy

    private let initialInsets: UIEdgeInsets
    private let completion: (ChatViewportTransactionResult) -> Void
    private var finalInsets: UIEdgeInsets
    private var forcedLayoutCount = 0
    private var programmaticOffsetMutationCount = 0
    private var finalAlignmentCorrectionCount = 0
    private var userInteractionDetected = false
    private var automaticOffsetMutationSuppressedByUserInteraction = false
    private var isCompleted = false

    init(
        snapshotDiff: ChatViewportSnapshotDiff,
        contentChanges: ChatViewportContentChanges,
        layoutChanges: ChatViewportLayoutChanges,
        initialInsets: UIEdgeInsets,
        anchorStrategy: ChatViewportAnchorStrategy,
        completion: @escaping (ChatViewportTransactionResult) -> Void
    ) {
        self.snapshotDiff = snapshotDiff
        self.contentChanges = contentChanges
        self.layoutChanges = layoutChanges
        self.initialInsets = initialInsets
        self.finalInsets = initialInsets
        self.anchorStrategy = anchorStrategy
        self.completion = completion
    }

    @discardableResult
    func performForcedLayout(_ operation: () -> Void) -> Bool {
        guard !isCompleted, forcedLayoutCount == 0 else {
            return false
        }
        forcedLayoutCount = 1
        operation()
        return true
    }

    @discardableResult
    func performProgrammaticOffsetMutation(
        currentOffsetY: CGFloat,
        targetOffsetY: CGFloat,
        isAutomatic: Bool,
        tolerance: CGFloat = 0.5,
        _ operation: (CGFloat) -> Void
    ) -> Bool {
        guard !isCompleted,
              programmaticOffsetMutationCount == 0,
              abs(currentOffsetY - targetOffsetY) > tolerance else {
            return false
        }
        if isAutomatic, userInteractionDetected {
            automaticOffsetMutationSuppressedByUserInteraction = true
            return false
        }
        programmaticOffsetMutationCount = 1
        operation(targetOffsetY)
        return true
    }

    /// Allows one final correction after self-sizing/layout has settled.
    ///
    /// The ordinary offset mutation remains single-shot. Initial-frame
    /// presentation gets this separate bounded correction while the same
    /// disabled-actions transaction is still open, so no misaligned content
    /// frame can reach the render server.
    @discardableResult
    func performFinalAlignmentCorrection(
        currentOffsetY: CGFloat,
        targetOffsetY: CGFloat,
        tolerance: CGFloat,
        _ operation: (CGFloat) -> Void
    ) -> Bool {
        guard !isCompleted,
              finalAlignmentCorrectionCount == 0,
              abs(currentOffsetY - targetOffsetY) > tolerance else {
            return false
        }
        finalAlignmentCorrectionCount = 1
        operation(targetOffsetY)
        return true
    }

    func markUserInteractionDetected() {
        guard !isCompleted else { return }
        userInteractionDetected = true
    }

    func recordFinalInsets(_ insets: UIEdgeInsets) {
        guard !isCompleted else { return }
        finalInsets = insets
    }

    @discardableResult
    func commit(anchorError: CGFloat?) -> Bool {
        complete(with: .committed(makeDiagnostics(anchorError: anchorError)))
    }

    @discardableResult
    func fail(_ failure: ChatViewportTransactionFailure) -> Bool {
        complete(with: .failed(failure, makeDiagnostics(anchorError: nil)))
    }

    private func complete(with result: ChatViewportTransactionResult) -> Bool {
        guard !isCompleted else { return false }
        isCompleted = true
        completion(result)
        return true
    }

    private func makeDiagnostics(anchorError: CGFloat?) -> ChatViewportTransactionDiagnostics {
        ChatViewportTransactionDiagnostics(
            snapshotDiff: snapshotDiff,
            contentChanges: contentChanges,
            layoutChanges: layoutChanges,
            insetDelta: ChatViewportInsetDelta(initial: initialInsets, final: finalInsets),
            anchorStrategy: anchorStrategy,
            forcedLayoutCount: forcedLayoutCount,
            programmaticOffsetMutationCount: programmaticOffsetMutationCount,
            finalAlignmentCorrectionCount: finalAlignmentCorrectionCount,
            nextRunLoopCorrectionCount: 0,
            anchorError: anchorError,
            automaticOffsetMutationSuppressedByUserInteraction: automaticOffsetMutationSuppressedByUserInteraction
        )
    }
}
