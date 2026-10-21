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
package fountain::f_mq.base

/**
 * 主题名校验。
 *
 * 合法主题：非空、以 `/` 开头、不以 `/` 结尾、无空段（`//`）、无 ASCII 空白字符。
 * 客户端在 publish/subscribe 前本地快速失败，服务端在注册时再校验一次（权威）。
 */
public class MQTopic {
    public static func isValid(topic: String): Bool {
        if (topic.isEmpty() || !topic.startsWith("/") || topic.endsWith("/")) {
            return false
        }
        // String 的迭代单位是字节：所有 <= 0x20 的字节都视为空白/控制字符
        for (c in topic) {
            if (c <= 0x20) {
                return false
            }
        }
        // 空段（"/a//b"）
        !topic.contains("//")
    }
}
