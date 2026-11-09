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

import std.collection.{ArrayList, HashSet}
import std.convert.*
import fountain::f_config.Config
import fountain::fprobe.collect.hw.SnmpDevice
import fountain::fprobe.rpc.NodeEndpoint

/** 读取非空配置字符串；显式空串按「未配置」处理。 */
func configString(key: String): ?String {
    match (Config.getString(key)) {
        case Some(value) =>
            let text = value.trimAscii()
            if (text.isEmpty()) {
                None<String>
            } else {
                Some(text)
            }
        case None => None<String>
    }
}

/**
 * 读取整数配置并聚合错误。
 *
 * 解析失败与范围不足都写入 `errors`，不会提前中断，保证一次启动能报出全部问题。
 */
func readInt(key: String, defaultValue: Int64, minimum: Int64, errors: ArrayList<String>): Int64 {
    match (configString(key)) {
        case Some(raw) =>
            match (Int64.tryParse(raw)) {
                case Some(value) =>
                    if (value < minimum) {
                        errors.add('${key} 必须大于等于 ${minimum}，实际为 ${value}')
                    }
                    value
                case None =>
                    errors.add('${key} 不是合法整数: "${raw}"')
                    defaultValue
            }
        case None => defaultValue
    }
}

/**
 * 解析逗号分隔的文件系统类型列表。
 *
 * 只接受字母、数字与 `_ . -`：这些值会参与磁盘过滤，不应携带空白或 shell 元字符。
 * 非法项写入 `errors` 并跳过，其余合法项仍然生效。
 */
func parseDiskExcludeFs(raw: String, errors: ArrayList<String>): Array<String> {
    let result = ArrayList<String>()
    for (piece in raw.split(",")) {
        let name = piece.trimAscii()
        if (name.isEmpty()) {
            continue
        }
        if (!isValidFsName(name)) {
            errors.add('probe_diskExcludeFs 含有非法文件系统名: "${name}"')
            continue
        }
        result.add(name.toAsciiLower())
    }
    result.toArray()
}

private func isValidFsName(name: String): Bool {
    for (rune in name.toRuneArray()) {
        let value = UInt32(rune)
        let digit = value >= 48 && value <= 57
        let upper = value >= 65 && value <= 90
        let lower = value >= 97 && value <= 122
        if (!digit && !upper && !lower && value != 95 && value != 46 && value != 45) {
            return false
        }
    }
    true
}

/** 校验并保留 `name@url` 原始项；探针侧仍按同一格式解析。 */
func parseServiceTargets(specs: Array<String>, errors: ArrayList<String>): Array<String> {
    let result = ArrayList<String>()
    for (spec in specs) {
        if (validServiceTarget(spec)) {
            result.add(spec)
        } else {
            errors.add('probe_serviceTargets 存在非法目标 "${spec}"，格式应为 name@http(s)://host[:port] 或 name@tcp://host:port')
        }
    }
    result.toArray()
}

private func validServiceTarget(spec: String): Bool {
    let atIndex = match (spec.indexOf('@')) {
        case Some(index) => index
        case None => return false
    }
    let name = spec[0..atIndex].trimAscii()
    let url = spec[atIndex + 1..].trimAscii()
    if (name.isEmpty() || url.isEmpty()) {
        return false
    }
    let schemeEnd = match (url.indexOf("://")) {
        case Some(index) => index
        case None => return false
    }
    let scheme = url[0..schemeEnd].toAsciiLower()
    if (scheme != "http" && scheme != "https" && scheme != "tcp") {
        return false
    }
    let rest = url[schemeEnd + 3..]
    var end = rest.size
    for (mark in ["/", "?", "#"]) {
        match (rest.indexOf(mark)) {
            case Some(index) => if (index < end) {
                end = index
            }
            case None => ()
        }
    }
    let authority = rest[0..end].trimAscii()
    if (authority.isEmpty()) {
        return false
    }
    let colon = match (authority.lastIndexOf(':')) {
        case Some(index) => index
        case None => return scheme == "http" || scheme == "https"
    }
    let host = authority[0..colon].trimAscii()
    let portText = authority[colon + 1..].trimAscii()
    if (host.isEmpty() || portText.isEmpty()) {
        return false
    }
    match (Int64.tryParse(portText)) {
        case Some(value) => value >= 1 && value <= 65535
        case None => false
    }
}

func isHttpUrl(value: String): Bool {
    (value.startsWith("http://") && value.size > 7) || (value.startsWith("https://") && value.size > 8)
}

/** `probe_rpcHealthTargets` 逐项解析为 `NodeEndpoint`，重复节点名直接报错。 */
func parseRpcHealthTargets(specs: Array<String>, errors: ArrayList<String>): Array<NodeEndpoint> {
    let result = ArrayList<NodeEndpoint>()
    let names = HashSet<String>()
    for (spec in specs) {
        match (NodeEndpoint.parse(spec)) {
            case Some(endpoint) =>
                if (names.contains(endpoint.name)) {
                    errors.add('probe_rpcHealthTargets 存在重复节点名 "${endpoint.name}"（${spec}）')
                } else {
                    names.add(endpoint.name)
                    result.add(endpoint)
                }
            case None => errors.add('probe_rpcHealthTargets 存在非法节点项 "${spec}"，格式应为 name@host:port')
        }
    }
    result.toArray()
}

/** `probe_snmpDevices`：`name@host@community`，host 与 community 不得含空白或 shell 元字符。 */
func parseSnmpDevices(specs: Array<String>, errors: ArrayList<String>): Array<SnmpDevice> {
    let result = ArrayList<SnmpDevice>()
    for (spec in specs) {
        let parts = spec.split("@")
        var valid = parts.size == 3
        if (valid) {
            let name = parts[0].trimAscii()
            let host = parts[1].trimAscii()
            let community = parts[2].trimAscii()
            valid = !name.isEmpty() && !host.isEmpty() && !community.isEmpty() &&
                !hasWhitespace(host) && !hasShellMeta(host) &&
                !hasWhitespace(community) && !hasShellMeta(community)
            if (valid) {
                result.add(SnmpDevice(name, host, community))
            }
        }
        if (!valid) {
            errors.add('probe_snmpDevices 存在非法项 "${spec}"，格式应为 name@host@community（host/community 不得含空白或 shell 元字符）')
        }
    }
    result.toArray()
}

/** `probe_smartDevices`：只接受 `/dev/` 下的安全设备路径。 */
func parseSmartDevices(specs: Array<String>, errors: ArrayList<String>): Array<String> {
    let result = ArrayList<String>()
    for (spec in specs) {
        let device = spec.trimAscii()
        if (isSafeDevicePath(device)) {
            result.add(device)
        } else {
            errors.add('probe_smartDevices 存在非法设备路径 "${device}"，只允许 /dev/ 下的字母、数字与 ._-/')
        }
    }
    result.toArray()
}

private func isSafeDevicePath(device: String): Bool {
    if (!device.startsWith("/dev/") || device.size <= 5) {
        return false
    }
    for (rune in device.toRuneArray()) {
        let value = UInt32(rune)
        let digit = value >= 48 && value <= 57
        let upper = value >= 65 && value <= 90
        let lower = value >= 97 && value <= 122
        let slash = value == 47
        let dot = value == 46
        let underscore = value == 95
        let dash = value == 45
        if (!(digit || upper || lower || slash || dot || underscore || dash)) {
            return false
        }
    }
    true
}

/** `probe_networkInterfaces`：网卡白名单，拒绝空白与 shell 元字符。 */
func parseNetworkInterfaces(specs: Array<String>, errors: ArrayList<String>): Array<String> {
    let result = ArrayList<String>()
    for (spec in specs) {
        let name = spec.trimAscii()
        if (isSafeInterfaceName(name)) {
            result.add(name)
        } else {
            errors.add('probe_networkInterfaces 存在非法网卡名 "${name}"，只允许字母、数字与 _.:-')
        }
    }
    result.toArray()
}

private func isSafeInterfaceName(name: String): Bool {
    if (name.isEmpty() || name == "." || name == "..") {
        return false
    }
    for (rune in name.toRuneArray()) {
        let value = UInt32(rune)
        let digit = value >= 48 && value <= 57
        let upper = value >= 65 && value <= 90
        let lower = value >= 97 && value <= 122
        let underscore = value == 95
        let dot = value == 46
        let colon = value == 58
        let dash = value == 45
        if (!(digit || upper || lower || underscore || dot || colon || dash)) {
            return false
        }
    }
    true
}

/** 参数中任何空白都会破坏「参数数组直传」的边界。 */
private func hasWhitespace(value: String): Bool {
    value.contains(' ') || value.contains('\t') || value.contains('\n') || value.contains('\r')
}

/** 拒绝会改变 shell 语义的字符，即使当前实现从不经过 shell。 */
private func hasShellMeta(value: String): Bool {
    value.contains('`') || value.contains('$') || value.contains(';') || value.contains('&') ||
        value.contains('|') || value.contains('<') || value.contains('>') || value.contains('\\') ||
        value.contains('\'') || value.contains('"') || value.contains('(') || value.contains(')')
}
