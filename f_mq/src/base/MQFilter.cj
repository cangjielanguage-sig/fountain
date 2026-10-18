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

import fountain::f_data.*
import fountain::f_data.path.DataPath

/**
 * 订阅过滤器：`f_data.path` 表达式的封装。
 *
 * 求值规则（规格固定）：
 * 1. 空串恒为真；
 * 2. 表达式无结果 → 假；
 * 3. 首元素为 `DataBool(b)` → `b`；
 * 4. 首元素为 `DataNone` → 假；
 * 5. 其它类型 → 真（存在即匹配）。
 *
 * 表达式非法时在 `compile` 抛 `DataException`（本地快速失败）。
 */
public class MQFilter {
    private let path_: String
    private let compiled: ?DataPath

    private init(path: String, compiled: ?DataPath) {
        this.path_ = path
        this.compiled = compiled
    }

    public static func compile(filter: String): MQFilter {
        if (filter.isEmpty()) {
            MQFilter(filter, None<DataPath>)
        } else {
            // DataPath.cache 自带编译缓存；非法表达式在这里抛 DataException
            MQFilter(filter, Some(DataPath.cache(filter)))
        }
    }

    /** 原始表达式（用于回填与日志）。 */
    public prop path: String {
        get() {
            path_
        }
    }

    public func matches(body: Data): Bool {
        match (compiled) {
            case None => true
            case Some(p) =>
                let itr = p.get(body)
                match (itr.next()) {
                    case None => false
                    case Some(v) =>
                        match (v) {
                            case b: DataBool => b.data
                            case _: DataNone => false
                            case _ => true
                        }
                }
        }
    }
}
