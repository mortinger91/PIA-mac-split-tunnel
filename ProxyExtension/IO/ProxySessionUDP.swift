//
//  ProxySessionUDP.swift
//  SplitTunnelProxyExtension
//
//  Created by John Mair on 07/01/2024.
//  Copyright © 2024 PIA. All rights reserved.
//

import Foundation
import NetworkExtension
import NIO

class ProxySessionUDP: ProxySession {
    let flow: NEAppProxyUDPFlow
    let config: SessionConfig
    let id: IDGenerator.ID // Unique identifier for this session
    var channel: Channel!

    // Number of bytes transmitted and received
    var _txBytes: UInt64 = 0
    var _rxBytes: UInt64 = 0

    var txBytes: UInt64 {
        get { return _txBytes }
        set(newTxBytes) { _txBytes = newTxBytes }
    }

    var rxBytes: UInt64 {
        get { return _rxBytes }
        set(newTxBytes) { _rxBytes = newTxBytes }
    }

    init(flow: NEAppProxyUDPFlow, config: SessionConfig, id: IDGenerator.ID) {
        self.flow = flow
        self.config = config
        self.id = id
    }

    deinit {
        log(.debug, "id: \(self.id) \(flow.metaData.sourceAppSigningIdentifier) ProxySession closed. rxBytes=\(formatByteCount(rxBytes)) txBytes=\(formatByteCount(txBytes))")
    }

    public func start() {
        let channelFuture = initChannel(flow: flow)
        channelFuture.whenSuccess { channel in
            log(.debug, "id: \(self.id) \(self.flow.metaData.sourceAppSigningIdentifier) A new UDP socket has been initialized")
            self.channel = channel
            self.scheduleFlowRead(flow: self.flow, channel: self.channel)
        }
        channelFuture.whenFailure { error in
            log(.error, "id: \(self.id) Unable to establish UDP: \(error), dropping the flow.")
            TrafficManagerNIO.dropFlow(flow: self.flow)
        }
    }

    public func terminate() {
        log(.error, "id: \(self.id) \(flow.metaData.sourceAppSigningIdentifier) Terminating the session.")
        TrafficManagerNIO.terminateProxySession(flow: flow, channel: channel)
    }

    public func identifier() -> IDGenerator.ID { self.id }

    // this function creates and bind a new UDP channel
    private func initChannel(flow: NEAppProxyUDPFlow) -> EventLoopFuture<Channel> {
        log(.debug, "id: \(self.id) \(flow.metaData.sourceAppSigningIdentifier) Creating and binding a new UDP socket")
        let bootstrap = DatagramBootstrap(group: config.eventLoopGroup)
            // Enable SO_REUSEADDR.
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                let inboundHandler = InboundHandlerUDP(flow: flow, id: self.id) { (byteCount: UInt64) in
                    self.rxBytes &+= byteCount
                }
                return channel.pipeline.addHandler(inboundHandler)
            }

        do {
            // This is the only call that can throw an exception
            let socketAddress = try SocketAddress(ipAddress: config.interfaceAddress, port: 0)
            // Not calling connect() on a UDP socket.
            // Doing that will turn the socket into a "connected datagram socket".
            // That will prevent the application from exchanging data with multiple endpoints
            let channelFuture = bootstrap.bind(to: socketAddress)
            return channelFuture
        } catch {
            return config.eventLoopGroup.next().makeFailedFuture(error)
        }
    }

    // schedule a new read on a UDP flow
    private func scheduleFlowRead(flow: NEAppProxyUDPFlow, channel: Channel) {
        flow.readDatagrams { outboundData, outboundEndpoints, flowError in
            if flowError == nil, let datas = outboundData, !datas.isEmpty, let endpoints = outboundEndpoints, !endpoints.isEmpty {
                var readIsScheduled = false
                for (data, endpoint) in zip(datas, endpoints) {
                    // Kill the proxy session if we can't create a datagram
                    guard let datagram = self.createDatagram(channel: channel, data: data, endpoint: endpoint) else {
                        self.terminate()
                        return
                    }

                    channel.writeAndFlush(datagram).whenComplete { result in
                        switch result {
                        case .success:
                            // Only schedule another read if we haven't already done so
                            if !readIsScheduled {
                                self.scheduleFlowRead(flow: flow, channel: channel)
                                readIsScheduled = true
                            }
                        case .failure(let error):
                            log(.error, "id: \(self.id) \(flow.metaData.sourceAppSigningIdentifier) \(error) while sending a UDP datagram through the socket")
                            self.terminate()
                        }
                    }
                }
            } else {
                log(.error, "id: \(self.id) \(flow.metaData.sourceAppSigningIdentifier) \((flowError?.localizedDescription) ?? "Empty buffer") occurred during UDP flow.readDatagrams()")
                if let error = flowError as NSError? {
                    // Error code 10 is "A read operation is already pending"
                    // We don't want to terminate the session if that is the error we got
                    if error.domain == "NEAppProxyFlowErrorDomain" && error.code == 10 {
                        return
                    }
                }
                self.terminate()
            }
        }
        //log(.debug, "id: \(self.id) \(flow.metaData.sourceAppSigningIdentifier) A new UDP flow readDatagrams() has been scheduled")
    }

    private func createDatagram(channel: Channel, data: Data, endpoint: NWEndpoint) -> AddressedEnvelope<ByteBuffer>? {
        let buffer = channel.allocator.buffer(bytes: data)
        let (endpointAddress, endpointPort) = getAddressAndPort(endpoint: endpoint as! NWHostEndpoint)
        do {
            let destination = try SocketAddress(ipAddress: endpointAddress!, port: endpointPort!)
            return AddressedEnvelope<ByteBuffer>(remoteAddress: destination, data: buffer)
        } catch {
            log(.error, "id: \(self.id) datagram creation failed")
            return nil
        }
    }
}

final class InboundHandlerUDP: ChannelInboundHandler {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = ByteBuffer

    let flow: NEAppProxyUDPFlow
    let id: IDGenerator.ID
    let onBytesReceived: (UInt64) -> Void

    init(flow: NEAppProxyUDPFlow, id: IDGenerator.ID, onBytesReceived: @escaping (UInt64) -> Void) {
        self.flow = flow
        self.id = id
        self.onBytesReceived = onBytesReceived
    }

    deinit {
        log(.debug, "id: \(self.id) Destructor called for InboundHandlerTCP")
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let input = self.unwrapInboundIn(data)
        guard let bytes = input.data.getBytes(at: 0, length: input.data.readableBytes) else {
            return
        }
        let address = input.remoteAddress.ipAddress
        let port = input.remoteAddress.port
        let endpoint = NWHostEndpoint(hostname: address!, port: String(port!))

        // new traffic is ready to be read on the socket
        // we want to write that data to the flow
        flow.writeDatagrams([Data(bytes)], sentBy: [endpoint]) { flowError in
            if flowError == nil {
                self.onBytesReceived(UInt64(bytes.count))
                // the next time data is available to read on the socket
                // this function will be called again automatically by the event loop
            } else {
                log(.error, "id: \(self.id) \(self.flow.metaData.sourceAppSigningIdentifier) \(flowError!.localizedDescription) occurred when writing a UDP datagram to the flow")
                self.terminate(context: context)
            }
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        log(.error, "id: \(self.id) \(error) in InboundTCPHandler")
        terminate(context: context)
    }

    func terminate(context: ChannelHandlerContext) {
        log(.error, "id: \(self.id) \(flow.metaData.sourceAppSigningIdentifier) Terminating the session.")
        TrafficManagerNIO.terminateProxySession(flow: flow, context: context)
    }
}
