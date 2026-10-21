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
 * 订阅组名校验：与 `MQTopic.isValid` 同级。
 *
 * 空串表示默认组，合法；非空组名长度不超过 255、不含空白与控制字符（按 Unicode 码点判定）、不含路径/转义字符
 * `'/'` `'\'` `':'` `'%'`、不以 `'.'` 开头或结尾。
 *
 * 组名会直接变成 `metas/groups/<escaped>.meta` 与 `cursors/<escaped>.cursor` 的文件名，
 * 也参与 `topic\0queue\0group` 的缓存键，因此这些字符必须挡在入口处（A05）。
 */
public class MQGroup {
    public static const MAX_LENGTH: Int64 = 255

    public static func isValid(group: String): Bool {
        if (group.isEmpty()) {
            return true
        }
        if (group.size > MAX_LENGTH) {
            return false
        }
        if (group.startsWith(".") || group.endsWith(".")) {
            return false
        }
        // 按码点判定空白/控制字符：只比 ASCII 字节会漏掉 DEL、NBSP、表意空格（R1-G12）
        if (MQChars.containsBlankOrControl(group)) {
            return false
        }
        for (c in group) {
            // '/' '\' ':' '%'：这三个都是 ASCII，按字节比较等价
            if (c == 0x2F || c == 0x5C || c == 0x3A || c == 0x25) {
                return false
            }
        }
        true
    }
}
