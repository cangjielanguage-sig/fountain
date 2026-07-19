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

import std.sync.{Mutex, AtomicInt8, AtomicOptionReference}
import fountain::f_exception.UnreachableException

const VALUE_NODE_IDLE = 0i8
const VALUE_NODE_BUSY = 1i8
const VALUE_NODE_CHECKING = 2i8
const VALUE_NODE_INVALIDATED = 3i8
protected abstract class Node<T> {
    protected open func insertPrev(value: T): ValueNode<T> {
        throw UnreachableException()
    }
    protected open func insertNext(value: T): ValueNode<T> {
        throw UnreachableException()
    }
    protected open func prevForChecking(): ?Node<T> {
        throw UnreachableException()
    }
    protected open func nextForGet(): ?T {
        throw UnreachableException()
    }
    protected open mut prop prev: Node<T>{
        get(){
            throw UnreachableException()
        }
        set(value){
            throw UnreachableException()
        }
    }
    protected open mut prop next: Node<T>{
        get(){
            throw UnreachableException()
        }
        set(value){
            throw UnreachableException()
        }
    }
}

abstract class AbstractNode<T> <: Node<T> {
    AbstractNode(
        let globalLock: Mutex
    ){}
}

protected class HeadNode<T> <: AbstractNode<T> {
    private let next_ = AtomicOptionReference<Node<T>>()
    protected let tail: TailNode<T>
    protected init(globalLock: Mutex){
        super(globalLock)
        synchronized(globalLock){
            this.tail = TailNode<T>(globalLock)
            this.next = tail
            tail.prev = this
        }
        
    }
    protected func insertNext(value: T): ValueNode<T> {
        synchronized(globalLock){
            ValueNode<T>(globalLock, this, next, value)
        }
    }
    protected mut prop next: Node<T> {
        get(){
            this.next_.load().getOrThrow()
        }
        set(value){
            this.next_.store(value)
        }
    }
    protected func nextForGet(): ?T {
        match(next){
            case x: TailNode<T> => None
            case x: ValueNode<T> => 
                if(x.idle){
                    synchronized(globalLock){
                        if(x.idle){
                            x.setBusy()
                            x.doRemove()
                            return x.value
                        }
                    }
                }
                x.nextForGet()
            case _ => throw UnreachableException()
        }
    }
}
protected class TailNode<T> <: AbstractNode<T> {
    private let prev_ = AtomicOptionReference<Node<T>>()
    init(globalLock: Mutex){
        super(globalLock)
    }
    init(globalLock: Mutex, prev: Node<T>){
        super(globalLock)
        synchronized(globalLock){
            this.prev = prev
        }
    }
    protected func insertPrev(value: T): ValueNode<T> {
        synchronized(globalLock){
            ValueNode<T>(globalLock, prev, this, value)
        }
    }
    protected func prevForChecking(): ?Node<T> {
        match(prev){
            case x: HeadNode<T> => None
            case x: ValueNode<T> => 
                if(x.idle){
                    synchronized(globalLock){
                        if(x.idle){
                            x.setChecking()
                            return x
                        }
                    }
                }
                x.prevForChecking()
            case _ => throw UnreachableException()
        }
    }
    protected mut prop prev: Node<T> {
        get(){
            this.prev_.load().getOrThrow()
        }
        set(value){
            this.prev_.store(value)
        }
    }
}
protected class ValueNode<T> <: AbstractNode<T> {
    private let status = AtomicInt8(VALUE_NODE_IDLE)
    private let prev_ = AtomicOptionReference<Node<T>>()
    private let next_ = AtomicOptionReference<Node<T>>()
    ValueNode(globalLock: Mutex, prev: Node<T>, next: Node<T>, let value: T){
        super(globalLock)
        synchronized(globalLock){
            this.prev = prev
            this.next = next
            match(next){
                case n: TailNode<T> => n.prev = this
                case n: ValueNode<T> => n.prev = this
                case _ => throw UnreachableException()
            }
            match(prev){
                case p: HeadNode<T> => p.next = this
                case p: ValueNode<T> => p.next = this
                case _ => throw UnreachableException()
            }
        }
    }
    protected mut prop prev: Node<T> {
        get(){
            this.prev_.load().getOrThrow()
        }
        set(value){
            this.prev_.store(value)
        }
    }
    protected mut prop next: Node<T> {
        get(){
            this.next_.load().getOrThrow()
        }
        set(value){
            this.next_.store(value)
        }
    }
    func remove(): Unit {
        synchronized(globalLock){
            doRemove()
        }
    }
    func doRemove(): Unit {
        match(next){
            case n: TailNode<T> => n.prev = this.prev
            case n: ValueNode<T> => n.prev = this.prev
            case _ => throw UnreachableException()
        }
        match(prev){
            case p: HeadNode<T> => p.next = this.next
            case p: ValueNode<T> => p.next = this.next
            case _ => throw UnreachableException()
        }
    }
    protected func prevForChecking(): ?Node<T> {
        var node: Node<T> = this.prev
        while(let x: ValueNode<T> <- node){
            if(!x.idle){
                node = x.prev
                sleep(Duration.Zero)
                continue
            }
            synchronized(globalLock){
                if(!x.idle){
                    node = x.prev
                    sleep(Duration.Zero)
                    continue
                }
                x.setChecking()
                return x
            }
            sleep(Duration.Zero)
        }
        None
    }
    protected func nextForGet(): ?T {
        var node: Node<T> = this.next
        while(let x: ValueNode<T> <- node){
            if(!x.idle){
                node = x.next
                sleep(Duration.Zero)
                continue
            }
            synchronized(globalLock){
                if(!x.idle){
                    node = x.next
                    sleep(Duration.Zero)
                    continue
                }
                x.setBusy()
                x.doRemove()
                x.value
            }
            sleep(Duration.Zero)
        }
        None
    }
    prop checking: Bool {
        get(){
            status.load() == VALUE_NODE_CHECKING
        }
    }
    prop idle: Bool {
        get(){
            status.load() == VALUE_NODE_IDLE
        }
    }
    prop busy: Bool {
        get(){
            status.load() == VALUE_NODE_BUSY
        }
    }
    prop invalidated: Bool {
        get(){
            status.load() == VALUE_NODE_INVALIDATED
        }
    }
    func setIdle(): Unit {
        status.store(VALUE_NODE_IDLE)
    }
    func setBusy(): Unit {
        status.store(VALUE_NODE_BUSY)
    }
    func setInvalidated(): Unit {
        status.store(VALUE_NODE_INVALIDATED)
    }
    func setChecking(): Unit {
        status.store(VALUE_NODE_CHECKING)
    }
    protected func check(fn: (T) -> Bool): Bool {
        if(fn(value)){
            this.setIdle()
            true
        }else{
            remove()
            false
        }
    }
}