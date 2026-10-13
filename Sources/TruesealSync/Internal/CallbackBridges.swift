import Foundation
@_implementationOnly @preconcurrency import TruesealSyncBindings

// Adapters from the core's UniFFI listener/handler protocols to Swift
// closures. The public API never exposes the FFI protocols.

/// Bridges the awaited message handler (ADR-0026). A throw from the app
/// closure becomes `HandlerError.Failed`, which the core turns into a
/// handler attempt (5 tries with backoff, then `handlerGaveUp`).
final class MessageHandlerBridge: TruesealSyncBindings.TrueSealMessageHandler, @unchecked Sendable {
    private let handler: @Sendable (TrueSealMessage) async throws -> Void

    init(_ handler: @escaping @Sendable (TrueSealMessage) async throws -> Void) {
        self.handler = handler
    }

    func onMessage(message: TruesealSyncBindings.TrueSealMessage) async throws {
        do {
            try await handler(TrueSealMessage(message))
        } catch {
            throw TruesealSyncBindings.HandlerError.Failed(msg: String(describing: error))
        }
    }
}

/// Bridges an event listener. Events are delivered synchronously from the
/// core; listeners must not block (the core's dispatch thread delivers
/// in order).
final class EventListenerBridge: TruesealSyncBindings.TrueSealEventListener, @unchecked Sendable {
    private let listener: @Sendable (TrueSealEvent) -> Void

    init(_ listener: @escaping @Sendable (TrueSealEvent) -> Void) {
        self.listener = listener
    }

    func onEvent(event: TruesealSyncBindings.TrueSealEvent) {
        listener(TrueSealEvent(event))
    }
}

/// Bridges a delivery-issue listener (ADR-0026, optional stream).
final class IssueListenerBridge: TruesealSyncBindings.TrueSealIssueListener, @unchecked Sendable {
    private let listener: @Sendable (DeliveryIssue) -> Void

    init(_ listener: @escaping @Sendable (DeliveryIssue) -> Void) {
        self.listener = listener
    }

    func onDeliveryIssue(issue: TruesealSyncBindings.DeliveryIssue) {
        listener(DeliveryIssue(issue))
    }
}
