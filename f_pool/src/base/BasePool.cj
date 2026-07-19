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
protected package fountain::f_pool.base

import fountain::f_pool.base.collection.{SyncDeque, WeakSyncDeque}

protected interface BasePool<T> {
    func add(value: T): Unit
    func giveBack(value: T, checker: (T) -> Bool, destroier: (T) -> Unit): Unit
    func get(checker: (T) -> Bool, destroier: (T) -> Unit): ?T
    func check(running: () -> Bool, checker: (T) -> Bool, taskPusher: () -> Unit): Int64 
    func destroy(fn: (T) -> Unit): Unit {
        check({=> true}, {v => 
            fn(v)
            false
        }){}
    }
    prop size: Int64
}
protected struct FifoPool<T> <: BasePool<T> {
    private let q = SyncDeque<T>()
    public func add(value: T): Unit {
        q.insertTail(value)
    }
    public func giveBack(value: T, checker: (T) -> Bool, destroier: (T) -> Unit): Unit {
        q.append(value, checker, destroier)
    }
    public func get(checker: (T) -> Bool, destroier: (T) -> Unit): ?T {
        return q.remove(checker, destroier)
    }
    public func check(running: () -> Bool, checker: (T) -> Bool, taskPusher: () -> Unit): Int64 {
        q.check(running, checker, taskPusher)
    }
    public prop size: Int64 {
        get(){
            return q.size
        }
    }
}
protected struct LifoPool<T> <: BasePool<T> {
    private let q = SyncDeque<T>()
    public func add(value: T): Unit {
        q.insertHead(value)
    }
    public func giveBack(value: T, checker: (T) -> Bool, destroier: (T) -> Unit): Unit {
        q.prepend(value, checker, destroier)
    }
    public func get(checker: (T) -> Bool, destroier: (T) -> Unit): ?T {
        return q.remove(checker, destroier)
    }
    public func check(running: () -> Bool, checker: (T) -> Bool, taskPusher: () -> Unit): Int64 {
        q.check(running, checker, taskPusher)
    }
    public prop size: Int64 {
        get(){
            return q.size
        }
    }
}

protected struct WeakFifoPool<T> <: BasePool<T> {
    private let q = WeakSyncDeque<T>()
    public func add(value: T): Unit {
        q.insertTail(value)
    }
    public func giveBack(value: T, checker: (T) -> Bool, destroier: (T) -> Unit): Unit {
        q.append(value, checker, destroier)
    }
    public func get(checker: (T) -> Bool, destroier: (T) -> Unit): ?T {
        q.remove(checker, destroier)
    }
    public func check(running: () -> Bool, checker: (T) -> Bool, taskPusher: () -> Unit): Int64 {
        q.check(running, checker, taskPusher)
    }
    public prop size: Int64 {
        get(){
            return q.size
        }
    }
}
protected struct WeakLifoPool<T> <: BasePool<T> {
    private let q = WeakSyncDeque<T>()
    public func add(value: T): Unit {
        q.insertHead(value)
    }
    public func giveBack(value: T, checker: (T) -> Bool, destroier: (T) -> Unit): Unit {
        q.prepend(value, checker, destroier)
    }
    public func get(checker: (T) -> Bool, destroier: (T) -> Unit): ?T {
        q.remove(checker, destroier)
    }
    public func check(running: () -> Bool, checker: (T) -> Bool, taskPusher: () -> Unit): Int64 {
        q.check(running, checker, taskPusher)
    }
    public prop size: Int64 {
        get(){
            return q.size
        }
    }
}