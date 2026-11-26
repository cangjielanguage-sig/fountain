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
package fountain::fprobe.channel

import std.collection.HashMap
import fountain::f_probe.{AlarmMessageChannel, ProbeErrorCode, ProbeException}

/**
 * 告警渠道分发器（设计 D11 / spec「多渠道分发」）。
 *
 * 启动时校验所有启用的渠道都已注册；分发时每个渠道独立执行，单个渠道抛错
 * 只记录 ERROR，后续渠道继续收到消息。
 */
public class ChannelDispatcher {
    private let channels = HashMap<String, AlarmMessageChannel>()
    private let enabled: Array<String>
    private let logWarning: (String) -> Unit
    private let logError: (String) -> Unit

    public init(channels: Array<(String, AlarmMessageChannel)>, enabled: Array<String>,
        logWarning!: (String) -> Unit = {message => println(message)},
        logError!: (String) -> Unit = {message => eprintln(message)}) {
        for ((name, channel) in channels) {
            this.channels.add(name, channel)
        }
        for (name in enabled) {
            if (!this.channels.contains(name)) {
                throw ProbeException(ProbeErrorCode.CONFIG, '未知告警渠道 "${name}"')
            }
        }
        this.enabled = enabled
        this.logWarning = logWarning
        this.logError = logError
    }

    /** 以纯文本分发；告警同时写入日志。 */
    public func dispatch(message: String, receivers!: Array<String> = []): Unit {
        this.logWarning(message)
        for (name in enabled) {
            match (channels.get(name)) {
                case Some(channel) => sendOne(name, channel, message, receivers)
                case None => ()
            }
        }
    }

    /** 以富消息分发；不支持富消息的渠道由默认实现退化为纯文本。 */
    public func dispatchRich(message: String, html: String, attachments: Array<String>,
        receivers!: Array<String> = []): Unit {
        this.logWarning(message)
        for (name in enabled) {
            match (channels.get(name)) {
                case Some(channel) =>
                    try {
                        channel.sendRich(message, html, attachments, receivers)
                    } catch (e: Exception) {
                        this.logError('告警渠道 ${name} 发送失败: ${e.message}')
                    } catch (e: Error) {
                        this.logError('告警渠道 ${name} 发送失败: ${e.message}')
                    }
                case None => ()
            }
        }
    }

    private func sendOne(name: String, channel: AlarmMessageChannel, message: String,
        receivers: Array<String>): Unit {
        try {
            channel.send(message, receivers)
        } catch (e: Exception) {
            this.logError('告警渠道 ${name} 发送失败: ${e.message}')
        } catch (e: Error) {
            this.logError('告警渠道 ${name} 发送失败: ${e.message}')
        }
    }
}
