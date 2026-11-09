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
package fountain::f_probe

/**
 * 告警消息渠道契约。
 *
 * 只实现 [send] / [receive] / [replyConf] 的渠道无需改动即可编译：[sendRich] 的默认
 * 实现会退化为纯文本发送，HTML 与附件被忽略。
 */
public interface AlarmMessageChannel {
    /** 发送纯文本消息给若干收件人。 */
    func send(message: String, receiver: Array<String>): Unit

    /**
     * 返回一条待处理消息的 JSON 文本；没有消息时返回空字符串。
     *
     * 格式必须是 `{"id":"...","from":"...","subject":"...","body":"..."}`。
     */
    func receive(): String

    /** 返回保存「可指挥智能体账号列表」的配置项名称，而不是配置值。 */
    func replyConf(): String

    /**
     * 发送富消息：HTML 正文与附件。
     *
     * 默认实现忽略 [html] 与 [attachments]，仅调用 [send] 发送 [message]。
     */
    func sendRich(message: String, html: String, attachments: Array<String>,
        receiver: Array<String>): Unit {
        // 默认实现不支持富消息；显式引用参数以避免 unused 警告。
        let _ = (html, attachments)
        send(message, receiver)
    }
}
