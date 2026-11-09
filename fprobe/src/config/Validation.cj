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
package fountain::fprobe.config

import std.collection.ArrayList
import std.convert.*
import fountain::f_config.Config

/** 读取非空配置字符串；显式空串按「未配置」处理。 */
func configString(key: String): ?String {
    match (Config.getString(key)) {
        case Some(value) =>
            let text = value.trimAscii()
            if (text.isEmpty()) {
                None<String>
            } else {
                Some(text)
            }
        case None => None<String>
    }
}

/**
 * 读取整数配置并聚合错误。
 *
 * 解析失败与范围不足都写入 `errors`，不会提前中断，保证一次启动能报出全部问题。
 */
func readInt(key: String, defaultValue: Int64, minimum: Int64, errors: ArrayList<String>): Int64 {
    match (configString(key)) {
        case Some(raw) =>
            match (Int64.tryParse(raw)) {
                case Some(value) =>
                    if (value < minimum) {
                        errors.add('${key} 必须大于等于 ${minimum}，实际为 ${value}')
                    }
                    value
                case None =>
                    errors.add('${key} 不是合法整数: "${raw}"')
                    defaultValue
            }
        case None => defaultValue
    }
}
