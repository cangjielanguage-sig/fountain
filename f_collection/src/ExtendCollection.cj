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
package f_collection

import std.collection.{Set, ArrayList, MapEntryView, HashMapIterator}
import std.collection.concurrent.ConcurrentHashMap

public interface ExtendCollection<T, C> where T <: Equatable<T>, C <: Collection<T> {
    func retain(set: C): Unit
}

public interface ExtendList<T> <: ExtendCollection<T, Set<T>> where T <: Equatable<T> {
    func remove(set: Set<T>): Unit
}

extend<T> ArrayList<T> <: ExtendList<T> where T <: Equatable<T> {
    public func retain(set: Set<T>): Unit {
        batchRemove(set, true)
    }
    public func remove(set: Set<T>): Unit {
        batchRemove(set, false)
    }
    private func batchRemove(set: Set<T>, complement: Bool): Unit {
        let s = size
        var w = 0
        for (r in 0..s where set.contains(this[r]) == complement) {
            this[w] = this[r]
            w++
        }
        if (w == s) {
            return
        }
        for (i in s - 1..=w : -1) {
            remove(at: i)
        }
    }
}

public interface ExtendMap<K, V> <: ExtendCollection<K, Collection<K>> where K <: Equatable<K> {
    func remove(k: K): ?V
    func contains(k: K): Bool
    func retain(c: Collection<K>): Unit {
        for (k in c where !contains(k)) {
            remove(k)
        }
    }
    func entryView(key: K, fn: (K, ?V) -> ?V): ?V
    func computeIfAbsent(key: K, fn: () -> V): V {
        entryView(key){k, optv =>
            if(let Some(_) <- optv){
                optv
            }else{
                fn()
            }
        }.getOrThrow()
    }
    func computeIfPresent(key: K, fn: () -> V): ?V {
        entryView(key){k, optv => 
            if(let Some(_) <- optv){
                fn()
            }else{
                None<V>
            }
        }
    }
    func addIfAbsent(key: K, fn: () -> V): V
    func addIfPreset(key: K, fn: () -> V): ?V
    func removeIf(key: K, predicate: (V) -> Bool): ?V
    func removeIf(predicate: (K, V) -> Bool): Unit
}

public interface ExtendNonConcurrentMap<K, V> <: ExtendMap<K, V> where K <: Equatable<K> {
    func entryView(key: K): MapEntryView<K, V>
    func entryView(key: K, fn: (K, ?V) -> ?V): ?V {
        let entry = this.entryView(key)
        let value = fn(entry.key, entry.value)
        entry.value = value
        value
    }
    func addIfAbsent(key: K, fn: () -> V): V {
        let view = entryView(key)
        if (let Some(v) <- view.value) {
            v
        } else {
            let v = fn()
            view.value = v
            v
        }
    }
    func addIfPreset(key: K, fn: () -> V): ?V {
        let view = entryView(key)
        if (let Some(_) <- view.value) {
            let v = fn()
            view.value = v
            v
        } else {
            None<V>
        }
    }
    func removeIf(key: K, predicate: (V) -> Bool): ?V {
        let view = entryView(key)
        if (let Some(v) <- view.value && predicate(v)) {
            view.value = None<V>
            v
        } else {
            None<V>
        }
    }
}

extend<K, V> HashMap<K, V> <: ExtendNonConcurrentMap<K, V> where K <: Hashable & Equatable<K> {}

extend<K, V> TreeMap<K, V> <: ExtendNonConcurrentMap<K, V> where K <: Comparable<K> {}

extend<K, V> LinkedHashMap<K, V> <: ExtendNonConcurrentMap<K, V> where K <: Hashable & Equatable<K> {}

extend<K, V> ConcurrentHashMap<K, V> <: ExtendMap<K, V> where K <: Hashable & Equatable<K> {
    public func entryView(key: K, fn: (K, ?V) -> ?V): ?V {
        this.entryView(key) {
            entry => entry.value = fn(entry.key, entry.value)
        }
    }
    public func addIfAbsent(key: K, fn: () -> V): V {
        entryView(key) {
            view => if (view.value.isNone()) {
                view.value = fn()
            }
        }.getOrThrow()
    }
    public func addIfPreset(key: K, fn: () -> V): ?V {
        entryView(key) {
            view => if (view.value.isSome()) {
                view.value = fn()
            }
        }
    }
    public func removeIf(key: K, predicate: (V) -> Bool): ?V {
        entryView(key) {
            view => if (let Some(v) <- view.value && predicate(v)) {
                view.value = None<V>
                v
            } else {
                None<V>
            }
        }
    }
    public func removeIf(predicate: (K, V) -> Bool): Unit {
        for ((k, v) in this where predicate(k, v)) {
            remove(k)
        }
    }
}
