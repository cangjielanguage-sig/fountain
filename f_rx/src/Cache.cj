/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    rxcj is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.  
*/
package f_rx

public interface Cache<T> <: Iterable<T> {
    func new(): Cache<T>
    func set(value: T): Unit
}
public class EmptyCache<T> <: Cache<T> {
    public func new(): Cache<T> {
        this
    }
    public func iterator(): Iterator<T> {
        EmptyIterator<T>.INSTANCE()
    }
    public func set(value: T): Unit{

    }
}
public class QueuedCache<T> <: Cache<T> {
    private let queue: LinkedList<T>
    private let lock = Mutex()
    public QueuedCache(private let capacity: Int64) {
        queue = LinkedList<T>()
    }
    public func new(): Cache<T> {
        QueuedCache<T>(capacity)
    }
    public func iterator(): Iterator<T> {
        CacheIterator<T>(queue.iterator(), lock, capacity)
    }
    public func set(value: T): Unit{
        synchronized(lock) {
            while(queue.size >= capacity) {
                queue.removeFirst()
            }
            queue.addLast(value)
        }
    }
}
class CacheIterator<T> <: Iterator<T> {
    CacheIterator(private let itr: Iterator<T>, private let lock: Mutex, private let size: Int64){}
    private var consumed = 0
    public func next(): ?T {
        synchronized(lock) {
            if(consumed >= size) {
                return None<T>
            }
            consumed++
            itr.next()
        }
    }
}