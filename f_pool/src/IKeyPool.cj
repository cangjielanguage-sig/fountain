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
    func destroy(destroier: (K, V) -> Unit): Unit
    prop size: Int64
    func keyedSize(key: K): Int64
    func entries(): Iterator<(K, Int64)>
}