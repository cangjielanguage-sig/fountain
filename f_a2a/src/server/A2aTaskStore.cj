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
package fountain::f_a2a.server

import std.collection.*
import std.sync.*

import fountain::f_a2a.model.*

/** 任务存储：默认内存实现，需要跨重启保留时换成自己的实现 */
public interface A2aTaskStore {
    func save(task: A2aTask): Unit
    func get(id: String): ?A2aTask
    func list(limit: Int64): ArrayList<A2aTask>
}

/**
 * 内存实现：`Mutex` 保护，读出的都是**副本**。
 *
 * 返回副本的理由：服务端与调用方共享同一批可变字段（状态、产物），
 * 返回引用会让「取消后再读」这类并发路径读到中间态。
 */
public class InMemoryA2aTaskStore <: A2aTaskStore {
    private let mutex = Mutex()
    private let tasks = HashMap<String, A2aTask>()

    public init() {
    }

    public func save(task: A2aTask): Unit {
        synchronized(mutex) {
            tasks[task.id] = A2aJson.copyOf(task)
        }
    }

    public func get(id: String): ?A2aTask {
        synchronized(mutex) {
            match (tasks.get(id)) {
                case Some(task) => Some(A2aJson.copyOf(task))
                case None => None
            }
        }
    }

    public func list(limit: Int64): ArrayList<A2aTask> {
        let result = ArrayList<A2aTask>()
        synchronized(mutex) {
            for ((_, task) in tasks) {
                if (limit > 0 && Int64(result.size) >= limit) {
                    break
                }
                result.add(A2aJson.copyOf(task))
            }
        }
        result
    }

    public func count(): Int64 {
        synchronized(mutex) {
            Int64(tasks.size)
        }
    }
}
