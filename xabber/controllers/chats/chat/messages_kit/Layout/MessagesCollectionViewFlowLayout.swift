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

import UIKit
import AVFoundation

enum ChatWidthTransitionInvalidationPhase: String, Equatable {
    case targetBounds
    case postBoundsMetrics
}

enum ChatWidthTransitionInvalidationCommitMode: String, Equatable {
    case direct
    case targetOffsetUpdate
}

enum ChatCollectionUpdateTargetContentOffset: Equatable {
    case bottom
    case message(IndexPath)
}

#if DEBUG || CHAT_PERFORMANCE_LAB
struct ChatWidthTransitionInvalidationDiagnostic: Equatable,
    CustomStringConvertible {
    let phase: ChatWidthTransitionInvalidationPhase
    let targetLayoutWidth: CGFloat
    let collectionLayoutWidthBeforeSuper: CGFloat
    let proposedLayoutWidth: CGFloat
    let installedSnapshotBeforeSuper: Bool
    let defaultAdjustmentY: CGFloat
    let semanticAdjustmentY: CGFloat
    let resolvedAdjustmentY: CGFloat

    var description: String {
        [
            "phase=\(phase.rawValue)",
            "targetWidth=\(targetLayoutWidth)",
            "sourceWidth=\(collectionLayoutWidthBeforeSuper)",
            "proposedWidth=\(proposedLayoutWidth)",
            "snapshotBeforeSuper=\(installedSnapshotBeforeSuper)",
            "defaultY=\(defaultAdjustmentY)",
            "semanticY=\(semanticAdjustmentY)",
            "resolvedY=\(resolvedAdjustmentY)"
        ].joined(separator: " ")
    }
}

struct ChatWidthTransitionTargetOffsetDiagnostic: Equatable,
    CustomStringConvertible {
    let proposedY: CGFloat
    let defaultY: CGFloat
    let anchorFrameMinY: CGFloat
    let viewportRelativeMinY: CGFloat
    let resolvedY: CGFloat

    var description: String {
        [
            "targetOffset",
            "proposedY=\(proposedY)",
            "defaultY=\(defaultY)",
            "anchorMinY=\(anchorFrameMinY)",
            "viewportY=\(viewportRelativeMinY)",
            "resolvedY=\(resolvedY)"
        ].joined(separator: " ")
    }
}
#endif

/// The layout object used by `MessagesCollectionView` to determine the size of all
/// framework provided `MessageCollectionViewCell` subclasses.
class MessagesCollectionViewFlowLayout: UICollectionViewFlowLayout {

    internal final let cache = ChatMessageLayoutCache()
    private struct StagedWidthTransitionLayout {
        let targetLayoutWidth: CGFloat
        var snapshot: ChatMessageLayoutSnapshot?
        var boundsContentOffsetAdjustmentY: CGFloat?
        var targetBoundsContentOffsetAdjustmentY: CGFloat?
        var postBoundsMetricsContentOffsetAdjustmentY: CGFloat?
        var targetContentOffset:
            ChatWidthTransitionTargetContentOffset?
    }

    private var stagedWidthTransitionLayout: StagedWidthTransitionLayout?
    private var stagedPostBoundsTargetContentOffset:
        ChatWidthTransitionTargetContentOffset?
    private var stagedCollectionUpdateTargetContentOffset:
        ChatCollectionUpdateTargetContentOffset?
#if DEBUG || CHAT_PERFORMANCE_LAB
    internal private(set) var widthTransitionInvalidationDiagnostics:
        [ChatWidthTransitionInvalidationDiagnostic] = []
    internal private(set) var widthTransitionTargetOffsetDiagnostics:
        [ChatWidthTransitionTargetOffsetDiagnostic] = []
    internal private(set) var widthTransitionInvalidationCommitModes:
        [ChatWidthTransitionInvalidationCommitMode] = []

    internal func resetWidthTransitionInvalidationDiagnostics() {
        widthTransitionInvalidationDiagnostics.removeAll(
            keepingCapacity: true
        )
        widthTransitionTargetOffsetDiagnostics.removeAll(
            keepingCapacity: true
        )
        widthTransitionInvalidationCommitModes.removeAll(
            keepingCapacity: true
        )
    }
#endif
    
    override class var layoutAttributesClass: AnyClass {
//        let lay = UICollectionViewLayout()
        return MessagesCollectionViewLayoutAttributes.self
    }
    
    public var messagesCollectionView: MessagesCollectionView {
        guard let messagesCollectionView = collectionView as? MessagesCollectionView else {
            fatalError(MessageKitError.layoutUsedOnForeignType)
        }
        return messagesCollectionView
    }
    
    var messagesDataSource: MessagesDataSource {
        guard let messagesDataSource = messagesCollectionView.messagesDataSource else {
            fatalError(MessageKitError.nilMessagesDataSource)
        }
        return messagesDataSource
    }
    
    var messagesLayoutDelegate: MessagesLayoutDelegate {
        guard let messagesLayoutDelegate = messagesCollectionView.messagesLayoutDelegate else {
            fatalError(MessageKitError.nilMessagesLayoutDelegate)
        }
        return messagesLayoutDelegate
    }

    var itemWidth: CGFloat {
        guard let collectionView = collectionView else { return 0 }
        return collectionView.frame.width - sectionInset.horizontal
    }
    
    override init() {
        super.init()
        self.sectionFootersPinToVisibleBounds = true
//        self.sectionHeadersPinToVisibleBounds = true
//        sectionInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        NotificationCenter.default.addObserver(self, selector: #selector(MessagesCollectionViewFlowLayout.handleOrientationChange(_:)), name: UIDevice.orientationDidChangeNotification, object: nil)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        cache.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard let attributesArray = super.layoutAttributesForElements(in: rect)?.compactMap({
            $0.copy() as? MessagesCollectionViewLayoutAttributes
        }) else {
            return nil
        }
        for attributes in attributesArray where attributes.representedElementCategory == .cell {
            let message = messagesDataSource.messageForItem(
                at: attributes.indexPath,
                in: messagesCollectionView
            )
            readyLayout(for: message).apply(to: attributes)
        }
//        guard let attributes = super.layoutAttributesForElements(in: rect) else {
//            return attributesArray
//        }
//        for attribute in attributes {
//            adjustAttributesIfNeeded(attribute)
//        }
        return attributesArray
    }
    
    func adjustAttributesIfNeeded(_ attributes: UICollectionViewLayoutAttributes) {
        switch attributes.representedElementKind {
            case UICollectionView.elementKindSectionHeader?:
                adjustHeaderAttributesIfNeeded(attributes)
            case UICollectionView.elementKindSectionFooter?:
                adjustFooterAttributesIfNeeded(attributes)
        default:
            break
        }
    }
    
    override func layoutAttributesForSupplementaryView(ofKind elementKind: String, at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard let attributes = super.layoutAttributesForSupplementaryView(
            ofKind: elementKind,
            at: indexPath
        )?.copy() as? UICollectionViewLayoutAttributes else { return nil }
        adjustAttributesIfNeeded(attributes)
        return attributes
    }
    
    private func adjustHeaderAttributesIfNeeded(_ attributes: UICollectionViewLayoutAttributes) {
        guard let collectionView = collectionView else { return }
        guard attributes.indexPath.section == 0 else { return }
        
        
        if collectionView.contentOffset.y < 0 {
            attributes.frame.origin.y = collectionView.contentOffset.y
        }
    }

    private func adjustFooterAttributesIfNeeded(_ attributes: UICollectionViewLayoutAttributes) {
        guard let collectionView = collectionView else { return }
        guard attributes.indexPath.section == collectionView.numberOfSections - 1 else { return }
        
        if collectionView.contentOffset.y + collectionView.bounds.size.height > collectionView.contentSize.height {
            attributes.frame.origin.y = collectionView.contentOffset.y + collectionView.bounds.size.height - attributes.frame.size.height
        }
    }
    
    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard let attributes = super.layoutAttributesForItem(
            at: indexPath
        )?.copy() as? MessagesCollectionViewLayoutAttributes else {
            return nil
        }
        if attributes.representedElementCategory == .cell {
            let message = messagesDataSource.messageForItem(
                at: attributes.indexPath,
                in: messagesCollectionView
            )
            readyLayout(for: message).apply(to: attributes)
        }
        return attributes
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        return collectionView?.bounds.width != newBounds.width
    }

    override func targetContentOffset(
        forProposedContentOffset proposedContentOffset: CGPoint
    ) -> CGPoint {
        let defaultTarget = super.targetContentOffset(
            forProposedContentOffset: proposedContentOffset
        )
        if let stagedCollectionUpdateTargetContentOffset {
            self.stagedCollectionUpdateTargetContentOffset = nil
            let targetMaxY: CGFloat
            switch stagedCollectionUpdateTargetContentOffset {
            case .bottom:
                targetMaxY = collectionViewContentSize.height
            case .message(let indexPath):
                guard let attributes = layoutAttributesForItem(
                    at: indexPath
                ) else {
                    return defaultTarget
                }
                targetMaxY = attributes.frame.maxY
            }
            return CGPoint(
                x: defaultTarget.x,
                y: ChatBottomScrollAlignmentPolicy.targetContentOffsetY(
                    targetMaxY: targetMaxY,
                    contentHeight: collectionViewContentSize.height,
                    viewportHeight: messagesCollectionView.bounds.height,
                    contentInsets: messagesCollectionView.contentInset
                )
            )
        }
        guard let stagedPostBoundsTargetContentOffset else {
            return defaultTarget
        }
        switch stagedPostBoundsTargetContentOffset {
        case .bottom:
            let contentInsets = messagesCollectionView.contentInset
            let resolvedTarget = CGPoint(
                x: defaultTarget.x,
                y: max(
                    -contentInsets.top,
                    collectionViewContentSize.height +
                        contentInsets.bottom -
                        messagesCollectionView.bounds.height
                )
            )
            self.stagedPostBoundsTargetContentOffset = nil
            return resolvedTarget
        case .message(let indexPath, let viewportRelativeMinY):
            guard let attributes = layoutAttributesForItem(
                at: indexPath
            ) else {
                return defaultTarget
            }
            let resolvedTarget = CGPoint(
                x: defaultTarget.x,
                y: attributes.frame.minY - viewportRelativeMinY
            )
#if DEBUG || CHAT_PERFORMANCE_LAB
            widthTransitionTargetOffsetDiagnostics.append(
                ChatWidthTransitionTargetOffsetDiagnostic(
                    proposedY: proposedContentOffset.y,
                    defaultY: defaultTarget.y,
                    anchorFrameMinY: attributes.frame.minY,
                    viewportRelativeMinY: viewportRelativeMinY,
                    resolvedY: resolvedTarget.y
                )
            )
            if widthTransitionTargetOffsetDiagnostics.count > 8 {
                widthTransitionTargetOffsetDiagnostics.removeFirst(
                    widthTransitionTargetOffsetDiagnostics.count - 8
                )
            }
#endif
            self.stagedPostBoundsTargetContentOffset = nil
            return resolvedTarget
        }
    }

    /// Arms one exact offset for the next collection update pass. UIKit
    /// resolves it against post-update geometry before exposing the inserted
    /// cells, so a live-tail row cannot briefly appear behind the composer.
    @discardableResult
    func stageCollectionUpdateTargetContentOffset(
        _ target: ChatCollectionUpdateTargetContentOffset
    ) -> Bool {
        guard stagedCollectionUpdateTargetContentOffset == nil,
              stagedWidthTransitionLayout == nil,
              stagedPostBoundsTargetContentOffset == nil else {
            return false
        }
        stagedCollectionUpdateTargetContentOffset = target
        return true
    }

    /// Removes an unconsumed target after UIKit's update completion. The
    /// viewport transaction then remains the bounded geometry fallback.
    func discardStagedCollectionUpdateTargetContentOffset() {
        stagedCollectionUpdateTargetContentOffset = nil
    }

    /// Uses an update pass when a late message anchor or live tail has armed
    /// the documented target-offset callback. A retained snapshot consumed
    /// in the natural bounds pass keeps its direct invalidation semantics.
    @discardableResult
    func commitStagedWidthTransitionInvalidation(
        _ context: UICollectionViewLayoutInvalidationContext,
        completion: ((Bool) -> Void)? = nil
    ) -> ChatWidthTransitionInvalidationCommitMode {
        let commitMode: ChatWidthTransitionInvalidationCommitMode
        if stagedPostBoundsTargetContentOffset != nil,
           let collectionView {
            commitMode = .targetOffsetUpdate
            collectionView.performBatchUpdates({
                self.invalidateLayout(with: context)
            }, completion: completion)
        } else {
            commitMode = .direct
            invalidateLayout(with: context)
        }
#if DEBUG || CHAT_PERFORMANCE_LAB
        widthTransitionInvalidationCommitModes.append(commitMode)
        if widthTransitionInvalidationCommitModes.count > 8 {
            widthTransitionInvalidationCommitModes.removeFirst(
                widthTransitionInvalidationCommitModes.count - 8
            )
        }
#endif
        return commitMode
    }

    override func invalidationContext(forBoundsChange newBounds: CGRect) -> UICollectionViewLayoutInvalidationContext {
        let stagedWidthTransition = matchingStagedWidthTransition(
            for: newBounds
        )
        let collectionLayoutWidthBeforeSuper = max(
            1,
            (collectionView?.bounds.width ?? newBounds.width) -
                sectionInset.horizontal
        )
        let proposedLayoutWidth = max(
            1,
            newBounds.width - sectionInset.horizontal
        )
        let phase: ChatWidthTransitionInvalidationPhase
        if abs(collectionLayoutWidthBeforeSuper - proposedLayoutWidth) > 1 {
            phase = .targetBounds
        } else {
            phase = .postBoundsMetrics
        }
        let installsSnapshotBeforeSuper =
            phase == .targetBounds &&
            stagedWidthTransition?.snapshot != nil
        if installsSnapshotBeforeSuper,
           let snapshot = stagedWidthTransition?.snapshot {
            cache.install(snapshot)
        }
        let context = super.invalidationContext(forBoundsChange: newBounds)
        guard let flowLayoutContext = context as? UICollectionViewFlowLayoutInvalidationContext else { return context }
        let defaultAdjustmentY =
            flowLayoutContext.contentOffsetAdjustment.y
        if phase == .postBoundsMetrics,
           let snapshot = stagedWidthTransition?.snapshot {
            // A late metrics pass must let UIKit inspect the source cache
            // first. Installing target geometry before `super` suppresses
            // UICollectionView's native visible-row/live-tail preservation
            // and returns both real rotation cycles to their baseline jump.
            cache.install(snapshot)
        }
        let semanticAdjustmentY = consumeStagedWidthTransitionIfNeeded(
            stagedWidthTransition,
            phase: phase,
            context: flowLayoutContext
        )
#if DEBUG || CHAT_PERFORMANCE_LAB
        if let stagedWidthTransition,
           let semanticAdjustmentY {
            widthTransitionInvalidationDiagnostics.append(
                ChatWidthTransitionInvalidationDiagnostic(
                    phase: phase,
                    targetLayoutWidth:
                        stagedWidthTransition.targetLayoutWidth,
                    collectionLayoutWidthBeforeSuper:
                        collectionLayoutWidthBeforeSuper,
                    proposedLayoutWidth: proposedLayoutWidth,
                    installedSnapshotBeforeSuper:
                        installsSnapshotBeforeSuper,
                    defaultAdjustmentY: defaultAdjustmentY,
                    semanticAdjustmentY: semanticAdjustmentY,
                    resolvedAdjustmentY:
                        flowLayoutContext.contentOffsetAdjustment.y
                )
            )
            if widthTransitionInvalidationDiagnostics.count > 8 {
                widthTransitionInvalidationDiagnostics.removeFirst(
                    widthTransitionInvalidationDiagnostics.count - 8
                )
            }
        }
#endif
        flowLayoutContext.invalidateFlowLayoutDelegateMetrics = shouldInvalidateLayout(forBoundsChange: newBounds)
        return flowLayoutContext
    }

    /// Retains a fully prepared target-width snapshot until UIKit asks for
    /// the matching bounds invalidation context. Installing it at that exact
    /// boundary prevents a narrower collection viewport from ever querying
    /// item sizes from the prior wider cache.
    func stageWidthTransitionLayout(
        _ snapshot: ChatMessageLayoutSnapshot,
        targetLayoutWidth: CGFloat,
        targetBoundsContentOffsetAdjustmentY: CGFloat,
        postBoundsMetricsContentOffsetAdjustmentY: CGFloat,
        targetContentOffset: ChatWidthTransitionTargetContentOffset?
    ) {
        if stagedWidthTransitionLayout?.targetLayoutWidth ==
            targetLayoutWidth {
            stagedWidthTransitionLayout?.snapshot = snapshot
            stagedWidthTransitionLayout?
                .targetBoundsContentOffsetAdjustmentY =
                    targetBoundsContentOffsetAdjustmentY
            stagedWidthTransitionLayout?
                .postBoundsMetricsContentOffsetAdjustmentY =
                    postBoundsMetricsContentOffsetAdjustmentY
            stagedWidthTransitionLayout?.targetContentOffset =
                targetContentOffset
        } else {
            stagedWidthTransitionLayout = StagedWidthTransitionLayout(
                targetLayoutWidth: targetLayoutWidth,
                snapshot: snapshot,
                boundsContentOffsetAdjustmentY: nil,
                targetBoundsContentOffsetAdjustmentY:
                    targetBoundsContentOffsetAdjustmentY,
                postBoundsMetricsContentOffsetAdjustmentY:
                    postBoundsMetricsContentOffsetAdjustmentY,
                targetContentOffset: targetContentOffset
            )
        }
    }

    /// Staged synchronously from `viewWillTransition`, before target layout
    /// preparation can finish and before Auto Layout mutates collection
    /// bounds. This replaces UIKit's viewport-height adjustment at the only
    /// boundary where the collection view consumes it.
    func stageWidthTransitionBoundsAdjustment(
        targetLayoutWidth: CGFloat,
        contentOffsetAdjustmentY: CGFloat
    ) {
        if stagedWidthTransitionLayout?.targetLayoutWidth ==
            targetLayoutWidth {
            stagedWidthTransitionLayout?
                .boundsContentOffsetAdjustmentY =
                    contentOffsetAdjustmentY
        } else {
            stagedWidthTransitionLayout = StagedWidthTransitionLayout(
                targetLayoutWidth: targetLayoutWidth,
                snapshot: nil,
                boundsContentOffsetAdjustmentY:
                    contentOffsetAdjustmentY,
                targetBoundsContentOffsetAdjustmentY: nil,
                postBoundsMetricsContentOffsetAdjustmentY: nil,
                targetContentOffset: nil
            )
        }
    }

    func discardStagedWidthTransitionLayout() {
        stagedWidthTransitionLayout = nil
        stagedPostBoundsTargetContentOffset = nil
    }

    private func matchingStagedWidthTransition(
        for newBounds: CGRect
    ) -> StagedWidthTransitionLayout? {
        guard let stagedWidthTransitionLayout else { return nil }
        let availableLayoutWidth = max(
            1,
            newBounds.width - sectionInset.horizontal
        )
        guard abs(
            availableLayoutWidth -
                stagedWidthTransitionLayout.targetLayoutWidth
        ) <= 1 else {
            return nil
        }
        return stagedWidthTransitionLayout
    }

    private func consumeStagedWidthTransitionIfNeeded(
        _ stagedWidthTransitionLayout: StagedWidthTransitionLayout?,
        phase: ChatWidthTransitionInvalidationPhase,
        context: UICollectionViewFlowLayoutInvalidationContext
    ) -> CGFloat? {
        guard let stagedWidthTransitionLayout else { return nil }
        let semanticAdjustmentY: CGFloat?
        switch phase {
        case .targetBounds:
            if stagedWidthTransitionLayout.targetContentOffset == .bottom {
                // A retained live-tail snapshot is installed atomically in
                // this bounds pass, but UIKit can still replace the natural
                // viewport-height proposal while finalizing its collection
                // metrics. Keep an exact layout-owned bottom target armed for
                // the enclosing update transaction. Message anchors retain
                // their already-proven natural-bounds contract.
                stagedPostBoundsTargetContentOffset = .bottom
            } else {
                stagedPostBoundsTargetContentOffset = nil
            }
            let contentOffsetAdjustments = [
                stagedWidthTransitionLayout
                    .boundsContentOffsetAdjustmentY,
                stagedWidthTransitionLayout
                    .targetBoundsContentOffsetAdjustmentY
            ].compactMap { $0 }
            semanticAdjustmentY = contentOffsetAdjustments.isEmpty
                ? nil
                : contentOffsetAdjustments.reduce(0, +)
            if let semanticAdjustmentY {
                // This is the natural bounds owner. Replace UIKit's viewport-
                // height proposal with the complete semantic adjustment.
                context.contentOffsetAdjustment = CGPoint(
                    x: context.contentOffsetAdjustment.x,
                    y: semanticAdjustmentY
                )
            }
        case .postBoundsMetrics:
            stagedPostBoundsTargetContentOffset =
                stagedWidthTransitionLayout.targetContentOffset
            semanticAdjustmentY = stagedWidthTransitionLayout
                .postBoundsMetricsContentOffsetAdjustmentY
            if let semanticAdjustmentY {
                // UIKit has captured its source row/tail before target-cache
                // installation. Keep that native proposal and add only the
                // requested-anchor residual.
                context.contentOffsetAdjustment = CGPoint(
                    x: context.contentOffsetAdjustment.x,
                    y: context.contentOffsetAdjustment.y +
                        semanticAdjustmentY
                )
            }
        }
        self.stagedWidthTransitionLayout = nil
        return semanticAdjustmentY
    }

    @objc
    private func handleOrientationChange(_ notification: Notification) {
        invalidateLayout()
    }

    func sizeForItem(at indexPath: IndexPath) -> CGSize {
        let message = messagesDataSource.messageForItem(at: indexPath, in: messagesCollectionView)
        return readyLayout(for: message).cellSize
    }

    func sizeForMessage(_ message: MessageType) -> CGSize {
        cache.layout(forPrimary: message.primary)?.cellSize ?? .zero
    }

    private func readyLayout(for message: MessageType) -> ChatMessageLayout {
        cache.layout(forPrimary: message.primary)
            ?? ChatMessageLayout.fallback(for: message, width: itemWidth)
    }
    
    public final func invalidateLastMessageCachedSize(primary: String?) {
        if let primary = primary {
            cache.invalidate(primary: primary)
        }
    }
    
}
