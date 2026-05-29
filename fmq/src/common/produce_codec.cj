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
package fountain::fmq.common

import std.io.ByteBuffer

/**
 * 生产请求编解码工具。
 * 消息体格式（DefaultCodec 顺序编码）：
 *   topic(String) + labelsCount(Int64) + label1(String) + ... + payload(Array<Byte>)
 */
public class ProduceCodec {
    private static let log = LoggerFactory.getLogger<ProduceCodec>()

    /**
     * 编码生产消息为 Array<Byte>。
     */
    public static func encode(topic: String, labels: ArrayList<String>, payload: Array<Byte>): Array<Byte> {
        let buf = ByteBuffer()
        let enc = DefaultCodec()
            .encode(topic)
            .encode(labels.size)
        for (l in labels) {
            enc.encode(l)
        }
        enc.encode(payload)
            .finish()
            .copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)

        extractBytes(buf)
    }

    /**
     * 解码生产消息。
     * 返回 (topic, labels, payload) 元组。
     */
    public static func decode(data: Array<Byte>): ?(String, ArrayList<String>, Array<Byte>) {
        try {
            let buf = ByteBuffer(data)
            let dec = DefaultCodec()
            if (let Some(topic) <- dec.decode<String>(buf)) {
                if (let Some(count) <- dec.decode<Int64>(buf)) {
                    // P2: 限制 labels 数量防止恶意/损坏消息导致 OOM
                    if (count < 0 || count > 256) {
                        log.warn{"ProduceCodec.decode: label count ${count} out of range"}
                        return None
                    }
                    let labels = ArrayList<String>()
                    for (_ in 0..count) {
                        if (let Some(l) <- dec.decode<String>(buf)) {
                            labels.add(l)
                        } else {
                            return None
                        }
                    }
                    if (let Some(payload) <- dec.decode<Array<Byte>>(buf)) {
                        Some((topic, labels, payload))
                    } else { None }
                } else { None }
            } else { None }
        } catch (e: Exception) {
            log.warn{"ProduceCodec.decode failed: ${e.message}"}
            None
        }
    }
}
