/*
Copyright (c) 2026 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
package fountain::fprobe.config

import std.collection.ArrayList
import std.convert.*
import std.posix.gethostname
import fountain::f_config.Config
import fountain::fprobe.collect.hw.SnmpDevice
import fountain::fprobe.rpc.NodeEndpoint

/**
 * agent 子命令的运行期配置。
 *
 * 解析与校验分离：`load` 只读取并保留原始错误，`validate` 一次返回全部问题，
 * 让进程能在监听端口之前打印完整原因并退出 2。
 */
public class AgentSettings {
    public var port: UInt16 = 12323
    public var host: String = defaultHost()
    public var intervalMs: Int64 = 5000
    public var customDir: String = "./custom"
    public var customFailFast: Bool = true
    public var diskExcludeFs: Array<String> = ["tmpfs", "devtmpfs", "overlay", "squashfs"]
    /** `probe_serviceTargets` 的原始 `name@url` 项，由服务探针逐项解析。 */
    public var serviceTargets: Array<String> = []
    public var mvcHealthUrl: String = ""
    public var rpcHealthTargets: Array<NodeEndpoint> = []
    public var snmpDevices: Array<SnmpDevice> = []
    public var ipmiEnabled: Bool = false
    public var smartDevices: Array<String> = []
    public var networkInterfaces: Array<String> = []
    public var httpTimeoutMs: Int64 = 2000
    public var commandTimeoutMs: Int64 = 3000

    private var errors = ArrayList<String>()

    private init() {}

    public static func load(): AgentSettings {
        let settings = AgentSettings()

        match (configString("probe_port")) {
            case Some(raw) =>
                match (Int64.tryParse(raw)) {
                    case Some(value) =>
                        if (value < 1 || value > 65535) {
                            settings.errors.add('probe_port 必须是 1..65535 之间的整数，实际为 "${raw}"')
                        } else {
                            settings.port = UInt16(value)
                        }
                    case None => settings.errors.add('probe_port 不是合法端口: "${raw}"')
                }
            case None => ()
        }

        match (configString("probe_host")) {
            case Some(value) => settings.host = value
            case None => ()
        }

        settings.intervalMs = readInt("probe_intervalMs", settings.intervalMs, 1, settings.errors)

        match (configString("probe_customDir")) {
            case Some(value) => settings.customDir = value
            case None => ()
        }

        match (configString("probe_customFailFast")) {
            case Some(raw) =>
                match (Bool.tryParse(raw)) {
                    case Some(value) => settings.customFailFast = value
                    case None => settings.errors.add('probe_customFailFast 不是合法布尔值: "${raw}"')
                }
            case None => ()
        }

        match (configString("probe_diskExcludeFs")) {
            case Some(raw) => settings.diskExcludeFs = parseDiskExcludeFs(raw, settings.errors)
            case None => ()
        }

        settings.serviceTargets = parseServiceTargets(Config.getStringArray("probe_serviceTargets"),
            settings.errors)

        match (configString("probe_mvcHealthUrl")) {
            case Some(value) =>
                if (isHttpUrl(value)) {
                    settings.mvcHealthUrl = value
                } else {
                    settings.errors.add('probe_mvcHealthUrl 必须是 http(s) 地址，实际为 "${value}"')
                }
            case None => ()
        }

        settings.rpcHealthTargets = parseRpcHealthTargets(Config.getStringArray("probe_rpcHealthTargets"),
            settings.errors)
        settings.snmpDevices = parseSnmpDevices(Config.getStringArray("probe_snmpDevices"), settings.errors)
        settings.smartDevices = parseSmartDevices(Config.getStringArray("probe_smartDevices"), settings.errors)
        settings.networkInterfaces = parseNetworkInterfaces(Config.getStringArray("probe_networkInterfaces"),
            settings.errors)

        match (configString("probe_ipmiEnabled")) {
            case Some(raw) =>
                match (Bool.tryParse(raw)) {
                    case Some(value) => settings.ipmiEnabled = value
                    case None => settings.errors.add('probe_ipmiEnabled 不是合法布尔值: "${raw}"')
                }
            case None => ()
        }

        settings.httpTimeoutMs = readInt("probe_httpTimeoutMs", settings.httpTimeoutMs, 1, settings.errors)
        settings.commandTimeoutMs = readInt("probe_commandTimeoutMs", settings.commandTimeoutMs, 1,
            settings.errors)

        settings
    }

    public func validate(): Array<String> {
        errors.toArray()
    }

    /**
     * 把 `probe_port` 映射到 f_rpc 读取的 `rpcServer_port`。
     *
     * 只能在 `validate()` 通过之后调用，避免把非法端口带进 RPC 初始化。
     */
    public func apply(): Unit {
        Config.set([("rpcServer_port", port)])
    }
}

@When[os != "Windows"]
private func defaultHost(): String {
    let name = gethostname().trimAscii()
    if (name.isEmpty()) {
        "localhost"
    } else {
        name
    }
}

@When[os == "Windows"]
private func defaultHost(): String {
    match (std.env.getVariable("COMPUTERNAME")) {
        case Some(name) => name
        case None => "localhost"
    }
}
