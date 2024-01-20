//
//  FlowUDPProcessor.swift
//  SplitTunnelProxy
//
//  Created by John Mair on 20/01/2024.
//  Copyright © 2024 PIA. All rights reserved.
//

import Foundation
import NIO
import NetworkExtension

final class FlowProcessorUDP {
    typealias ByteCountFunc = (UInt64) -> Void
    let flow: FlowUDP
    let channel: SessionChannel
    let id: IDGenerator.ID

    init(id: IDGenerator.ID, flow: FlowUDP, channel: SessionChannel) {
        self.id = id
        self.flow = flow
        self.channel = channel
    }

    public func scheduleFlowRead(_ onBytesTransmitted: @escaping ByteCountFunc) {
        flow.readDatagrams { outboundData, outboundEndpoints, flowError in
            if flowError == nil, let datas = outboundData, !datas.isEmpty, let endpoints = outboundEndpoints, !endpoints.isEmpty {
                self.forwardToChannel(datas: datas, endpoints: endpoints, onBytesTransmitted: onBytesTransmitted)
            } else {
                self.handleReadError(error: flowError)
            }
        }
    }

    private func handleReadError(error: Error?) {
        log(.error, "id: \(self.id) \(self.flow.sourceAppSigningIdentifier)" +
            " \((error?.localizedDescription) ?? "Empty buffer") occurred during UDP flow.readDatagrams()")
        
        if let error = error as NSError? {
            // Error code 10 is "A read operation is already pending"
            // We don't want to terminate the session if that is the error we got
            if error.domain == "NEAppProxyFlowErrorDomain" && error.code == 10 {
                return
            }
        }
        self.terminate()
    }

    private func createDatagram(data: Data, endpoint: NWEndpoint) -> AddressedEnvelope<ByteBuffer>? {
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

    private func forwardToChannel(datas: [Data], endpoints: [NWEndpoint], onBytesTransmitted: @escaping ByteCountFunc) {
        var readIsScheduled = false
        for (data, endpoint) in zip(datas, endpoints) {
            // Kill the proxy session if we can't create a datagram
            guard let datagram = self.createDatagram(data: data, endpoint: endpoint) else {
                self.terminate()
                return
            }

            let writeFuture = self.channel.writeAndFlush(datagram)
            writeFuture.whenSuccess {
                // Update number of bytes transmitted
                onBytesTransmitted(UInt64(data.count))
                // Only
                if !readIsScheduled {
                    self.scheduleFlowRead(onBytesTransmitted)
                    readIsScheduled = true
                }
            }

            writeFuture.whenFailure { error in
                log(.error, "id: \(self.id) \(self.flow.sourceAppSigningIdentifier) \(error) while sending a UDP datagram through the socket")
                self.terminate()
            }
        }
    }

    private func terminate() {
        ProxySessionUDP.terminateProxySession(id: id, channel: channel, flow: flow)
    }
}
