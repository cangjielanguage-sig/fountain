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
package fountain::f_zip

import std.collection.{HashMap, HashSet}

/**
 * 写入侧同名消解：保证产出的 ZIP 里不存在同名条目。
 *
 * - 同名**目录**（名字以 `/` 结尾）→ 合并，第二次遇到直接跳过；
 * - 同名**文件** → 第一个保留原名，后续加 `_<N>`，`N` 从 2 起；
 * - 后缀插在**最后一个非目录段的 `.` 之前**，保留扩展名。
 *
 * 名字都是 ASCII / UTF-8 字节串，下标一律按字节算，所以 `lastIndexOf` 的结果
 * 可以直接用于切片。
 */
internal class EntryNameTable {
    private let used = HashSet<String>()
    private let counter = HashMap<String, Int64>()

    /** 分配一个可用的名字（文件语义：冲突就加后缀）。 */
    public func allocate(name: String): String {
        if (used.add(name)) {
            return name
        }
        var n = counter.get(name) ?? 2
        while (true) {
            let candidate = insertSuffix(name, n)
            if (used.add(candidate)) {
                counter[name] = n + 1
                return candidate
            }
            n += 1
        }
        throw ZipException("名字分配失败：${name}")
    }

    /**
     * 目录语义：已存在就合并（返回原名，不再写第二条）。
     * 返回 `(实际名字, 是否需要写条目)`。
     */
    public func allocateDirectory(name: String): (String, Bool) {
        if (used.contains(name)) {
            return (name, false)
        }
        used.add(name)
        (name, true)
    }

    public func contains(name: String): Bool {
        used.contains(name)
    }

    public func size(): Int64 {
        used.size
    }

    /**
     * `dir/a.txt` + 2 → `dir/a_2.txt`；`a` → `a_2`；`dir.d/file` → `dir.d/file_2`；
     * `.gitignore` → `.gitignore_2`；`a.` → `a_2.`。
     */
    public func insertSuffix(name: String, n: Int64): String {
        let dot = name.lastIndexOf(".") ?? -1
        let slash = name.lastIndexOf("/") ?? -1
        // 点必须落在最后一个路径段的非首字符位置才算扩展名分隔符：
        // `.gitignore` 的点在段首（视为无扩展名），`dir.d/file` 的点在目录段里。
        if (dot <= slash + 1) {
            return "${name}_${n}"
        }
        "${name[0..dot]}_${n}${name[dot..]}"
    }
}
