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

/** 原子 pair：同时持有 active 和 immutable */
class MemTablePair {
    let active: MemTable
    let immutable: ?MemTable
    init(active: MemTable, immutable: ?MemTable) {
        this.active = active
        this.immutable = immutable
    }
}

/** 双缓冲管理：active 可写，immutable 刷盘中（只读快照）
 *
 *  无锁设计：active + immutable 合并为 MemTablePair，由单一
 *  AtomicReference 保护。swap = copy + CAS，get 原子加载快照。
 */
class MemTableManager {
    let state: AtomicReference<MemTablePair>

    init() {
        state = AtomicReference<MemTablePair>(MemTablePair(MemTable(), None))
    }

    /** 将 active 设为 immutable，创建新 active，返回旧 active（可能为 None 如果已被其他线程 swap） */
    func swapActive(): ?MemTable {
        while (true) {
            let oldState = state.load()
            // 如果 immutable 非空（上次刷盘未完成），不 swap
            if (oldState.immutable.isSome()) {
                return None
            }
            let newState = MemTablePair(MemTable(), Some(oldState.active))
            if (state.compareAndSwap(oldState, newState)) {
                return Some(oldState.active)
            }
        }
        None
    }

    func getActive(): MemTable {
        state.load().active
    }

    func getImmutable(): ?MemTable {
        state.load().immutable
    }

    /** 刷盘完成后清空 immutable 引用 */
    func clearImmutable(): Unit {
        while (true) {
            let oldState = state.load()
            let newState = MemTablePair(oldState.active, None)
            if (state.compareAndSwap(oldState, newState)) {
                break
            }
        }
    }
}
