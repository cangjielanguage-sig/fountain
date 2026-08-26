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
package fountain::f_concurrent

import std.sync.{Mutex, Condition}
import std.time.{DateTime, MonoTime}
import fountain::f_collection.PriorityQueue

public interface Delayed<T> <: Comparable<T> where T <: Delayed<T> {
    prop delayedAt: DateTime

    func compare(other: T): Ordering {
        delayedAt.compare(other.delayedAt)
    }
}

public class DelayQueue<T> <: Queue<T> where T <: Delayed<T> {
    private let mutex = Mutex()
    private let delayedCond = synchronized(mutex){mutex.condition()}
    private let remCond = synchronized(mutex){mutex.condition()}
    private let queue = PriorityQueue<T>({a, b => a.compare(b)})
    
    public func add(element: T): Unit {
        synchronized(mutex){
            queue.add(element)
            remCond.notifyAll()
        }
    }
    public func peek(): ?T {
        return queue.peek()
    }
    public func remove(): ?T {
        synchronized(mutex){
            while(true){
                if(let Some(v) <- queue.remove()){
                    let now = DateTime.now()
                    if(v.delayedAt <= now){
                        return v
                    }
                    delayedCond.wait(timeout: v.delayedAt - now)
                    return v
                }else{
                    remCond.wait()
                }
            }
            None<T>
        }
    }
    public func remove(timeout: Duration): ?T {
        let start = MonoTime.now()
        synchronized(mutex){
            while(true){
                if(let Some(v) <- queue.remove()){
                    if(v.delayedAt <= DateTime.now()){
                        return v
                    }
                    delayedCond.wait(timeout: v.delayedAt - DateTime.now())
                    return v
                }else if(let consumed <- MonoTime.now() - start && (consumed >= timeout || !remCond.wait(timeout: timeout - consumed))){
                    return None<T>
                }
            }
            None<T>
        }
    }
    public prop size: Int64 {
        get(){
            return queue.size
        }
    }
    public func isEmpty(): Bool {
        return queue.isEmpty()
    }
    public func iterator(): Iterator<T> {
        DelayQueueIterator<T>(mutex, queue.iterator())
    }
}

public class DelayQueueIterator<T> <: Iterator<T> {
    DelayQueueIterator(
        private let mutex: Mutex,
        private let itr: Iterator<T>
    ){}
    public func next(): ?T {
        synchronized(mutex){
            return itr.next()
        }
    }
}