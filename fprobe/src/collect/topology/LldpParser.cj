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
package fountain::fprobe.collect.topology

import std.collection.{ArrayList, HashMap}
import std.convert.*

/** LLDP-MIB 的 remote table 根。 */
public const LLDP_MIB_WALK_OID = "1.0.8802.1.1.2.1.4.1.1"

private const REM_PORT_ID_PREFIX = LLDP_MIB_WALK_OID + ".7."
private const REM_SYS_NAME_PREFIX = LLDP_MIB_WALK_OID + ".9."

/** 一条 LLDP 邻居观察；`localPortIndex` 同时是 LLDP 表中的 local port number（通常等于 ifIndex）。 */
class LldpObservation {
    let localPortIndex: Int64
    let localPort: String
    let remoteSysName: String
    let remotePort: String

    init(localPortIndex: Int64, localPort: String, remoteSysName: String, remotePort: String) {
        this.localPortIndex = localPortIndex
        this.localPort = localPort
        this.remoteSysName = remoteSysName
        this.remotePort = remotePort
    }
}

/**
 * 解析 LLDP-MIB 的 remote port id 与 remote system name。
 *
 * 两类 OID 的后缀结构一致（timeMark.localPortNum.remIndex），先按后缀聚合再配对，
 * 避免依赖 walk 的返回顺序。
 */
func parseLldp(text: String, ports: HashMap<Int64, String>): Array<LldpObservation> {
    let remotePorts = HashMap<String, String>()
    let remoteNames = HashMap<String, String>()
    for (entry in parseWalk(text)) {
        if (entry.oid.startsWith(REM_PORT_ID_PREFIX)) {
            let key = observationKey(entry.oid[REM_PORT_ID_PREFIX.size..])
            if (!key.isEmpty()) {
                remotePorts[key] = entry.value
            }
        } else if (entry.oid.startsWith(REM_SYS_NAME_PREFIX)) {
            let key = observationKey(entry.oid[REM_SYS_NAME_PREFIX.size..])
            if (!key.isEmpty()) {
                remoteNames[key] = entry.value
            }
        }
    }

    let observations = ArrayList<LldpObservation>()
    for ((key, sysName) in remoteNames) {
        if (sysName.isEmpty()) {
            continue
        }
        let index = localPortIndex(key)
        if (index.isNone()) {
            continue
        }
        let localIndex = index.getOrThrow()
        let localPort = match (ports.get(localIndex)) {
            case Some(name) => name
            case None => 'if${localIndex}'
        }
        let remotePort = remotePorts.get(key) ?? ""
        observations.add(LldpObservation(localIndex, localPort, sysName, remotePort))
    }
    observations.toArray()
}

private func observationKey(suffix: String): String {
    let parts = ArrayList<String>()
    for (part in suffix.split(".")) {
        let trimmed = part.trimAscii()
        if (!trimmed.isEmpty()) {
            parts.add(trimmed)
        }
    }
    if (parts.size < 3) {
        return ""
    }
    '${parts[0]}.${parts[1]}.${parts[2]}'
}

private func localPortIndex(key: String): ?Int64 {
    let parts = key.split(".")
    if (parts.size < 2) {
        return None<Int64>
    }
    Int64.tryParse(parts[1])
}
