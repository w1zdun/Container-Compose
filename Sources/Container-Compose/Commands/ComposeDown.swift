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
//  ComposeDown.swift
//  Container-Compose
//
//  Created by Morris Richman on 6/19/25.
//

import ArgumentParser
import ContainerCommands
import ContainerAPIClient
import Foundation
import Yams

public struct ComposeDown: AsyncParsableCommand {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "down",
        abstract: "Stop containers with compose"
    )

    @Argument(help: "Specify the services to stop")
    var services: [String] = []

    @Flag(name: [.customShort("v"), .customLong("volumes")], help: "Remove named volumes declared in the compose file")
    var volumes: Bool = false

    @OptionGroup
    var process: Flags.Process

    private var cwd: String { composeFileOptions.effectiveCwd(processCwd: process.cwd) }

    @OptionGroup
    var composeFileOptions: ComposeFileOptions

    private static let supportedComposeFilenames = [
        "compose.yml",
        "compose.yaml",
        "docker-compose.yml",
        "docker-compose.yaml",
    ]

    private var cwdURL: URL {
        URL(fileURLWithPath: cwd)
    }

    private var composePath: String {
        if let composeFilename = composeFileOptions.composeFilename {
            return resolvedPath(for: composeFilename, relativeTo: cwdURL)
        }

        for filename in Self.supportedComposeFilenames {
            let candidate = cwdURL.appending(path: filename).path
            if fileManager.fileExists(atPath: candidate) {
                return candidate
            }
        }

        return cwdURL.appending(path: Self.supportedComposeFilenames[0]).path
    }

    private var envFilePath: String {
        let envFile = process.envFile.first ?? ".env"
        return resolvedPath(for: envFile, relativeTo: cwdURL)
    }

    private var fileManager: FileManager { FileManager.default }
    private var projectName: String?
    private var environmentVariables: [String: String] = [:]

    public mutating func run() async throws {

        // Read docker-compose.yml content
        guard let yamlData = fileManager.contents(atPath: composePath) else {
            let path = URL(fileURLWithPath: composePath)
                .deletingLastPathComponent()
                .path
            throw YamlError.composeFileNotFound(path)
        }

        // Decode the YAML file into the DockerCompose struct
        let dockerComposeString = String(data: yamlData, encoding: .utf8)!
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: dockerComposeString)

        // Load environment variables from .env file
        environmentVariables = loadEnvFile(path: envFilePath)

        // Determine project name for container naming
        let resolvedProjectName = resolveProjectName(
            flagValue: composeFileOptions.projectName,
            composeName: dockerCompose.name,
            envVars: environmentVariables,
            cwd: cwd
        )
        projectName = resolvedProjectName
        print("Info: Docker Compose project name resolved as: \(resolvedProjectName)")

        var services = try Service.topoSortConfiguredServices(configuredServices(from: dockerCompose.services))

        // Filter for specified services only (docker compose parity: `down app`
        // does not touch app's dependencies).
        if !self.services.isEmpty {
            services = services.filter({ serviceName, _ in
                self.services.contains(serviceName)
            })
        }

        // Removing a volume fails while a container still references it, so
        // when -v is passed the containers are removed too (matching docker
        // compose down, which always removes containers).
        try await stopOldStuff(services, remove: volumes)

        if volumes {
            try await removeNamedVolumes(from: dockerCompose, services: services)
        }
    }

    private func removeNamedVolumes(from dockerCompose: DockerCompose, services: [(serviceName: String, service: Service)]) async throws {
        guard let projectName else { return }

        var handledKeys: Set<String> = []
        for (volumeKey, volumeConfig) in dockerCompose.volumes ?? [:] {
            handledKeys.insert(volumeKey)
            let (nativeName, isExternal) = resolveNamedVolume(key: volumeKey, config: volumeConfig, projectName: projectName)
            if isExternal {
                print("Info: Volume '\(volumeKey)' is external and will not be removed.")
                continue
            }
            await removeNamedVolume(key: volumeKey, name: nativeName)
        }

        // Also remove named volumes that `up` created on demand for service
        // references not declared top-level.
        for (_, service) in services {
            for volume in service.volumes ?? [] {
                guard let source = volume.split(separator: ":", maxSplits: 2).map(String.init).first,
                    isNamedVolumeSource(source), !handledKeys.contains(source)
                else { continue }
                handledKeys.insert(source)
                let (nativeName, _) = resolveNamedVolume(key: source, config: nil, projectName: projectName)
                await removeNamedVolume(key: source, name: nativeName)
            }
        }
    }

    private func removeNamedVolume(key: String, name: String) async {
        print("Removing volume: \(key) (\(name))")
        do {
            try await ClientVolume.delete(name: name)
            print("Successfully removed volume: \(name)")
        } catch {
            guard (try? await ClientVolume.inspect(name)) == nil else {
                print("Error Removing Volume '\(name)': \(error)")
                return
            }
            print("Warning: Volume '\(name)' not found, skipping.")
        }
    }

    private func stopOldStuff(_ services: [(serviceName: String, service: Service)], remove: Bool) async throws {
        guard let projectName else { return }

        for (serviceName, service) in services {
            // Respect explicit container_name (with variable interpolation), otherwise use default pattern
            let containerName = resolveContainerName(
                explicit: service.container_name, projectName: projectName, serviceName: serviceName, envVars: environmentVariables)

            print("Stopping container: \(containerName)")
            
            let client = ContainerClient()
            
            guard let container = try? await client.get(id: containerName) else {
                print("Warning: Container '\(containerName)' not found, skipping.")
                continue
            }

            do {
                try await client.stop(id: container.id)
                print("Successfully stopped container: \(containerName)")
            } catch {
                print("Error Stopping Container: \(error)")
            }
            if remove {
                do {
                    try await client.delete(id: container.id)
                    print("Successfully removed container: \(containerName)")
                } catch {
                    print("Error Removing Container: \(error)")
                }
            }
        }
    }
}
