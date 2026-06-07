//===----------------------------------------------------------------------===//
// Copyright © 2025 Morris Richman and the Container-Compose project authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

//
//  Helper Functions.swift
//  container-compose-app
//
//  Created by Morris Richman on 6/17/25.
//

import Foundation
import Yams
import Rainbow
import ContainerCommands
import ContainerAPIClient
import ContainerResource

public func resolvedPath(for path: String, relativeTo baseURL: URL) -> String {
    let expandedPath = NSString(string: path).expandingTildeInPath
    return URL(fileURLWithPath: expandedPath, relativeTo: baseURL).standardizedFileURL.path
}


/// Loads environment variables from a .env file.
/// - Parameter path: The full path to the .env file.
/// - Returns: A dictionary of key-value pairs representing environment variables.
public func loadEnvFile(path: String) -> [String: String] {
    var envVars: [String: String] = [:]
    let fileURL = URL(fileURLWithPath: path)
    do {
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = content.split(separator: "\n")
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // Ignore empty lines and comments
            if !trimmedLine.isEmpty && !trimmedLine.starts(with: "#") {
                // Parse key=value pairs
                if let eqIndex = trimmedLine.firstIndex(of: "=") {
                    let key = String(trimmedLine[..<eqIndex])
                    let value = String(trimmedLine[trimmedLine.index(after: eqIndex)...])
                    envVars[key] = value
                }
            }
        }
    } catch {
        // print("Warning: Could not read .env file at \(path): \(error.localizedDescription)")
        // Suppress error message if .env file is optional or missing
    }
    return envVars
}

/// Resolves environment variables within a string (e.g., ${VAR:-default}, ${VAR:?error}).
/// This function supports default values and error-on-missing variable syntax.
/// - Parameters:
///   - value: The string possibly containing environment variable references.
///   - envVars: A dictionary of environment variables to use for resolution.
/// - Returns: The string with all recognized environment variables resolved.
public func resolveVariable(_ value: String, with envVars: [String: String]) -> String {
    var resolvedValue = value
    // Regex to find ${VAR}, ${VAR:-default}, ${VAR:?error}
    let regex = try! NSRegularExpression(pattern: #"\$\{([A-Za-z0-9_]+)(:?-(.*?))?(:\?(.*?))?\}"#, options: [])
    
    // Combine process environment with loaded .env file variables, prioritizing process environment
    let combinedEnv = ProcessInfo.processInfo.environment.merging(envVars) { (current, _) in current }
    
    // Loop to resolve all occurrences of variables in the string
    while let match = regex.firstMatch(in: resolvedValue, options: [], range: NSRange(resolvedValue.startIndex..<resolvedValue.endIndex, in: resolvedValue)) {
        guard let varNameRange = Range(match.range(at: 1), in: resolvedValue) else { break }
        let varName = String(resolvedValue[varNameRange])
        
        if let envValue = combinedEnv[varName] {
            // Variable found in environment, replace with its value
            resolvedValue.replaceSubrange(Range(match.range(at: 0), in: resolvedValue)!, with: envValue)
        } else if let defaultValueRange = Range(match.range(at: 3), in: resolvedValue) {
            // Variable not found, but default value is provided, replace with default
            let defaultValue = String(resolvedValue[defaultValueRange])
            resolvedValue.replaceSubrange(Range(match.range(at: 0), in: resolvedValue)!, with: defaultValue)
        } else if match.range(at: 5).location != NSNotFound, let errorMessageRange = Range(match.range(at: 5), in: resolvedValue) {
            // Variable not found, and error-on-missing syntax used, print error and exit
            let errorMessage = String(resolvedValue[errorMessageRange])
            fputs("Error: Missing required environment variable '\(varName)': \(errorMessage)\n", stderr)
            Application.exit(withError: "Error: Missing required environment variable '\(varName)': \(errorMessage)\n")
        } else {
            // Variable not found and no default/error specified, leave as is and break loop to avoid infinite loop
            break
        }
    }
    return resolvedValue
}

/// Derives a project name from the current working directory. It replaces any '.' characters with
/// '_' to ensure compatibility with container naming conventions.
///
/// - Parameter cwd: The current working directory path.
/// - Returns: A sanitized project name suitable for container naming.
public func deriveProjectName(cwd: String) -> String {
    // We need to replace '.' with _ because it is not supported in the container name
    let projectName = URL(fileURLWithPath: cwd).lastPathComponent.replacingOccurrences(of: ".", with: "_")
    return projectName
}

/// Resolves the project name using the same precedence as Docker Compose:
/// 1. The `-p`/`--project-name` flag, 2. the `COMPOSE_PROJECT_NAME` environment variable
/// (process environment takes precedence over the .env file), 3. the top-level `name` field
/// from the compose file (with variable interpolation), 4. the working directory name.
///
/// - Parameters:
///   - flagValue: The value of the `-p`/`--project-name` flag, if provided.
///   - composeName: The top-level `name` field from the compose file, if present.
///   - envVars: Environment variables loaded from the .env file.
///   - cwd: The current working directory path, used as the fallback.
///   - processEnv: The process environment (injectable for testing).
/// - Returns: The resolved project name.
public func resolveProjectName(
    flagValue: String?,
    composeName: String?,
    envVars: [String: String],
    cwd: String,
    processEnv: [String: String] = ProcessInfo.processInfo.environment
) -> String {
    if let flagValue, !flagValue.isEmpty {
        return flagValue
    }
    let combinedEnv = processEnv.merging(envVars) { (current, _) in current }
    if let envName = combinedEnv["COMPOSE_PROJECT_NAME"], !envName.isEmpty {
        return envName
    }
    if let composeName {
        return resolveVariable(composeName, with: envVars)
    }
    return deriveProjectName(cwd: cwd)
}

/// Maximum length of a single DNS label (RFC 1035). apple/container validates
/// this only at query time, not at container creation, so an over-long label
/// produces a container that exists but fails to resolve — we warn up front.
let maxDNSLabelLength = 63
/// Maximum total length of a DNS name in wire form (RFC 1035).
let maxDNSNameLength = 253
/// Soft cap on apple/container entity names — see [[apple-container-limitations]].
let maxContainerNameLength = 64

/// Derives a per-network DNS zone label from an IPv4 subnet/CIDR by dropping the
/// mask and replacing dots with dashes (`"10.99.5.0/24"` -> `"10-99-5-0"`). The
/// full network address is globally unique on the host, so the label never
/// collides between distinct networks. Returns `nil` for empty input, IPv6
/// (contains `:`), or anything that is not a dotted-quad IPv4 address — callers
/// fall back to a project slug.
func zoneLabel(fromSubnet subnet: String) -> String? {
    let address = subnet.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
    guard !address.isEmpty, !address.contains(":") else { return nil }
    let octets = address.split(separator: ".", omittingEmptySubsequences: false)
    guard octets.count == 4,
        octets.allSatisfy({ octet in
            !octet.isEmpty && octet.count <= 3 && octet.allSatisfy(\.isNumber)
                && (UInt(octet).map { $0 <= 255 } ?? false)
        })
    else { return nil }
    return address.replacingOccurrences(of: ".", with: "-")
}

/// Sanitizes a project name into a DNS-safe zone label used as the fallback when
/// a network's IPv4 subnet can't be determined: lowercase, every character
/// outside `[a-z0-9-]` collapsed to a single `-`, leading/trailing dashes
/// stripped, truncated to one DNS label. Empty results become a deterministic
/// placeholder. Underscores (legal in `container` names but not in RFC
/// hostnames) and other characters are normalized here. Two long project names
/// can collide after truncation — fallback territory only; an explicit
/// `subnet:` gives a stable, collision-free CIDR zone instead.
func slugifyZone(_ name: String) -> String {
    var slug = ""
    var pendingDash = false
    for character in name.lowercased() {
        if character.isASCII, character.isLetter || character.isNumber {
            if pendingDash, !slug.isEmpty { slug.append("-") }
            slug.append(character)
            pendingDash = false
        } else {
            pendingDash = true
        }
    }
    if slug.count > maxDNSLabelLength {
        slug = String(slug.prefix(maxDNSLabelLength))
        while slug.hasSuffix("-") { slug.removeLast() }
    }
    return slug.isEmpty ? "proj" : slug
}

/// Collapses dots in a single name label to dashes so a service/`container_name`
/// containing a dot (e.g. `api.internal`) stays one DNS label when composed into
/// a zoned FQDN, instead of silently becoming an extra subdomain level.
func sanitizeNameLabel(_ label: String) -> String {
    label.replacingOccurrences(of: ".", with: "-")
}

/// Returns human-readable warnings if a composed container/DNS name would fail
/// (or be rejected). Empty when the name is valid. Separated from
/// `resolveContainerName` so it is unit-testable without capturing stdout.
func dnsNameWarnings(for name: String) -> [String] {
    var warnings: [String] = []
    for label in name.split(separator: ".", omittingEmptySubsequences: false) where label.utf8.count > maxDNSLabelLength {
        warnings.append(
            "DNS label '\(label)' in '\(name)' exceeds \(maxDNSLabelLength) bytes; DNS resolution will fail (RFC 1035).")
    }
    if name.utf8.count > maxDNSNameLength {
        warnings.append("DNS name '\(name)' exceeds \(maxDNSNameLength) bytes; DNS resolution will fail.")
    }
    if name.count > maxContainerNameLength {
        warnings.append("container name '\(name)' exceeds \(maxContainerNameLength) characters; the runtime may reject it.")
    }
    return warnings
}

/// Resolves the container name for a service. An explicit `container_name`
/// (with variable interpolation, e.g. `${NAME:-fallback}`) takes precedence.
///
/// When both `zone` and `dnsDomain` are non-empty (zone mode), the name is the
/// per-project FQDN `<base>.<zone>.<dnsDomain>` — `base` is the interpolated
/// `container_name` or, lacking one, the bare `serviceName` (the project is
/// encoded in the zone, so the `<projectName>-` prefix is dropped). The runtime
/// registers a dotted name verbatim as an FQDN, which is what makes the same
/// service name reachable in parallel projects. Otherwise the classic
/// `<projectName>-<serviceName>` (or verbatim explicit) name is returned.
func resolveContainerName(
    explicit: String?,
    projectName: String,
    serviceName: String,
    zone: String? = nil,
    dnsDomain: String? = nil,
    envVars: [String: String] = [:]
) -> String {
    let zoneMode = !(zone ?? "").isEmpty && !(dnsDomain ?? "").isEmpty
    let base: String
    if let explicit {
        base = resolveVariable(explicit, with: envVars)
    } else {
        base = zoneMode ? serviceName : "\(projectName)-\(serviceName)"
    }
    guard zoneMode, let zone, let dnsDomain else { return base }
    let name = "\(sanitizeNameLabel(base)).\(zone).\(dnsDomain)"
    for warning in dnsNameWarnings(for: name) { print("Warning: \(warning)") }
    return name
}

/// Splits a shell-style command string into arguments: whitespace separation,
/// single/double quotes, and backslash escapes. No expansion is performed —
/// this matches how Docker Compose parses string-form `command:` and
/// `entrypoint:` (shellwords), e.g.
/// `sh -c "npm install && npm run build"` -> ["sh", "-c", "npm install && npm run build"].
func shellLex(_ input: String) -> [String] {
    var args: [String] = []
    var current = ""
    var hasToken = false
    var inSingleQuotes = false
    var inDoubleQuotes = false
    var escaped = false

    for character in input {
        if escaped {
            current.append(character)
            escaped = false
            hasToken = true
            continue
        }
        if character == "\\" && !inSingleQuotes {
            escaped = true
            continue
        }
        if character == "'" && !inDoubleQuotes {
            inSingleQuotes.toggle()
            hasToken = true
            continue
        }
        if character == "\"" && !inSingleQuotes {
            inDoubleQuotes.toggle()
            hasToken = true
            continue
        }
        if character.isWhitespace && !inSingleQuotes && !inDoubleQuotes {
            if hasToken {
                args.append(current)
                current = ""
                hasToken = false
            }
            continue
        }
        current.append(character)
        hasToken = true
    }
    if hasToken {
        args.append(current)
    }
    return args
}

/// Builds a service-name -> DNS host mapping for the given services, used to
/// resolve inter-service references in environment values when the 'container'
/// tool has a local DNS domain configured.
///
/// When a service has a zone label in `serviceZones`, its host is the zoned
/// FQDN (`<base>.<zone>.<domain>`) — already fully qualified, so the domain is
/// not appended a second time. Without a zone the classic
/// `<containerName>.<domain>` form is used.
func buildServiceHosts(
    services: [(serviceName: String, service: Service)],
    projectName: String,
    dnsDomain: String,
    serviceZones: [String: String] = [:],
    envVars: [String: String] = [:]
) -> [String: String] {
    var hosts: [String: String] = [:]
    for (serviceName, service) in services {
        if let zone = serviceZones[serviceName], !zone.isEmpty {
            hosts[serviceName] = resolveContainerName(
                explicit: service.container_name, projectName: projectName, serviceName: serviceName,
                zone: zone, dnsDomain: dnsDomain, envVars: envVars)
        } else {
            let containerName = resolveContainerName(
                explicit: service.container_name, projectName: projectName, serviceName: serviceName, envVars: envVars)
            hosts[serviceName] = "\(containerName).\(dnsDomain)"
        }
    }
    return hosts
}

/// Extracts the IPv4 subnet (CIDR string, e.g. "10.99.5.0/24") from a network's
/// runtime state — authoritative for both explicit and vmnet-auto-allocated
/// subnets.
func ipv4Subnet(from state: NetworkState) -> String? {
    switch state {
    case .running(_, let status):
        return status.ipv4Subnet.description
    case .created(let config):
        return config.ipv4Subnet?.description
    }
}

/// Resolves the DNS zone label for a top-level network: the real allocated IPv4
/// subnet if the network exists, else the compose-declared subnet. Returns `nil`
/// when neither yields a usable IPv4 CIDR (caller falls back to the project
/// slug). Shared by `up` and `down` so both compute identical names.
func networkZoneLabel(actualName: String, composeSubnet: String?) async -> String? {
    if let state = try? await NetworkClient().get(id: actualName),
        let subnet = ipv4Subnet(from: state),
        let label = zoneLabel(fromSubnet: subnet) {
        return label
    }
    if let composeSubnet, let label = zoneLabel(fromSubnet: composeSubnet) {
        return label
    }
    return nil
}

/// Maps each service to its DNS zone label, taken from its first network's CIDR
/// (via `networkZones`). A service with no `networks:` — or one resolved to the
/// shared builtin default network, whose CIDR is common to every project — gets
/// the project slug instead: a CIDR zone there would collide across projects and
/// regress today's `<project>-<service>` coexistence. Pure (no I/O) so the
/// per-project isolation contract is unit-testable; `up` and `down` share it.
func buildServiceZones(
    services: [(serviceName: String, service: Service)],
    networkZones: [String: String],
    networks: [String: Network?]?,
    projectName: String,
    envVars: [String: String] = [:]
) -> [String: String] {
    let slug = slugifyZone(projectName)
    var zones: [String: String] = [:]
    for (serviceName, service) in services {
        guard let first = service.networks?.first else {
            zones[serviceName] = slug
            continue
        }
        let resolved = resolveVariable(first, with: envVars)
        let actualNetworkName = networks?[first]??.name ?? resolved
        zones[serviceName] = networkZones[actualNetworkName] ?? slug
    }
    return zones
}

/// Converts Docker Compose port specification into a container run -p format.
/// Handles various formats: "PORT", "HOST:PORT", "IP:HOST:PORT", and optional protocol.
/// - Parameter portSpec: The port specification string from docker-compose.yml.
/// - Returns: A properly formatted port binding for `container run -p`.
public func composePortToRunArg(_ portSpec: String) -> String {
    // Check for protocol suffix (e.g., "/tcp" or "/udp")
    var protocolSuffix = ""
    var portBody = portSpec
    if let slashRange = portSpec.range(of: "/", options: [.backwards]) {
        let afterSlash = portSpec[slashRange.lowerBound...]
        let protocolPart = String(afterSlash)
        if protocolPart == "/tcp" || protocolPart == "/udp" {
            protocolSuffix = protocolPart
            portBody = String(portSpec[..<slashRange.lowerBound])
        }
    }

    let components = portBody.split(separator: ":", maxSplits: 3).map(String.init)
    switch components.count {
    case 1:
        let containerPort = components[0]
        return "0.0.0.0:\(containerPort):\(containerPort)\(protocolSuffix)"
    case 2:
        let hostPart = components[0]
        let containerPart = components[1]
        let hasIPv4 = hostPart.contains(".")
        let hasIPv6 = hostPart.contains(":") && hostPart.hasPrefix("[") && hostPart.hasSuffix("]")
        if hasIPv4 || hasIPv6 {
            return "\(hostPart):\(containerPart)\(protocolSuffix)"
        } else {
            return "0.0.0.0:\(hostPart):\(containerPart)\(protocolSuffix)"
        }
    case 3:
        let ipPart = components[0]
        let hostPart = components[1]
        let containerPart = components[2]
        return "\(ipPart):\(hostPart):\(containerPart)\(protocolSuffix)"
    default:
        return portSpec
    }
}

/// Returns `true` when a volume source refers to a named volume rather than a
/// host path (bind mount). Shared by the args builder and the volume pre-scan
/// in `ComposeUp` so the classification can never drift between call sites.
func isNamedVolumeSource(_ source: String) -> Bool {
    !(source.contains("/") || source.starts(with: ".") || source.starts(with: ".."))
}

/// Resolves the actual native volume name for a top-level compose volume entry,
/// following Docker Compose naming rules:
/// - `external`: use the external name (or the key verbatim); never created by this tool.
/// - explicit top-level `name:`: used verbatim.
/// - otherwise: `<projectName>_<key>`.
/// - Parameters:
///   - key: The volume key from the top-level `volumes:` mapping (or a service-level reference).
///   - config: The top-level volume configuration, if declared.
///   - projectName: The resolved compose project name.
/// - Returns: The native volume name and whether the volume is external (pre-existing).
func resolveNamedVolume(key: String, config: Volume?, projectName: String) -> (name: String, isExternal: Bool) {
    if let external = config?.external, external.isExternal {
        return (external.name ?? key, true)
    }
    if let explicitName = config?.name {
        return (explicitName, false)
    }
    return ("\(projectName)_\(key)", false)
}

/// Resolves a build's context directory and Dockerfile to absolute paths,
/// interpolating variables (`${VAR}`, `${VAR:-default}`) in both. Per the
/// Compose spec, `context` is relative to the compose file's directory and
/// `dockerfile` is relative to the resolved context.
func resolveBuildPaths(
    context: String,
    dockerfile: String?,
    composeDirectory: String,
    environmentVariables: [String: String] = [:]
) -> (contextPath: String, dockerfilePath: String) {
    let resolvedContext = resolveVariable(context, with: environmentVariables)
    let contextPath = resolvedPath(for: resolvedContext, relativeTo: URL(fileURLWithPath: composeDirectory, isDirectory: true))
    let resolvedDockerfile = resolveVariable(dockerfile ?? "Dockerfile", with: environmentVariables)
    let dockerfilePath = resolvedPath(for: resolvedDockerfile, relativeTo: URL(fileURLWithPath: contextPath, isDirectory: true))
    return (contextPath, dockerfilePath)
}

/// Merges a service's `environment:` values over the base environment,
/// following Compose semantics: env-file values are literal, while
/// service-level values are variable-interpolated (`${VAR}`, `${VAR:-default}`,
/// resolved from the .env file and the process environment) and override the
/// files.
func mergeServiceEnvironment(
    base: [String: String],
    serviceEnvironment: [String: String]?,
    envVars: [String: String]
) -> [String: String] {
    var combined = base
    for (key, value) in serviceEnvironment ?? [:] {
        combined[key] = resolveVariable(value, with: envVars)
    }
    return combined
}

/// Converts a Docker Compose `volumes:` entry into the `--volume` arguments for `container run`.
/// Internal so tests can reach it via `@testable import ContainerComposeCore`.
func composeVolumeToRunArgs(
    _ volume: String,
    cwd: String,
    fileManager: FileManager = .default,
    environmentVariables: [String: String] = [:],
    namedVolumeNames: [String: String] = [:]
) throws -> [String] {
    let resolvedVolume = resolveVariable(volume, with: environmentVariables)
    var args: [String] = []

    let components = resolvedVolume.split(separator: ":", maxSplits: 2).map(String.init)
    guard components.count >= 2 else {
        print("Warning: Volume entry '\(resolvedVolume)' has an invalid format (expected 'source:destination'). Skipping.")
        return []
    }

    let source = components[0]
    let destination = components[1]
    let mode = components.count == 3 ? components[2] : nil

    func mountArg(source: String) -> String {
        if let mode { return "\(source):\(destination):\(mode)" }
        return "\(source):\(destination)"
    }

    if !isNamedVolumeSource(source) {
        let fullHostPath = resolvedPath(for: source, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true))

        if fileManager.fileExists(atPath: fullHostPath) {
            args.append("-v")
            args.append(mountArg(source: fullHostPath))
        } else {
            do {
                try fileManager.createDirectory(atPath: fullHostPath, withIntermediateDirectories: true, attributes: nil)
                print("Info: Created missing host directory for volume: \(fullHostPath)")
                args.append("-v")
                args.append(mountArg(source: fullHostPath))
            } catch {
                print("Error: Could not create host directory '\(fullHostPath)' for volume '\(resolvedVolume)': \(error.localizedDescription). Skipping this volume.")
            }
        }
    } else {
        // Named volume reference. Map the compose key to the native volume
        // name; the caller is responsible for creating the volume and seeding
        // the mapping. Fall back to the verbatim source if unmapped.
        // `nocopy` is a compose-level signal (skip population from image
        // content), not a runtime mount option — strip it before emitting.
        let nativeName = namedVolumeNames[source] ?? source
        let runtimeMode = mode.flatMap { m -> String? in
            let kept = m.split(separator: ",").filter { $0 != "nocopy" }
            return kept.isEmpty ? nil : kept.joined(separator: ",")
        }
        args.append("-v")
        if let runtimeMode {
            args.append("\(nativeName):\(destination):\(runtimeMode)")
        } else {
            args.append("\(nativeName):\(destination)")
        }
    }

    return args
}

/// Extracts the named-volume mounts from a service's `volumes:` entries, with
/// the information the copy-on-first-use population step needs: the native
/// volume name, the mount destination inside the container, and whether the
/// compose entry opted out via `nocopy`. Bind mounts and malformed entries are
/// skipped. Uses the same classification as `composeVolumeToRunArgs`.
func namedVolumeMounts(
    volumes: [String],
    namedVolumeNames: [String: String],
    environmentVariables: [String: String] = [:]
) -> [(nativeName: String, destination: String, nocopy: Bool)] {
    volumes.compactMap { volume in
        let resolvedVolume = resolveVariable(volume, with: environmentVariables)
        let components = resolvedVolume.split(separator: ":", maxSplits: 2).map(String.init)
        guard components.count >= 2, isNamedVolumeSource(components[0]) else { return nil }
        let nativeName = namedVolumeNames[components[0]] ?? components[0]
        let nocopy = components.count == 3 && components[2].split(separator: ",").contains("nocopy")
        return (nativeName, components[1], nocopy)
    }
}

/// Converts the decoded `services:` mapping into a deterministically ordered
/// array. Dictionary iteration order varies between runs, which previously
/// made the topological sort (and therefore partial `up`/`down` selection and
/// start order among independent services) nondeterministic. YAML file order
/// is lost during decoding, so alphabetical order is used instead.
func configuredServices(from services: [String: Service?]) -> [(serviceName: String, service: Service)] {
    services
        .compactMap({ serviceName, service in
            guard let service else { return nil }
            return (serviceName, service)
        })
        .sorted(by: { $0.serviceName < $1.serviceName })
}

/// Expands the user-requested service names to include their transitive
/// `depends_on` closure, matching `docker compose up <service>` semantics.
/// Names that don't match a configured service are ignored.
func expandServiceSelection(
    requested: [String],
    services: [(serviceName: String, service: Service)]
) -> Set<String> {
    var selected = Set<String>()
    var queue = requested
    while let name = queue.popLast() {
        guard !selected.contains(name) else { continue }
        selected.insert(name)
        if let service = services.first(where: { $0.serviceName == name })?.service {
            queue.append(contentsOf: service.depends_on ?? [])
        }
    }
    return selected
}

extension String: @retroactive Error {}

/// A structure representing the result of a command-line process execution.
public struct CommandResult {
    /// The standard output captured from the process.
    public let stdout: String

    /// The standard error output captured from the process.
    public let stderr: String

    /// The exit code returned by the process upon termination.
    public let exitCode: Int32
}

extension NamedColor: @retroactive Codable {

}
