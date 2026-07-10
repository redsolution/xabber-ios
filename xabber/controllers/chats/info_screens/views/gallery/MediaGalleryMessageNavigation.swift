import UIKit

enum MediaGalleryMessageNavigationRequestBuilder {
    static func request(
        for item: BaseMediaGalleryForChatViewController.Datasource
    ) -> ChatOpenMessageRequest? {
        guard let owner = normalized(item.owner),
              let jid = normalized(item.jid) else {
            return nil
        }
        let messagePrimary = normalized(item.messagePrimary)
        let archivedId = normalized(item.archiveId)
        guard messagePrimary != nil || archivedId != nil else {
            return nil
        }

        return ChatOpenMessageRequest(
            chatJid: jid,
            owner: owner,
            conversationType: item.conversationType,
            anchor: ChatMessageAnchorRef(
                messagePrimary: messagePrimary,
                archivedId: archivedId,
                messageId: nil,
                authorId: nil,
                bodyFingerprint: nil,
                sourceDate: item.date
            ),
            highlight: true,
            markReadOnVisible: false,
            source: .mediaGallery
        )
    }

    private static func normalized(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

enum MediaGalleryMessageNavigationRouteResult: Equatable {
    case activeChat
    case navigationStack
    case unavailable
}

@MainActor
protocol MediaGalleryMessageNavigationRouting: AnyObject {
    func route(
        _ request: ChatOpenMessageRequest,
        from presenter: UIViewController
    ) -> MediaGalleryMessageNavigationRouteResult
}

@MainActor
final class MediaGalleryMessageNavigationRouter: MediaGalleryMessageNavigationRouting {
    typealias ActiveChatProvider = (
        _ presenter: UIViewController,
        _ request: ChatOpenMessageRequest
    ) -> ChatViewController?
    typealias ActiveChatHandler = (
        _ chat: ChatViewController,
        _ presenter: UIViewController,
        _ request: ChatOpenMessageRequest
    ) -> Void
    typealias AppRouteHandler = (
        _ route: AppRoute,
        _ presenter: UIViewController
    ) -> Bool

    static let shared = MediaGalleryMessageNavigationRouter(
        activeChatProvider: defaultActiveChat,
        activeChatHandler: openInActiveChat,
        appRouteHandler: openThroughAppRouter
    )

    private let activeChatProvider: ActiveChatProvider
    private let activeChatHandler: ActiveChatHandler
    private let appRouteHandler: AppRouteHandler

    init(
        activeChatProvider: @escaping ActiveChatProvider,
        activeChatHandler: @escaping ActiveChatHandler,
        appRouteHandler: @escaping AppRouteHandler
    ) {
        self.activeChatProvider = activeChatProvider
        self.activeChatHandler = activeChatHandler
        self.appRouteHandler = appRouteHandler
    }

    func route(
        _ request: ChatOpenMessageRequest,
        from presenter: UIViewController
    ) -> MediaGalleryMessageNavigationRouteResult {
        if let activeChat = activeChatProvider(presenter, request),
           activeChat.owner == request.owner,
           activeChat.jid == request.chatJid,
           activeChat.conversationType == request.conversationType {
            activeChatHandler(activeChat, presenter, request)
            return .activeChat
        }

        let route = AppRoute.chatMessage(
            owner: request.owner,
            jid: request.chatJid,
            conversationType: request.conversationType,
            openMessageRequest: request,
            configure: nil
        )
        return appRouteHandler(route, presenter) ? .navigationStack : .unavailable
    }

    private static func defaultActiveChat(
        presenter: UIViewController,
        request: ChatOpenMessageRequest
    ) -> ChatViewController? {
        let route = InfoCardChatSearchRouting.route(
            owner: request.owner,
            jid: request.chatJid,
            conversationType: request.conversationType
        )
        var roots: [UIViewController] = []
        if let navigationController = presenter.navigationController {
            roots.append(navigationController)
            if let presentingViewController = navigationController.presentingViewController {
                roots.append(presentingViewController)
            }
        }
        if let presentingViewController = presenter.presentingViewController {
            roots.append(presentingViewController)
        }
        if let root = SceneWindowProvider.presentationRootViewController {
            roots.append(root)
        }

        var visited = Set<ObjectIdentifier>()
        for root in roots {
            let identifier = ObjectIdentifier(root)
            guard visited.insert(identifier).inserted else { continue }
            if let chat = InfoCardChatSearchRouting.matchingCurrentChat(
                in: root,
                route: route
            ) {
                return chat
            }
        }
        return nil
    }

    private static func openInActiveChat(
        chat: ChatViewController,
        presenter: UIViewController,
        request: ChatOpenMessageRequest
    ) {
        let open = {
            chat.queueOpenMessageRequest(request)
        }
        if let navigationController = presenter.navigationController,
           navigationController.viewControllers.contains(where: { $0 === chat }) {
            navigationController.popToViewController(chat, animated: true)
            DispatchQueue.main.async(execute: open)
            return
        }

        let modal = presenter.navigationController ?? presenter
        if modal.presentingViewController != nil {
            modal.dismiss(animated: true, completion: open)
            return
        }
        open()
    }

    private static func openThroughAppRouter(
        route: AppRoute,
        presenter: UIViewController
    ) -> Bool {
        guard let coordinator = AppRootCoordinator.active else {
            return false
        }
        let open = {
            coordinator.route(route)
        }
        let modal = presenter.navigationController ?? presenter
        if modal.presentingViewController != nil {
            modal.dismiss(animated: true) {
                _ = open()
            }
            return true
        }
        return open()
    }
}
