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
package fountain::f_email.smtp

import std.collection.ArrayList

/**
 * `EHLO` 能力表。
 *
 * `HELO` 回退后能力表为空——这是刻意的：不支持 `EHLO` 的服务器基本也不可能支持
 * `STARTTLS` / `AUTH` / `SIZE`，此时若配置要求加密或认证，`build()` 直接失败。
 */
public class SmtpCapabilities {
    private let entries = ArrayList<(String, String)>()

    public init() {}

    public func add(name: String, value: String): Unit {
        entries.add((name.toAsciiUpper(), value))
    }

    public func has(name: String): Bool {
        let key = name.toAsciiUpper()
        for ((name0, _) in entries) {
            if (name0 == key) {
                return true
            }
        }
        false
    }

    public func value(name: String): ?String {
        let key = name.toAsciiUpper()
        for ((name0, value) in entries) {
            if (name0 == key) {
                return Some(value)
            }
        }
        None<String>
    }

    public prop size: ?Int64 {
        get() {
            if (let Some(raw) <- value("SIZE")) {
                let trimmed = raw.trimAscii()
                if (trimmed.size == 0) {
                    return Some(0)
                }
                var n: Int64 = 0
                for (b in trimmed.toArray()) {
                    if (b < b'0' || b > b'9') {
                        return None<Int64>
                    }
                    n = n * 10 + Int64(b - b'0')
                }
                return Some(n)
            }
            None<Int64>
        }
    }

    public prop authMechanisms: Array<String> {
        get() {
            if (let Some(raw) <- value("AUTH")) {
                return raw.trimAscii().toAsciiUpper().split(" ", removeEmpty: true)
            }
            Array<String>()
        }
    }

    public prop supports8BitMime: Bool {
        get() {
            has("8BITMIME")
        }
    }

    public prop supportsSmtpUtf8: Bool {
        get() {
            has("SMTPUTF8")
        }
    }

    public prop supportsPipelining: Bool {
        get() {
            has("PIPELINING")
        }
    }

    public prop supportsStartTls: Bool {
        get() {
            has("STARTTLS")
        }
    }

    public prop supportsDsn: Bool {
        get() {
            has("DSN")
        }
    }

    public prop supportsEnhancedStatusCodes: Bool {
        get() {
            has("ENHANCEDSTATUSCODES")
        }
    }

    /** 从 `EHLO` 的多行回复解析；第一行是服务器问候语，跳过。 */
    public static func fromEhlo(lines: Array<String>): SmtpCapabilities {
        let capabilities = SmtpCapabilities()
        var first = true
        for (line in lines) {
            if (first) {
                first = false
                continue
            }
            let trimmed = line.trimAscii()
            if (trimmed.size == 0) {
                continue
            }
            let space = trimmed.indexOf(" ") ?? -1
            if (space < 0) {
                capabilities.add(trimmed, "")
            } else {
                capabilities.add(trimmed[0..space], trimmed[(space + 1)..].trimAscii())
            }
        }
        capabilities
    }
}
