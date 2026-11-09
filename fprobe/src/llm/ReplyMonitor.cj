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
package fountain::fprobe.llm

import fountain::f_config.Config
import fountain::f_data.*
import fountain::f_probe.AlarmMessageChannel
import fountain::fprobe.channel.ChannelMessage

/**
 * 回复轮询（spec「回复轮询」「回复授权」「回复去重」）。
 *
 * 逐渠道 `receive()`，非空文本按 `ChannelMessage` 解析；已处理 id 直接跳过，
 * 未授权发件人通过同一渠道收到固定文案且不触发任何动作。
 */
public class ReplyMonitor {
    public static let UNAUTHORIZED_REPLY = "本账号没有权限指挥智能体"

    private let channels: Array<(String, AlarmMessageChannel)>
    private let store: ReplyStateStore
    private let onAuthorized: (ChannelMessage) -> Unit
    private let accounts: (String) -> Array<String>
    private let logWarning: (String) -> Unit
    private let logError: (String) -> Unit

    public init(channels: Array<(String, AlarmMessageChannel)>, store: ReplyStateStore,
        onAuthorized: (ChannelMessage) -> Unit,
        accounts!: (String) -> Array<String> = {key => Config.getStringArray(key)},
        logWarning!: (String) -> Unit = {message => eprintln(message)},
        logError!: (String) -> Unit = {message => eprintln(message)}) {
        this.channels = channels
        this.store = store
        this.onAuthorized = onAuthorized
        this.accounts = accounts
        this.logWarning = logWarning
        this.logError = logError
    }

    /** 轮询一轮，返回非空且格式合法的消息数（含未授权消息）。 */
    public func pollOnce(): Int64 {
        var processed = 0
        for ((name, channel) in channels) {
            let raw = channel.receive()
            if (raw.trimAscii().isEmpty()) {
                continue
            }
            let message = match (parse(raw)) {
                case Some(value) => value
                case None =>
                    logWarning('渠道 ${name} 收到非法回复: ${truncate(raw)}')
                    continue
            }
            if (store.isHandled(message.id)) {
                continue
            }

            if (!isAuthorized(channel.replyConf(), message.from)) {
                try {
                    channel.send(UNAUTHORIZED_REPLY, [message.from])
                } catch (e: Exception) {
                    logError('渠道 ${name} 回复未授权账号失败: ${e.message}')
                } catch (e: Error) {
                    logError('渠道 ${name} 回复未授权账号失败: ${e.message}')
                }
                store.markHandled(message.id)
                logWarning('渠道 ${name} 拒绝未授权发件人 ${message.from}')
                processed += 1
                continue
            }

            try {
                onAuthorized(message)
                store.markHandled(message.id)
                processed += 1
            } catch (e: Exception) {
                logError('渠道 ${name} 处理回复失败: ${e.message}')
            } catch (e: Error) {
                logError('渠道 ${name} 处理回复失败: ${e.message}')
            }
        }
        processed
    }

    private func isAuthorized(confKey: String, from: String): Bool {
        let sender = from.trimAscii()
        for (account in accounts(confKey)) {
            if (account.trimAscii() == sender) {
                return true
            }
        }
        false
    }

    private func parse(raw: String): ?ChannelMessage {
        try {
            match (JsonValue.fromStr(raw)) {
                case object: JsonObject =>
                    match (DataObject<ChannelMessage>.populate(object.toData())) {
                        case Some(message) => if (message.id.isEmpty()) {
                            None<ChannelMessage>
                        } else {
                            Some(message)
                        }
                        case None => None<ChannelMessage>
                    }
                case _ => None<ChannelMessage>
            }
        } catch (_: Exception) {
            None<ChannelMessage>
        } catch (_: Error) {
            None<ChannelMessage>
        }
    }

    private func truncate(raw: String): String {
        if (raw.size > 120) {
            raw[0..120] + "..."
        } else {
            raw
        }
    }
}
