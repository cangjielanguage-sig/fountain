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

import std.collection.ArrayList
import std.convert.*

/** IF-MIB 的 ifDescr 子树。 */
public const IF_MIB_WALK_OID = "1.3.6.1.2.1.2.2.1.2"

class WalkEntry {
    let oid: String
    let value: String

    init(oid: String, value: String) {
        this.oid = oid
        this.value = value
    }
}

/** 一个 ifIndex 与端口名的映射。 */
class IfPort {
    let index: Int64
    let name: String

    init(index: Int64, name: String) {
        this.index = index
        this.name = name
    }
}

/** 解析 `snmpwalk`/`snmpbulkwalk` 的 `OID = TYPE: value` 文本。 */
func parseWalk(text: String): Array<WalkEntry> {
    let entries = ArrayList<WalkEntry>()
    for (raw in text.split("\n")) {
        let line = raw.trimAscii()
        if (line.isEmpty()) {
            continue
        }
        let separator = match (line.indexOf(" = ")) {
            case Some(index) => index
            case None => continue
        }
        let oid = trimLeadingDots(line[0..separator].trimAscii())
        let rest = line[separator + 3..].trimAscii()
        if (oid.isEmpty() || rest.isEmpty()) {
            continue
        }
        let value = match (rest.indexOf(": ")) {
            case Some(index) => unquote(rest[index + 2..].trimAscii())
            case None => unquote(rest)
        }
        entries.add(WalkEntry(oid, value))
    }
    entries.toArray()
}

/** IF-MIB walk → 端口列表；非 ifDescr 子树的行忽略。 */
func parseIfMib(text: String): Array<IfPort> {
    let prefix = IF_MIB_WALK_OID + "."
    let ports = ArrayList<IfPort>()
    for (entry in parseWalk(text)) {
        if (!entry.oid.startsWith(prefix)) {
            continue
        }
        let suffix = entry.oid[prefix.size..]
        match (Int64.tryParse(suffix)) {
            case Some(index) => ports.add(IfPort(index, entry.value))
            case None => ()
        }
    }
    ports.toArray()
}

func trimLeadingDots(value: String): String {
    var result = value
    while (result.startsWith(".")) {
        result = result[1..]
    }
    result
}

func unquote(value: String): String {
    let text = value.trimAscii()
    if (text.size >= 2 && text.startsWith("\"") && text.endsWith("\"")) {
        return text[1..text.size - 1]
    }
    text
}
