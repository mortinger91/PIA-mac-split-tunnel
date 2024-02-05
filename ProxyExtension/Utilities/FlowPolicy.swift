import Foundation
import NetworkExtension

// Given a flow, find the policy for that flow - ignore, block, proxy
// This class just wraps AppPolicy, which takes an app "descriptor", either
// an appID or a full path to an executable. It first tries to find a policy based
// on appID, and failing that (if it gets back an .ignore) it tries the full path which
// it extracts from the flow audit token.
final class FlowPolicy {
    let vpnState: VpnState

    init(vpnState: VpnState) {
        self.vpnState = vpnState
    }

    public static func policyFor(flow: Flow, vpnState: VpnState) -> AppPolicy.Policy {
        FlowPolicy(vpnState: vpnState).policyFor(flow: flow)
    }

    public static func modeFor(flow: Flow, vpnState: VpnState) -> AppPolicy.Mode {
        FlowPolicy(vpnState: vpnState).modeFor(flow: flow)
    }

    // Given a flow, return the app policy to apply (.proxy, .block. ignore)
    public func policyFor(flow: Flow) -> AppPolicy.Policy {
        guard let descriptor = descriptorFor(flow: flow) else {
            return .ignore
        }

        let policy = AppPolicy.policyFor(descriptor, vpnState: vpnState)
        let mode = AppPolicy.modeFor(descriptor, vpnState: vpnState)

        // Block Ipv6 vpnOnly flows
        // Do not block Ipv6 bypass flows (let them get proxied)
        if mode == .vpnOnly && !isFlowIPv4(flow) {
            return .block
        } else {
            return policy
        }
    }

    public func modeFor(flow: Flow) -> AppPolicy.Mode {
        guard let descriptor = descriptorFor(flow: flow) else {
            return .unspecified
        }
        return AppPolicy.modeFor(descriptor, vpnState: vpnState)
    }

    public func descriptorFor(flow: Flow) -> String? {
        // First try to find an identifier for the app using the appId
        let appID = flow.sourceAppSigningIdentifier
        if !appID.isEmpty {
            return appID
        } else {
            // Fall back to appPath if appID is not available
            return pathFromAuditToken(token: flow.sourceAppAuditToken)
        }
    }

    // Given an audit token of an app flow - extract out the executable path for
    // the app generating the flow.
    private func pathFromAuditToken(token: Data?) -> String? {
        guard let auditToken = token else {
            log(.warning, "Audit token is nil")
            return nil
        }

        // The pid of the process behind the flow
        var pid: pid_t = 0

        // An audit token is opaque Data - but we can use it to extract the pid (and other things)
        // by converting it to an audit_token_t and then using libbsm APIs to extract what we want.
        auditToken.withUnsafeBytes { bytes in
            let auditTokenValue = bytes.bindMemory(to: audit_token_t.self).baseAddress!.pointee

            pid = audit_token_to_pid(auditTokenValue)
        }

        guard pid != 0 else {
            log(.warning, "Could not get a pid from the audit token")
            return nil
        }

        // Get the executable path from the pid
        guard let path = getProcessPath(pid: pid) else {
            log(.warning, "Found a process with pid \(pid) but could not convert to a path")
            return nil
        }

        return path
    }

    private func isFlowIPv4(_ flow: Flow) -> Bool {
        if let flowTCP = flow as? FlowTCP {
            // Check if the address is an IPv6 address, and negate it. IPv6 addresses always contain a ":"
            // We can't do the opposite (such as just checking for "." for an IPv4 address) due to IPv4-mapped IPv6 addresses
            // which are IPv6 addresses but include IPv4 address notation.
            if let endpoint = flowTCP.remoteEndpoint as? NWHostEndpoint {
                // We have a valid NWHostEndpoint - let's see if it's IPv6
                if endpoint.hostname.contains(":") {
                    return false
                }
            }
        }

        return true
    }
}
