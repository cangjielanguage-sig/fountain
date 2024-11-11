/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.  
*/
package f_concurrent

import std.sync.ReentrantMutex
import f_base.*
import f_collection.{PriorityQueue, Queue, Growable}

public class SyncPriorityQueue<T> <: Queue<T> & Collection<T> & Growable {
    private let mutex = ReentrantMutex()
    private let queue: PriorityQueue<T>
    public init(
        comparator: (T, T) -> Ordering,
        capacity!: Int64 = 0,
        overSizePolicy!: OverSizePolicy<PriorityQueue<T>> = DiscardOverSizePolicy<PriorityQueue<T>>()
    ) {
        queue = PriorityQueue<T>(comparator, capacity: capacity, overSizePolicy: overSizePolicy)
    }
    public init(
        comparator: Comparator<T>,
        capacity!: Int64 = 0,
        overSizePolicy!: OverSizePolicy<PriorityQueue<T>> = DiscardOverSizePolicy<PriorityQueue<T>>()
    ) {
        this(comparator.comparator, capacity: capacity, overSizePolicy: overSizePolicy)
    }
    public static func create<T>(
        capacity!: Int64 = 0,
        overSizePolicy!: OverSizePolicy<PriorityQueue<T>> = DiscardOverSizePolicy<PriorityQueue<T>>()
    ) where T <: Comparable<T> {
        SyncPriorityQueue<T>.create(Comparator<T>.create<T>(), capacity: capacity, overSizePolicy: overSizePolicy)
    }
    public static func createReverse<T>(
        capacity!: Int64 = 0,
        overSizePolicy!: OverSizePolicy<PriorityQueue<T>> = DiscardOverSizePolicy<PriorityQueue<T>>()
    ) where T <: Comparable<T> {
        SyncPriorityQueue<T>.create(Comparator<T>.create<T>().reverse(), capacity: capacity, overSizePolicy: overSizePolicy)
    }
    public static func create(
        comparator: Comparator<T>,
        capacity!: Int64 = 0,
        overSizePolicy!: OverSizePolicy<PriorityQueue<T>> = DiscardOverSizePolicy<PriorityQueue<T>>()
    ) {
        SyncPriorityQueue<T>(comparator.comparator, capacity: capacity, overSizePolicy: overSizePolicy)
    }

    public prop size: Int64{
        get(){
            synchronized(mutex){
                queue.size
            }
        }
    }
    public func isEmpty(): Bool {
        synchronized(mutex){
            queue.isEmpty()
        }
    }
    public func offer(x: T): Unit {
        synchronized(mutex){
            queue.offer(x)
        }
    }
    public func grow(): Unit {
        synchronized(mutex){
            queue.grow()
        }
    }
    public func offerAll<I>(values: I) where I <: Iterable<T>{
        synchronized(mutex){
            queue.offerAll(values)
        }
    }
    public func peek(): ?T {
        synchronized(mutex){
            queue.peek()
        }
    }
    public func poll(): ?T {
        synchronized(mutex){
            queue.poll()
        }
    }
    public func iterator(): Iterator<T> {
        synchronized(mutex){
            SyncPriorityQueueIterator<T>(queue.iterator(), mutex)
        }
    }
    public func removeIf(predicate: (T) -> Bool): Unit {
        synchronized(mutex){
            queue.removeIf(predicate)
        }
    }
    public func toArray(): Array<T> {
        synchronized(mutex){
            queue.toArray()
        }
    }
}
public class SyncPriorityQueueIterator<T> <: Iterator<T> {
    public SyncPriorityQueueIterator(private let itr: Iterator<T>, 
                                     private let mutex: ReentrantMutex){}
    public func next(): ?T {
        synchronized(mutex){
            itr.next()
        }
    }
}