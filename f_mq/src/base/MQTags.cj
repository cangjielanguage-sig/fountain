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
 * 消息 tags 校验。
 *
 * 规则：最多 64 个；每个 1..128 字节；不含空白与控制字符。
 * 客户端在 `publish`/`subscribe` 前本地快速失败，避免非法 tags 进入记录后
 * 变成「永远匹配不上」的静默丢消息（A19）。
 */
public class MQTags {
    public static const MAX_COUNT: Int64 = 64
    public static const MAX_LENGTH: Int64 = 128

    public static func isValid(tags: Array<String>): Bool {
        if (tags.size > MAX_COUNT) {
            return false
        }
        for (tag in tags) {
            if (tag.isEmpty() || tag.size > MAX_LENGTH) {
                return false
            }
            for (c in tag) {
                if (c <= 0x20) {
                    return false
                }
            }
        }
        true
    }
}
