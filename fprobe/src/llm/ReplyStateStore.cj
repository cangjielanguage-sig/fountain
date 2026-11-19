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
package fountain::fprobe.llm

import std.collection.ArrayList
import fountain::f_data.*
import fountain::f_io.*

/**
 * 已处理回复 id 的持久化集合（spec「回复去重」）。
 *
 * 文件是 JSON 字符串数组，按处理顺序保存；只保留最近 `capacity` 条。文件损坏
 * 时记录 WARN 并以空集合启动，不阻止进程启动。
 */
public class ReplyStateStore {
    private let path: Path
    private let capacity: Int64
    private let logWarning: (String) -> Unit
    private let ids = ArrayList<String>()

    public init(path: String, capacity!: Int64 = 1000,
        logWarning!: (String) -> Unit = {message => eprintln(message)}) {
        this.path = Path(path)
        this.capacity = capacity
        this.logWarning = logWarning
        load()
    }

    public func isHandled(id: String): Bool {
        ids.contains(id)
    }

    public func size(): Int64 {
        ids.size
    }

    /** 记录已处理 id 并落盘；重复 id 不会重复写入。 */
    public func markHandled(id: String): Unit {
        if (id.isEmpty() || ids.contains(id)) {
            return
        }
        ids.add(id)
        trim()
        persist()
    }

    private func load(): Unit {
        if (!exists(path)) {
            return
        }
        try {
            let text = String.fromUtf8(File.readFrom(path))
            match (JsonValue.fromStr(text)) {
                case array: JsonArray =>
                    let loaded = ArrayList<String>()
                    for (item in array) {
                        match (item) {
                            case value: JsonString => loaded.add(value.value)
                            case _ => throw Exception("回复状态文件包含非字符串项")
                        }
                    }
                    for (id in loaded) {
                        ids.add(id)
                    }
                    trim()
                case _ => throw Exception("回复状态文件根节点不是数组")
            }
        } catch (e: Exception) {
            logWarning('回复状态文件损坏，按空集合启动: ${path} (${e.message})')
            ids.clear()
        } catch (e: Error) {
            logWarning('回复状态文件损坏，按空集合启动: ${path} (${e.message})')
            ids.clear()
        }
    }

    private func trim(): Unit {
        while (ids.size > capacity) {
            ids.remove(at: 0)
        }
    }

    private func persist(): Unit {
        try {
            let parent = path.parent
            if (!exists(parent)) {
                Directory.create(parent, recursive: true)
            }
            let array = JsonArray()
            for (id in ids) {
                array.add(JsonString(id))
            }
            File.writeTo(path, array.toString().toArray())
        } catch (e: Exception) {
            logWarning('回复状态文件写入失败: ${path} (${e.message})')
        } catch (e: Error) {
            logWarning('回复状态文件写入失败: ${path} (${e.message})')
        }
    }
}
