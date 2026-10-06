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
package fountain::f_pool

interface IKeyPool<K, V> {
    func add(key: K, value: V): Unit
    func giveBack(key: K, value: V, checker: (K, V) -> Bool, destroier: (K, V) -> Unit): Unit
    func get(key: K, checker: (K, V) -> Bool, destroier: (K, V) -> Unit): ?V
    func check(running: () -> Bool, checker: (K, V) -> Bool, taskPusher: (K) -> Unit): Unit
    /** 主动审计自愈（巡检线程每轮调用，见 .autocode/bugs/bug-archived-on-20261004.md 7.12）：返回校正的动作数。 */
    func audit(): Int64
    /**
     * 摘掉 `key` 的池：**先关闭并销毁**它的池项（逐个交给 `fn`），再把它从键表里删掉（`POOL-11`）。
     * 键不存在时是空操作。
     */
    func remove(key: K, fn: (K, V) -> Unit): Unit
    /**
     * 关闭并销毁**全部**：每个键的池都先关闭 + 销毁池项，然后清空键表。本层唯一的销毁入口
     * （原来的 `destroy` 已删除，见 `POOL-11`）。
     */
    func close(fn: (K, V) -> Unit): Unit
    prop size: Int64
    func keyedSize(key: K): Int64
    func entries(): Iterator<(K, Int64)>
    /** 键表里当前的键数（诊断 / 测试用：`POOL-11` 的观测点，`close()` 之后必须为 0）。 */
    func keyCount(): Int64
}