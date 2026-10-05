/*
Copyright (c) 2025 WuJingrun（吴京润）

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
package fountain::f_orm.base

import fountain::f_regex.*

public class Condition {
    private init() {}
    private static let _delimiter = ThreadLocal<String>()
    mut static prop delimiter: String {
        get() {
            _delimiter.get() ?? ''
        }
        set(value) {
            _delimiter.set(value)
        }
    }
    // bug.md §2.12（ORM-5）：内部只用三种 (prefix, suffix) 组合（SET/WHERE 与 LoopCondition 默认），
    // 预编译为常量；模式文本与原先每次插值出的完全一致（含 IgnoreCase），语义不变
    private static let TRIM_AND_OR = Regex(#"^\s*(and|or)\s*|\s*(and|or)\s*$"#, [IgnoreCase])
    private static let TRIM_COMMA = Regex(#"^\s*(,)\s*|\s*(,)\s*$"#, [IgnoreCase])
    private static let TRIM_SPACES = Regex(#"^\s*()\s*|\s*()\s*$"#, [IgnoreCase])
    public static func loop<I, T>(values: I, executor: SqlExecutor): LoopCondition<I, T> where I <: Iterable<T> {
        LoopCondition<I, T>(values, executor)
    }

    public static func SET(partial: () -> String): String {
        try {
            delimiter = ','
            let partial = trim(prefix: ',', suffix: ',', partial: partial)
            if (partial.isEmpty()) {
                ''
            } else {
                ' SET ${partial} '
            }
        } finally {
            delimiter = ''
        }
    }

    public static func WHERE(partial: () -> String): String {
        WHERE('', partial)
    }
    public static func WHERE(delimiter: String, partial: () -> String): String {
        try {
            Condition.delimiter = delimiter
            let partial = trim(prefix: 'and|or', suffix: 'and|or', partial: partial)
            if (partial.isEmpty()) {
                ''
            } else {
                ' WHERE ${partial} '
            }
        } finally {
            Condition.delimiter = ''
        }
    }
    public static func trim(prefix!: String = '', suffix!: String = '', partial!: () -> String): String {
        // bug.md §2.12（ORM-5）：内部组合走预编译常量；自定义 prefix/suffix 仍按原样动态构造
        let pattern = if (prefix == 'and|or' && suffix == 'and|or') {
            TRIM_AND_OR
        } else if (prefix == ',' && suffix == ',') {
            TRIM_COMMA
        } else if (prefix.isEmpty() && suffix.isEmpty()) {
            TRIM_SPACES
        } else {
            '^\\s*(${prefix})\\s*|\\s*(${suffix})\\s*$'.regex(flags: [IgnoreCase])
        }
        pattern.replaceAll(partial(), " ")
    }
}
