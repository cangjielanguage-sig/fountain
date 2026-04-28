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
package fountain::f_store

/** 可预读迭代器 — 包装 Iterator，支持 peek 查看下一个元素但不推进 */
public class PeekableIterator<T> {
    private let inner: Iterator<T>
    private var buffered: ?T

    init(inner: Iterator<T>) {
        this.inner = inner
        this.buffered = None
    }

    /** 查看下一个元素但不推进迭代器 */
    public func peek(): ?T {
        if (let Some(v) <- buffered) {
            return Some(v)
        }
        if (let Some(v) <- inner.next()) {
            buffered = Some(v)
            return Some(v)
        }
        None
    }

    /** 推进迭代器并返回当前元素 */
    public func next(): ?T {
        if (let Some(v) <- buffered) {
            buffered = None
            return Some(v)
        }
        inner.next()
    }
}
