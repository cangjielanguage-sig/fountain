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
package fountain::f_email.transport

/**
 * 协议跟踪。
 *
 * 只拿得到**已脱敏**的内容：`AUTH` / `PASS` / `LOGIN` 行的参数一律替换为 `<redacted>`；
 * 凭据交互期间由协议层显式置"敏感模式"，此时整行都写成 `<redacted>`。
 * 正文不走 [onLine]，只在 [onBytes] 报告字节数——正文可能是任意二进制，按行回调既慢又危险。
 *
 * `direction` 用 `r'C'`（客户端→服务器）与 `r'S'`（服务器→客户端）。
 */
public interface MailTrace {
    func onLine(direction: Rune, line: String): Unit
    func onBytes(direction: Rune, count: Int64): Unit
}

/**
 * 关键字脱敏。
 *
 * 保守做法：只要行首命令属于凭据类，参数全部丢弃。`AUTH` 后可能跟机制名与 base64，
 * 两者都可能用于离线爆破，所以一并丢弃。
 */
internal func redactLine(line: String): String {
    let parts = line.trimAsciiStart().split(" ")
    if (parts.size == 0) {
        return line
    }
    let command = parts[0].toAsciiUpper()
    if (command == "AUTH" && parts.size >= 2) {
        // 保留机制名（调用方需要知道用的是哪种机制），凭据与 base64 一律丢弃。
        return "${parts[0]} ${parts[1]} <redacted>"
    }
    if ((command == "PASS" || command == "LOGIN") && parts.size >= 2) {
        return "${parts[0]} <redacted>"
    }
    // 单独的 AUTH / PASS / LOGIN（无参数）不需要脱敏。
    line
}
