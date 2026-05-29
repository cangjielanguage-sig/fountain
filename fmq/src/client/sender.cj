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
package fountain::fmq.client

import fountain::f_protocol.default.{Message as ProtocolMessage, EncodedMessage}
import fountain::f_codec.default.DefaultCodec
import std.io.ByteBuffer

/**
 * 消息发送器。
 * 封装生产消息的协议细节。
 */
public class Sender {
    private let client: Client<ProtocolMessage, EncodedMessage, ProtocolMessage, MqBody, MessageID>

    public init(client: Client<ProtocolMessage, EncodedMessage, ProtocolMessage, MqBody, MessageID>) {
        this.client = client
    }

    /**
     * 生产单条消息。
     * 编码 topic + labels + payload，封装为 PUBLISH 命令发送给服务端。
     */
    public func produce(topic: String, labels: ArrayList<String>, data: Array<Byte>): ProduceResult {
        let bodyBytes = ProduceCodec.encode(topic, labels, data)
        let body = MqBody("produce", bodyBytes)
        let req = ProtocolMessage(Command.PUBLISH(0), MessageID(), body.toData())

        let resp = client.transfer(req.id, req, Duration.second * 10)
        if (let Some(_) <- resp) {
            ProduceResult(messageId: req.id)
        } else {
            ProduceResult()
        }
    }

    /**
     * 批量生产消息。
     * 合并为单次 PUBLISH 命令，bodyType="batch_produce"。
     */
    public func produceBatch(topic: String, messages: ArrayList<(ArrayList<String>, Array<Byte>)>): ArrayList<ProduceResult> {
        // 编码所有消息
        let buf = ByteBuffer()
        let enc = DefaultCodec()
            .encode(messages.size)
        for ((labels, data) in messages) {
            enc.encode(topic).encode(labels.size)
            for (l in labels) { enc.encode(l) }
            enc.encode(data)
        }
        enc.finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let raw = extractBytes(buf)

        let body = MqBody("batch_produce", raw)
        let req = ProtocolMessage(Command.PUBLISH(0), MessageID(), body.toData())
        let resp = client.transfer(req.id, req, Duration.second * 30)

        // 服务端当前协议不返回逐条 messageId，用请求 ID 作为引用
        let results = ArrayList<ProduceResult>()
        if (resp.isSome()) {
            for (_ in 0..messages.size) {
                results.add(ProduceResult(messageId: req.id))
            }
        } else {
            for (_ in 0..messages.size) {
                results.add(ProduceResult())
            }
        }
        results
    }
}
