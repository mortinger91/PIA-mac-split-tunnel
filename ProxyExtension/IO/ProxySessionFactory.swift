import Foundation
import NetworkExtension

// Protocol to abstract away ProxySession(TCP,UDP) creation.
// We can implement this protocol in mocks for use in testing.
protocol ProxySessionFactory {
    func create(flow: FlowTCP, config: SessionConfig, id: IDGenerator.ID) -> ProxySession
    func create(flow: FlowUDP, config: SessionConfig, id: IDGenerator.ID) -> ProxySession
}

// Concrete implementation - the one we actually use in production.
final class DefaultProxySessionFactory: ProxySessionFactory {
    // For TCP sessions
    public func create(flow: FlowTCP, config: SessionConfig, id: IDGenerator.ID) -> ProxySession {
        return ProxySessionTCP(flow: flow, config: config, id: id)
    }

    // For UDP sessions
    public func create(flow: FlowUDP, config: SessionConfig, id: IDGenerator.ID) -> ProxySession {
        return ProxySessionUDP(flow: flow, config: config, id: id)
    }
}
