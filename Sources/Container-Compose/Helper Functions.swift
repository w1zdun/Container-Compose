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

/// Resolves the container name for a service. An explicit `container_name`
/// (with variable interpolation, e.g. `${NAME:-fallback}`) takes precedence;
/// otherwise the default `<projectName>-<serviceName>` pattern is used.
func resolveContainerName(explicit: String?, projectName: String, serviceName: String, envVars: [String: String] = [:]) -> String {
    if let explicit {
        return resolveVariable(explicit, with: envVars)
    }
    return "\(projectName)-\(serviceName)"
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

/// Builds a service-name -> DNS host mapping (`<containerName>.<domain>`) for
/// the given services, used to resolve inter-service references in environment
/// values when the 'container' tool has a local DNS domain configured.
func buildServiceHosts(
    services: [(serviceName: String, service: Service)],
    projectName: String,
    dnsDomain: String,
    envVars: [String: String] = [:]
) -> [String: String] {
    var hosts: [String: String] = [:]
    for (serviceName, service) in services {
        let containerName = resolveContainerName(
            explicit: service.container_name, projectName: projectName, serviceName: serviceName, envVars: envVars)
        hosts[serviceName] = "\(containerName).\(dnsDomain)"
    }
    return hosts
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
