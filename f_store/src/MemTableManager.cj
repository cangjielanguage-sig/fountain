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

/** 双缓冲管理：active 可写，immutable 刷盘中（只读快照） */
class MemTableManager {
    let active: AtomicReference<MemTable>
    let immutable: AtomicOptionReference<MemTable>
    let flushLock: Mutex

    init() {
        active = AtomicReference<MemTable>(MemTable())
        immutable = AtomicOptionReference<MemTable>()
        flushLock = Mutex()
    }

    /** 将 active 设为 immutable，创建新 active，返回旧 active（可能为 None 如果已被其他线程 swap） */
    func swapActive(): ?MemTable {
        synchronized(flushLock) {
            let old = active.load()
            // 如果 immutable 非空（上次刷盘未完成），不 swap
            if (immutable.load().isSome()) {
                return None
            }
            immutable.store(Some(old))
            active.store(MemTable())
            Some(old)
        }
    }

    func getActive(): MemTable {
        active.load()
    }

    func getImmutable(): ?MemTable {
        immutable.load()
    }

    /** 刷盘完成后清空 immutable 引用 */
    func clearImmutable(): Unit {
        immutable.store(None)
    }
}
