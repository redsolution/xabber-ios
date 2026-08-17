import Foundation

/// Immutable group state consumed by the chat screen.
///
/// The adapter deliberately exposes no Realm objects. A projection received by
/// UIKit remains a stable value even while the repository applies a later
/// server snapshot.
struct ChatGroupProjectionState: Equatable, Sendable {
    let pinnedMessageIDs: [String]?
    let selfMemberID: String?
    let members: [GroupMember]
    let capabilities: GroupCapabilities
    let isActive: Bool
    let isDeleted: Bool

    var lastPinnedMessageID: String? {
        pinnedMessageIDs?.first
    }

    var isComposerActive: Bool {
        isActive && capabilities.sendMessages
    }

    var selfMember: GroupMember? {
        guard let selfMemberID else { return nil }
        return members.first { $0.id == selfMemberID }
    }

    var canUnpinLastMessage: Bool {
        canPinMessages && lastPinnedMessageID != nil
    }

    var canPinMessages: Bool {
        isActive && capabilities.pinMessages
    }
}

enum ChatGroupProjectionAdapter {
    static func map(
        _ projection: GroupRepositoryProjection
    ) -> ChatGroupProjectionState {
        ChatGroupProjectionState(
            pinnedMessageIDs: projection.state.snapshot.pinnedMessageIDs,
            selfMemberID: projection.selfMemberID,
            members: projection.state.members,
            capabilities: projection.capabilities,
            isActive: projection.state.isActive,
            isDeleted: projection.state.isDeleted
        )
    }

    static func allowsComposer(
        baseEnabled: Bool,
        isGroupConversation: Bool,
        state: ChatGroupProjectionState?
    ) -> Bool {
        guard baseEnabled else { return false }
        guard isGroupConversation else { return true }
        return state?.isComposerActive == true
    }
}

enum ChatCanonicalGroupPresencePolicy {
    static func shouldSend(
        _ state: GroupChatPresenceState,
        conversationIsGroup: Bool,
        projection: ChatGroupProjectionState?,
        lastSent: GroupChatPresenceState?
    ) -> Bool {
        guard conversationIsGroup,
              projection?.isActive == true else {
            return false
        }
        return state != lastSent
    }
}

/// Owns both the repository and its Realm notification token for one chat
/// controller subscription. Replacing or invalidating the observer guarantees
/// that a controller never retains live persistence entities.
final class ChatGroupProjectionObserver {
    private var repository: GroupRepository?
    private var observation: GroupRepositoryObservation?

    func observe(
        repository: GroupRepository,
        owner: String,
        groupJID: String,
        onChange: @escaping (ChatGroupProjectionState) -> Void
    ) throws {
        invalidate()
        self.repository = repository
        do {
            observation = try repository.observeProjection(
                owner: owner,
                groupJID: groupJID
            ) { projection in
                onChange(ChatGroupProjectionAdapter.map(projection))
            }
        } catch {
            self.repository = nil
            throw error
        }
    }

    func invalidate() {
        observation?.invalidate()
        observation = nil
        repository = nil
    }

    deinit {
        invalidate()
    }
}
