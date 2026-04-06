@preconcurrency import NIOCore

final class TunnelRelayHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let peer: Channel

    init(peer: Channel) {
        self.peer = peer
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        peer.writeAndFlush(buffer, promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        peer.close(mode: .all, promise: nil)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer.close(mode: .all, promise: nil)
        context.fireChannelInactive()
    }
}

extension TunnelRelayHandler: @unchecked Sendable {}
