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
package fountain::f_email.pop3

import std.collection.ArrayList

/** `CAPA` 的一行：能力名 + 参数。 */
public struct Pop3Capability {
    public let name: String
    public let args: Array<String>

    public init(name: String, args!: Array<String> = []) {
        this.name = name
        this.args = args
    }
}

/**
 * `CAPA` 的能力表。
 *
 * 服务器回 `-ERR`（RFC 2449 之前的老服务器）时这里是**空表**而不是异常：
 * 老服务器仍然能用 `USER`/`PASS`/`RETR`，只是没有 `TOP`/`UIDL` 等扩展。
 * 需要扩展的命令届时自己判断并在能力缺失时报错。
 */
public struct Pop3Capabilities {
    public let entries: Array<Pop3Capability>

    public init(entries!: Array<Pop3Capability> = []) {
        this.entries = entries
    }

    public static func fromLines(lines: Array<String>): Pop3Capabilities {
        let entries = ArrayList<Pop3Capability>()
        for (raw in lines) {
            let trimmed = raw.trimAscii()
            if (trimmed.size == 0) {
                continue
            }
            let tokens = trimmed.split(" ", removeEmpty: true)
            if (tokens.size == 0) {
                continue
            }
            let name = tokens[0].toAsciiUpper()
            let args = ArrayList<String>()
            for (i in 1..tokens.size) {
                args.add(tokens[i])
            }
            entries.add(Pop3Capability(name, args: args.toArray()))
        }
        Pop3Capabilities(entries: entries.toArray())
    }

    public func supports(name: String): Bool {
        let wanted = name.toAsciiUpper()
        for (entry in entries) {
            if (entry.name == wanted) {
                return true
            }
        }
        false
    }

    public func args(name: String): Array<String> {
        let wanted = name.toAsciiUpper()
        for (entry in entries) {
            if (entry.name == wanted) {
                return entry.args
            }
        }
        []
    }

    public func get(name: String): ?Pop3Capability {
        let wanted = name.toAsciiUpper()
        for (entry in entries) {
            if (entry.name == wanted) {
                return Some(entry)
            }
        }
        None<Pop3Capability>
    }

    public prop size: Int64 {
        get() {
            entries.size
        }
    }

    public prop isEmpty: Bool {
        get() {
            entries.size == 0
        }
    }

    public prop supportsTop: Bool {
        get() {
            supports("TOP")
        }
    }

    public prop supportsUidl: Bool {
        get() {
            supports("UIDL")
        }
    }

    public prop supportsPipelining: Bool {
        get() {
            supports("PIPELINING")
        }
    }

    public prop supportsUser: Bool {
        get() {
            supports("USER")
        }
    }

    public prop supportsStls: Bool {
        get() {
            supports("STLS")
        }
    }

    public prop supportsRespCodes: Bool {
        get() {
            supports("RESP-CODES")
        }
    }

    /** `SASL` 行的机制列表（`AUTH` 命令的可用集合）。 */
    public prop authMechanisms: Array<String> {
        get() {
            let out = ArrayList<String>()
            for (mechanism in args("SASL")) {
                out.add(mechanism.toAsciiUpper())
            }
            out.toArray()
        }
    }

    /** `IMPLEMENTATION` 文本，仅供诊断。 */
    public prop implementation: ?String {
        get() {
            let values = args("IMPLEMENTATION")
            if (values.size == 0) {
                return None
            }
            var text = ""
            for (part in values) {
                if (text.size > 0) {
                    text = text + " "
                }
                text = text + part
            }
            Some(text)
        }
    }

    public prop expire: ?String {
        get() {
            if (let Some(entry) <- get("EXPIRE")) {
                if (entry.args.size > 0) {
                    return Some(entry.args[0])
                }
            }
            None<String>
        }
    }
}
