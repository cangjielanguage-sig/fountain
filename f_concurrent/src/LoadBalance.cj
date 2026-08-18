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
package fountain::f_concurrent

import std.collection.TreeMap
import std.math.Number as StdNumber
import std.sync.Mutex
import stdx.crypto.crypto.SecureRandom
import fountain::f_base.Addable
import fountain::f_random.*
import fountain::f_concurrent.exception.LoadBalanceException

public interface LoadBalanceAlgo<W> where W <: Addable<W> & Comparable<W> {
    mut func next(): W
}
public struct RoundRobin<W> <: LoadBalanceAlgo<W> where W <: Addable<W> & Comparable<W> {
    private let mutex = Mutex()
    private var current: W
    public RoundRobin(private let step: W, private let min: W, private let max: W){
        current = min
    }
    public mut func next(): W{
        let v = current
        synchronized(mutex){
            current += step
        }
        if(current > max){
            synchronized(mutex){
                if(current > max){
                    current = min
                }
            }
        }
        v
    }
}
public abstract class RandomWeight<W> <: LoadBalanceAlgo<W> where W <: StdNumber<W> & Addable<W> & Comparable<W> {
    protected let random = SecureRandom()
    public RandomWeight(protected let min: W, protected let max: W){}
}
public class Int64Weight <: RandomWeight<Int64>{
    public init(min: Int64, max: Int64){
        super(min, max)
    }
    public func next(): Int64 {
        random.nextInt64(min, max, closed: true)
    }
}
public class Float64Weight <: RandomWeight<Float64>{
    public init(min: Float64, max: Float64){
        super(min, max)
    }
    public func next(): Float64 {
        random.nextFloat64(min, max, closed: true)
    }
}
public class LoadBalance<W, D, R> where W <: Addable<W> & Comparable<W> {
    private let tree = TreeMap<W, (D) -> R>()
    public LoadBalance(private let min: W, private let algo: LoadBalanceAlgo<W>){}
    public func add(weight: W, fn: (D) -> R): Unit {
        let max = tree.last?[0] ?? min
        let new = max + weight
        tree[new] = fn
    }
    public func add(all!: Iterable<(W, (D) -> R)>): Unit {
        for((w, fn) in all){
            add(w, fn)
        }
    }
    public func call(data: D): R {
        tree.forward(algo.next(), inclusive: true).next().getOrThrow()[1](data)
    }
    public func call(data: D, maxRetrying: Int64): (?R, ?LoadBalanceException) {
        var tried = 0
        var ex = None<LoadBalanceException>
        for(f in iterator()){
            try{
                return (f(data), ex)
            }catch(e: Exception){
                if(let Some(e) <- ex){
                    e
                }else{
                    let e = LoadBalanceException()
                    ex = e
                    e
                }.addSuppressed(e)
                if(tried < maxRetrying){
                    tried++
                    continue
                }
                throw ex.getOrThrow()
            }
        }
        (None<R>, ex)
    }
    public func iterator(): Iterator<(D) -> R> {
        func mapper(tpl: (W, (D) -> R)){
            tpl[1]
        }
        LoadBalanceIterator<D, R>(tree.iterator().map(mapper), tree.forward(algo.next(), inclusive: true).map(mapper))
    }
}
class LoadBalanceIterator<D, R> <: Iterator<(D) -> R> {
    LoadBalanceIterator(
        private let itr: Iterator<(D) -> R>,
        private let sub: Iterator<(D) -> R>
    ){}
    private var endsub = false
    public func next(): ?(D) -> R {
        if(endsub){
            return itr.next()
        }else if(let Some(f) <- itr.next()){
            return f
        }
        endsub = true
        next()
    }
}