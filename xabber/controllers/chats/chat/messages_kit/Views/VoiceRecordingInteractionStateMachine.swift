//
//  VoiceRecordingInteractionStateMachine.swift
//  xabber
//
//  Created by Codex on 14.05.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import CoreGraphics
import Foundation

enum VoiceRecordingFinishIntent: Equatable {
    case sendImmediately
    case preview
}

struct VoiceRecordingInteractionStateMachine {
    struct Configuration: Equatable {
        var minimumDuration: TimeInterval = 1.0
        var cancelTranslationX: CGFloat = -120
        var lockTranslationY: CGFloat = -108
    }

    enum State: Equatable {
        case idle
        case pressing(sessionID: UUID, startedAt: TimeInterval)
        case recording(sessionID: UUID, startedAt: TimeInterval)
        case cancelling(sessionID: UUID)
        case lockedRecording(sessionID: UUID, startedAt: TimeInterval)
        case preview(sessionID: UUID)
        case sending(sessionID: UUID)
        case failed(sessionID: UUID?)

        var sessionID: UUID? {
            switch self {
            case .idle:
                return nil
            case .pressing(let sessionID, _),
                 .recording(let sessionID, _),
                 .cancelling(let sessionID),
                 .lockedRecording(let sessionID, _),
                 .preview(let sessionID),
                 .sending(let sessionID):
                return sessionID
            case .failed(let sessionID):
                return sessionID
            }
        }
    }

    enum Action: Equatable {
        case requestStartRecording(UUID)
        case showRecording(UUID)
        case updateDrag(CGPoint)
        case lockRecording(UUID)
        case cancelRecording(UUID)
        case finishRecording(UUID, VoiceRecordingFinishIntent)
        case deletePreview(UUID)
        case sendPreview(UUID)
        case resetUI
        case fail(UUID?)
    }

    private(set) var state: State = .idle
    var configuration: Configuration

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    mutating func beginPress(sessionID: UUID = UUID(), at timestamp: TimeInterval) -> [Action] {
        guard state == .idle else { return [] }
        state = .pressing(sessionID: sessionID, startedAt: timestamp)
        return [.requestStartRecording(sessionID)]
    }

    mutating func recorderStarted(sessionID: UUID) -> [Action] {
        switch state {
        case .pressing(sessionID, let startedAt):
            state = .recording(sessionID: sessionID, startedAt: startedAt)
            return [.showRecording(sessionID)]
        case .lockedRecording(sessionID, _):
            return [.showRecording(sessionID)]
        default:
            return []
        }
    }

    mutating func recorderFailed(sessionID: UUID?) -> [Action] {
        guard sessionID == nil || state.sessionID == sessionID else { return [] }
        state = .failed(sessionID: sessionID)
        return [.fail(sessionID)]
    }

    mutating func dragChanged(to translation: CGPoint) -> [Action] {
        switch state {
        case .pressing(let sessionID, let startedAt),
             .recording(let sessionID, let startedAt):
            var actions: [Action] = [.updateDrag(translation)]
            if translation.x <= configuration.cancelTranslationX {
                state = .cancelling(sessionID: sessionID)
                actions.append(.cancelRecording(sessionID))
            } else if translation.y <= configuration.lockTranslationY {
                state = .lockedRecording(sessionID: sessionID, startedAt: startedAt)
                actions.append(.lockRecording(sessionID))
            }
            return actions
        case .lockedRecording(let sessionID, _):
            var actions: [Action] = [.updateDrag(translation)]
            if translation.x <= configuration.cancelTranslationX {
                state = .cancelling(sessionID: sessionID)
                actions.append(.cancelRecording(sessionID))
            }
            return actions
        default:
            return []
        }
    }

    mutating func endPress(at timestamp: TimeInterval) -> [Action] {
        switch state {
        case .pressing(let sessionID, _):
            state = .cancelling(sessionID: sessionID)
            return [.cancelRecording(sessionID)]
        case .recording(let sessionID, let startedAt):
            if timestamp - startedAt >= configuration.minimumDuration {
                state = .sending(sessionID: sessionID)
                return [.finishRecording(sessionID, .sendImmediately)]
            } else {
                state = .cancelling(sessionID: sessionID)
                return [.cancelRecording(sessionID)]
            }
        case .lockedRecording:
            return []
        default:
            return []
        }
    }

    mutating func stopLockedRecording(at timestamp: TimeInterval) -> [Action] {
        guard case .lockedRecording(let sessionID, let startedAt) = state else { return [] }
        if timestamp - startedAt >= configuration.minimumDuration {
            state = .preview(sessionID: sessionID)
            return [.finishRecording(sessionID, .preview)]
        } else {
            state = .cancelling(sessionID: sessionID)
            return [.cancelRecording(sessionID)]
        }
    }

    mutating func sendLockedRecording(at timestamp: TimeInterval) -> [Action] {
        guard case .lockedRecording(let sessionID, let startedAt) = state else { return [] }
        if timestamp - startedAt >= configuration.minimumDuration {
            state = .sending(sessionID: sessionID)
            return [.finishRecording(sessionID, .sendImmediately)]
        } else {
            state = .cancelling(sessionID: sessionID)
            return [.cancelRecording(sessionID)]
        }
    }

    mutating func cancelActive() -> [Action] {
        guard let sessionID = state.sessionID else { return [] }
        state = .cancelling(sessionID: sessionID)
        return [.cancelRecording(sessionID)]
    }

    mutating func deletePreview() -> [Action] {
        guard case .preview(let sessionID) = state else { return [] }
        state = .idle
        return [.deletePreview(sessionID), .resetUI]
    }

    mutating func sendPreview() -> [Action] {
        guard case .preview(let sessionID) = state else { return [] }
        state = .sending(sessionID: sessionID)
        return [.sendPreview(sessionID)]
    }

    mutating func complete(sessionID: UUID) -> [Action] {
        guard state.sessionID == sessionID else { return [] }
        state = .idle
        return [.resetUI]
    }

    mutating func reset() -> [Action] {
        state = .idle
        return [.resetUI]
    }
}

struct VoiceMessageReferenceBuilder {
    static func make(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        rawUrl: URL,
        duration: Int,
        meteringLevels: [Float]
    ) -> MessageReferenceStorageItem {
        let reference = MessageReferenceStorageItem()
        reference.kind = .voice
        reference.owner = owner
        reference.jid = jid
        reference.mimeType = "audio"
        reference.conversationType = conversationType
        reference.metadata = [
            "name": "Voice message",
            "media-type": "audio/ogg",
            "desc": "Voice message",
            "uri": rawUrl.absoluteString,
            "filename": "Voice message",
            "duration": "\(duration)",
            "meters": meteringLevels.map { String($0) }.joined(separator: " ")
        ]
        reference.meteringLevels = meteringLevels
        reference.primary = UUID().uuidString
        reference.url = rawUrl.absoluteString
        reference.decodedUrl = rawUrl
        return reference
    }
}
