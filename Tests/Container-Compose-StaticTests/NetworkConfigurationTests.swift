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

import Testing
import Foundation
@testable import Yams
@testable import ContainerComposeCore

@Suite("Network Configuration Tests")
struct NetworkConfigurationTests {
    
    @Test("Parse service with single network")
    func parseServiceWithSingleNetwork() throws {
        let yaml = """
        version: '3.8'
        services:
          web:
            image: nginx:latest
            networks:
              - frontend
        networks:
          frontend:
        """
        
        let decoder = YAMLDecoder()
        let compose = try decoder.decode(DockerCompose.self, from: yaml)
        
        #expect(compose.services["web"]??.networks?.count == 1)
        #expect(compose.services["web"]??.networks?.contains("frontend") == true)
        #expect(compose.networks != nil)
    }
    
    @Test("Parse service with multiple networks")
    func parseServiceWithMultipleNetworks() throws {
        let yaml = """
        version: '3.8'
        services:
          app:
            image: myapp:latest
            networks:
              - frontend
              - backend
        networks:
          frontend:
          backend:
        """
        
        let decoder = YAMLDecoder()
        let compose = try decoder.decode(DockerCompose.self, from: yaml)
        
        #expect(compose.services["app"]??.networks?.count == 2)
        #expect(compose.services["app"]??.networks?.contains("frontend") == true)
        #expect(compose.services["app"]??.networks?.contains("backend") == true)
    }
    
    @Test("Parse network with driver")
    func parseNetworkWithDriver() throws {
        let yaml = """
        driver: bridge
        """
        
        let decoder = YAMLDecoder()
        let network = try decoder.decode(Network.self, from: yaml)
        
        #expect(network.driver == "bridge")
    }
    
    @Test("Parse network with driver_opts")
    func parseNetworkWithDriverOpts() throws {
        let yaml = """
        driver: bridge
        driver_opts:
          com.docker.network.bridge.name: br-custom
        """
        
        let decoder = YAMLDecoder()
        let network = try decoder.decode(Network.self, from: yaml)
        
        #expect(network.driver_opts != nil)
        #expect(network.driver_opts?["com.docker.network.bridge.name"] == "br-custom")
    }
    
    @Test("Parse network with external flag")
    func parseNetworkWithExternal() throws {
        let yaml = """
        external: true
        """
        
        let decoder = YAMLDecoder()
        let network = try decoder.decode(Network.self, from: yaml)
        
        #expect(network.external != nil)
        #expect(network.external?.isExternal == true)
    }
    
    @Test("Parse network with labels")
    func parseNetworkWithLabels() throws {
        let yaml = """
        driver: bridge
        labels:
          com.example.description: "Frontend Network"
          com.example.version: "1.0"
        """
        
        let decoder = YAMLDecoder()
        let network = try decoder.decode(Network.self, from: yaml)
        
        #expect(network.labels?["com.example.description"] == "Frontend Network")
        #expect(network.labels?["com.example.version"] == "1.0")
    }
    
    @Test("Multiple networks in compose")
    func multipleNetworksInCompose() throws {
        let yaml = """
        version: '3.8'
        services:
          web:
            image: nginx:latest
            networks:
              - frontend
          api:
            image: api:latest
            networks:
              - frontend
              - backend
          db:
            image: postgres:14
            networks:
              - backend
        networks:
          frontend:
          backend:
        """
        
        let decoder = YAMLDecoder()
        let compose = try decoder.decode(DockerCompose.self, from: yaml)
        
        #expect(compose.networks?.count == 2)
        #expect(compose.networks?["frontend"] != nil)
        #expect(compose.networks?["backend"] != nil)
        #expect(compose.services["api"]??.networks?.count == 2)
    }
    
    @Test("Service without explicit networks uses default")
    func serviceWithoutExplicitNetworks() throws {
        let yaml = """
        version: '3.8'
        services:
          web:
            image: nginx:latest
        """
        
        let decoder = YAMLDecoder()
        let compose = try decoder.decode(DockerCompose.self, from: yaml)
        
        // Service should exist without networks specified
        #expect(compose.services["web"] != nil)
        #expect(compose.services["web"]??.networks == nil)
    }
    
    @Test("Parse network with ipam subnet")
    func parseNetworkWithIpamSubnet() throws {
        let yaml = """
        ipam:
          driver: default
          config:
            - subnet: 10.99.5.0/24
        """

        let decoder = YAMLDecoder()
        let network = try decoder.decode(Network.self, from: yaml)

        #expect(network.ipam?.driver == "default")
        #expect(network.ipam?.config?.first?.subnet == "10.99.5.0/24")
        #expect(network.ipv4Subnet == "10.99.5.0/24")
    }

    @Test("Parse network with full ipam config")
    func parseNetworkWithFullIpamConfig() throws {
        let yaml = """
        ipam:
          config:
            - subnet: 172.28.0.0/16
              ip_range: 172.28.5.0/24
              gateway: 172.28.5.254
              aux_addresses:
                host1: 172.28.1.5
          options:
            foo: bar
        """

        let decoder = YAMLDecoder()
        let network = try decoder.decode(Network.self, from: yaml)

        let config = try #require(network.ipam?.config?.first)
        #expect(config.subnet == "172.28.0.0/16")
        #expect(config.ip_range == "172.28.5.0/24")
        #expect(config.gateway == "172.28.5.254")
        #expect(config.aux_addresses?["host1"] == "172.28.1.5")
        #expect(network.ipam?.options?["foo"] == "bar")
        #expect(network.ipv4Subnet == "172.28.0.0/16")
    }

    @Test("ipv4Subnet skips IPv6 subnets and picks first IPv4")
    func ipv4SubnetSkipsIPv6() throws {
        let yaml = """
        ipam:
          config:
            - subnet: 2001:db8::/64
            - subnet: 10.99.7.0/24
            - subnet: 10.99.8.0/24
        """

        let decoder = YAMLDecoder()
        let network = try decoder.decode(Network.self, from: yaml)

        #expect(network.ipv4Subnet == "10.99.7.0/24")
    }

    @Test("Network without ipam has nil ipv4Subnet")
    func networkWithoutIpam() throws {
        let yaml = """
        driver: bridge
        """

        let decoder = YAMLDecoder()
        let network = try decoder.decode(Network.self, from: yaml)

        #expect(network.ipam == nil)
        #expect(network.ipv4Subnet == nil)
    }

    @Test("Parse compose with ipam network")
    func parseComposeWithIpamNetwork() throws {
        let yaml = """
        version: '3.8'
        services:
          web:
            image: nginx:latest
            networks:
              - backend
        networks:
          backend:
            ipam:
              config:
                - subnet: 10.99.9.0/24
        """

        let decoder = YAMLDecoder()
        let compose = try decoder.decode(DockerCompose.self, from: yaml)

        #expect(compose.networks?["backend"]??.ipv4Subnet == "10.99.9.0/24")
    }

    @Test("Empty networks definition")
    func emptyNetworksDefinition() throws {
        let yaml = """
        version: '3.8'
        services:
          web:
            image: nginx:latest
        networks:
        """
        
        let decoder = YAMLDecoder()
        let compose = try decoder.decode(DockerCompose.self, from: yaml)
        
        #expect(compose.services["web"] != nil)
    }
}

