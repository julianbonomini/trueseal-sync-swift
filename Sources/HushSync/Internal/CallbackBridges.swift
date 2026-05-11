// Internal callback bridge objects.
//
// Each class implements one of the UniFFI callback interface protocols from
// HushSyncBindings and feeds events into an AsyncStream continuation.
// None of these types are public — they live entirely behind the
// @_implementationOnly import boundary.

@_implementationOnly import HushSyncBindings
import Foundation

// MARK: - Blob

final class BlobCallbackHandler: MessageCallback {
    private let continuation: AsyncStream<ReceivedBlob>.Continuation

    init(continuation: AsyncStream<ReceivedBlob>.Continuation) {
        self.continuation = continuation
    }

    func onMessage(blob: Data, senderNoisePub: Data) {
        continuation.yield(ReceivedBlob(data: blob, senderPublicKey: senderNoisePub))
    }
}

// MARK: - Removed from group

final class MemberRemovedCallbackHandler: RemovedFromGroupCallback {
    private let continuation: AsyncStream<MemberEvent>.Continuation

    init(continuation: AsyncStream<MemberEvent>.Continuation) {
        self.continuation = continuation
    }

    func onRemovedFromGroup() {
        continuation.yield(.removedSelf)
    }
}

// MARK: - Group destroyed

final class GroupDestroyedCallbackHandler: GroupDestroyedCallback {
    private let continuation: AsyncStream<MemberEvent>.Continuation

    init(continuation: AsyncStream<MemberEvent>.Continuation) {
        self.continuation = continuation
    }

    func onGroupDestroyed() {
        continuation.yield(.groupDestroyed)
        continuation.finish()
    }
}

// MARK: - Pairing request

final class PairingRequestCallbackHandler: MemberRequestCallback {
    private let continuation: AsyncStream<PairingRequest>.Continuation

    init(continuation: AsyncStream<PairingRequest>.Continuation) {
        self.continuation = continuation
    }

    func onMemberRequest(token: String, name: String) {
        continuation.yield(PairingRequest(token: token, deviceName: name))
    }
}

// MARK: - Member joined / left

final class MemberJoinedCallbackHandler: MemberJoinedCallback {
    private let continuation: AsyncStream<MemberEvent>.Continuation

    init(continuation: AsyncStream<MemberEvent>.Continuation) {
        self.continuation = continuation
    }

    func onMemberJoined(memberId: String, memberName: String) {
        continuation.yield(.joined(SyncMember(id: memberId, name: memberName)))
    }
}

final class MemberLeftCallbackHandler: MemberLeftCallback {
    private let continuation: AsyncStream<MemberEvent>.Continuation

    init(continuation: AsyncStream<MemberEvent>.Continuation) {
        self.continuation = continuation
    }

    func onMemberLeft(memberId: String, memberName: String) {
        continuation.yield(.left(SyncMember(id: memberId, name: memberName)))
    }
}

// MARK: - Connection changed

final class ConnectionChangedCallbackHandler: ConnectionChangedCallback {
    private let continuation: AsyncStream<ConnectionState>.Continuation

    init(continuation: AsyncStream<ConnectionState>.Continuation) {
        self.continuation = continuation
    }

    func onConnectionChanged(connected: Bool) {
        continuation.yield(connected ? .connected : .disconnected)
    }
}
