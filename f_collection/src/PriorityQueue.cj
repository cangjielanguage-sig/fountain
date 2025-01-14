/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_collection

import std.collection.ArrayList
import f_base.*
import f_exception.OverSizeException

class PriorityQueueIterator<T> <: Iterator<T> {
    private var idx = 0
    PriorityQueueIterator(private let itr: Iterator<Option<T>>, private let max_: Int64) {}

    public func next(): Option<T> {
        for (current in itr) {
            if (idx >= max_ || current.isNone()) {
                break
            }
            idx++
            return current.getOrThrow()
        }
        PriorityQueue<T>.EMPTY_VALUE
    }
}
public class PriorityQueue<T> <: Queue<T> & Iterable<T> & Collection<T> & Growable {
    static const EMPTY_VALUE = None<T>

    /**
     * current size
     */
    private var currentSize: Int64 = 0

    /**
     * datas
     */
    private var queue: Array<Option<T>>

    public PriorityQueue(
        private let comparator: (T, T) -> Ordering,
        private var capacity!: Int64 = 0,
        private let overSizePolicy!: OverSizePolicy<PriorityQueue<T>> = DiscardOverSizePolicy<PriorityQueue<T>>()
    ) {
        queue = Array<Option<T>>(
            if (capacity == 0) {
                16
            } else {
                capacity
            },
            repeat: PriorityQueue<T>.EMPTY_VALUE
        )
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
        PriorityQueue<T>.create(Comparator<T>.create<T>(), capacity: capacity, overSizePolicy: overSizePolicy)
    }
    public static func createReverse<T>(
        capacity!: Int64 = 0,
        overSizePolicy!: OverSizePolicy<PriorityQueue<T>> = DiscardOverSizePolicy<PriorityQueue<T>>()
    ) where T <: Comparable<T> {
        PriorityQueue<T>.create(Comparator<T>.create<T>().reverse(), capacity: capacity, overSizePolicy: overSizePolicy)
    }
    public static func create(
        comparator: Comparator<T>,
        capacity!: Int64 = 0,
        overSizePolicy!: OverSizePolicy<PriorityQueue<T>> = DiscardOverSizePolicy<PriorityQueue<T>>()
    ) {
        PriorityQueue<T>(comparator.comparator, capacity: capacity, overSizePolicy: overSizePolicy)
    }

    /**
     * current size
     */
    public prop size: Int64 {
        get() {
            currentSize
        }
    }
    public func isEmpty(): Bool {
        size == 0
    }

    /**
     * add an element
     */
    public func add(x: T): Unit {
        if (capacity > 0 && size >= capacity) {
            overSizePolicy.reject(this) {doOffer(x)}
        } else {
            doOffer(x)
        }
    }
    private func doOffer(x: T): Bool {
        if (currentSize == 0) {
            queue[currentSize] = x
            currentSize++
            true
        } else if (!isFull()) {
            adjustUp(currentSize, x)
            currentSize++
            true
        } else if (capacity <= 0) {
            grow()
            doOffer(x)
        } else {
            false
        }
    }
    public func grow(): Unit {
        let q = queue
        queue = Array<Option<T>>(currentSize * 2){i => 
            if(i < currentSize){
                q[i]
            }else{
                PriorityQueue<T>.EMPTY_VALUE
            }
        }
    }

    /**
     * offer all elements in values to current queue
     */
    public func add(all!: Collection<T>) {
        for (value in all) {
            add(value)
        }
    }

    /**
     * is current heap full? if capacity is not greater than 0, heap is infinity
     */
    private func isFull() {
        return currentSize >= queue.size
    }

    /**
     * get element on top
     */
    public func peek(): Option<T> {
        if (currentSize > 0) {
            queue[0]
        } else {
            PriorityQueue<T>.EMPTY_VALUE
        }
    }

    /**
     * get and remove element on top
     */
    public func remove(): Option<T> {
        let cur = peek()
        if (cur.isNone()) {
            return PriorityQueue<T>.EMPTY_VALUE
        }
        currentSize--
        let temp = queue[currentSize]
        queue[currentSize] = PriorityQueue<T>.EMPTY_VALUE
        if (currentSize > 0) {
            adjustDown(0, temp.getOrThrow())
        }
        return cur
    }

    /**
     * 从下往上调整
     */
    private func adjustUp(k: Int64, value: T) {
        var i = k
        while (i > 0) {
            let parent = (i - 1) >> 1 //父
            let current = queue[parent].getOrThrow()
            if (comparator(current, value) == LT) {
                break
            }
            queue[i] = queue[parent]
            i = parent
        }
        queue[i] = value
    }

    /**
     * 从上往下调整
     */
    private func adjustDown(k: Int64, value: T) { //把要插入的值传入进来，节省每转旋转交换的开销
        var i = k
        let progenitor = currentSize >> 1 //最禄的父,也是adjustDown的终点，再往下就是空转了
        while (i < progenitor) {
            var leftChild = (i << 1) + 1 //左子
            var leftChildVal = queue[leftChild].getOrThrow()
            let rightChild = leftChild + 1 //右子
            if (rightChild < currentSize && comparator(leftChildVal, queue[rightChild].getOrThrow()) == GT) {
                leftChild = rightChild
                leftChildVal = queue[leftChild].getOrThrow()
            }
            if (comparator(leftChildVal, value) == GT) {
                break
            }
            queue[i] = leftChildVal
            i = leftChild
        }
        queue[i] = value
    }

    public func iterator(): Iterator<T> {
        let itr: Iterator<Option<T>> = queue.iterator()
        let size: Int64 = currentSize
        PriorityQueueIterator<T>(itr, size)
    }
    public func removeIf(predicate: (T) -> Bool): Unit {
        var i = 0
        let size = currentSize
        var lastIdx = size
        var toAdjust = false
        while (i < size) {
            let v = queue[i].getOrThrow()
            if (predicate(v)) {
                queue[i] = PriorityQueue<T>.EMPTY_VALUE
                if (!toAdjust) {
                    lastIdx = i
                    toAdjust = true
                }
            } else if (toAdjust) {
                queue[i] = PriorityQueue<T>.EMPTY_VALUE
                adjustUp(lastIdx, v)
                lastIdx++
            }
            i++
        }
        currentSize = lastIdx
    }
    public func toArray(): Array<T> {
        let itr = iterator()
        Array<T>(size) {
            _ => itr.next().getOrThrow()
        }
    }
}
