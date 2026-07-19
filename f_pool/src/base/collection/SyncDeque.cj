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
protected package fountain::f_pool.base.collection

import std.sync.{Mutex, AtomicInt64}
import std.ref.*

protected interface Deque<T> {
    func insertHead(value: T): Unit
    func insertTail(value: T): Unit
    func prepend(value: T, checker: (T) -> Bool, destroier: (T) -> Unit): Unit
    func append(value: T, checker: (T) -> Bool, destroier: (T) -> Unit): Unit
    func remove(checker: (T) -> Bool, destroier: (T) -> Unit): ?T
    func check(running: () -> Bool, checker: (T) -> Bool, taskPusher: () -> Unit): Int64
    prop size: Int64
}
protected class SyncDeque<T> <: Deque<T> {
    private let head = HeadNode<T>(Mutex())
    private var s = AtomicInt64(0)
    public func insertHead(value: T): Unit {
        head.insertNext(value)
        s.fetchAdd(1)
    }
    public func insertTail(value: T): Unit {
        head.tail.insertPrev(value)
        s.fetchAdd(1)
    }
    public func prepend(value: T, checker: (T) -> Bool, destroier: (T) -> Unit): Unit {
        if(checker(value)){
            head.insertNext(value)
        }else{
            destroier(value)
            s.fetchSub(1)
        }
    }
    public func append(value: T, checker: (T) -> Bool, destroier: (T) -> Unit): Unit {
        if(checker(value)){
            head.tail.insertPrev(value)
        }else{
            destroier(value)
            s.fetchSub(1)
        }
    }
    public func remove(checker: (T) -> Bool, destroier: (T) -> Unit): ?T {
        while(let Some(x) <- head.nextForGet()){
            if(checker(x)){
                return x
            }else{
                destroier(x)
                s.fetchSub(1)
            }
        }
        None
    }
    public func check(running: () -> Bool, checker: (T) -> Bool, taskPusher: () -> Unit): Int64 {
        var rm = 0
        var node: ?Node<T> = head.tail.prevForChecking()
        while(running() && let Some(n: ValueNode<T>) <- node){
            node = n.prevForChecking()
            if(!n.check(checker)){
                s.fetchSub(1)
                taskPusher()
                rm++
            }
            sleep(Duration.Zero)
        }
        rm
    }
    public prop size: Int64 {
        get(){
            s.load()
        }
    }
}
protected struct WeakSyncDeque<T> <: Deque<T> {
    private let q = SyncDeque<WeakRef<Box<T>>>()
    private func ref(value: T): WeakRef<Box<T>>{
        WeakRef<Box<T>>(Box<T>(value), DEFERRED)
    }
    public func insertHead(value: T): Unit {
        q.insertHead(ref(value))
    }
    public func insertTail(value: T): Unit {
        q.insertTail(ref(value))
    }
    private func refChecker(checker: (T) -> Bool){
        {ref: WeakRef<Box<T>> => 
            if(let Some(x) <- ref.value){
                checker(x.value)
            }else{
                false
            }
        }
    }
    private func refDestroier(destroier: (T) -> Unit){
        {ref: WeakRef<Box<T>> => 
            if(let Some(x) <- ref.value){
                destroier(x.value)
            }
        }
    }
    public func prepend(value: T, checker: (T) -> Bool, destroier: (T) -> Unit): Unit {
        q.prepend(ref(value), refChecker(checker), refDestroier(destroier))
    }
    public func append(value: T, checker: (T) -> Bool, destroier: (T) -> Unit): Unit {
        q.append(ref(value), refChecker(checker), refDestroier(destroier))
    }
    public func remove(checker: (T) -> Bool, destroier: (T) -> Unit): ?T {
        if (let Some(ref: WeakRef<Box<T>>) <- q.remove(refChecker(checker), refDestroier(destroier))) {
            return ref.value?.value
        }
        return None
    }
    public func check(running: () -> Bool, checker: (T) -> Bool, taskPusher: () -> Unit): Int64 {
        q.check(running, {ref => 
            if (let Some(value) <- ref.value) {
                checker(value.value)
            }else{
                false
            }
        }, taskPusher)
    }
    public prop size: Int64 {
        get(){
            q.size
        }
    }
}