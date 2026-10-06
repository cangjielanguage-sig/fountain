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
import fountain::f_base.{Addable, EmptyIterator}
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
        let v: W
        synchronized(mutex){
            v = current
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
        // 不能用 closed: true —— 那是给整数类型准备的（把区间扩成 [min, max] 要 +1），
        // 对浮点会把取值区间放大成 [min, max+1) ⇒ 权重比例整体失真
        //（实测等权 [1,1]、区间 [0,2] 时命中率是 653:347，见 .autocode/bugs/bug-archived-20261004-2.md）。
        // 均匀分布取到端点的概率本来就为 0，[min, max) 与 [min, max] 等价。
        random.nextFloat64(min, max)
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
        let forward = if(tree.isEmpty()){
            EmptyIterator<(D) -> R>.instance()
        }else{
            tree.forward(algo.next(), inclusive: true).map(mapper)
        }
        LoadBalanceIterator<D, R>(tree.iterator().map(mapper), forward)
    }
}
class LoadBalanceIterator<D, R> <: Iterator<(D) -> R> {
    LoadBalanceIterator(
        private let itr: Iterator<(D) -> R>,
        private let sub: Iterator<(D) -> R>
    ){}
    private var endsub = false
    public func next(): ?(D) -> R {
        // 先走负载算法选定的位置（sub：从当前键往后的部分），走完再从头（itr）绕回。
        // 原来这里读的是 itr（整棵树、按键升序）⇒ 算法的选择从未生效，每次都命中键最小的节点
        // （= 最先 add 的节点），负载均衡形同虚设：权重、随机、轮询全都不起作用（见 .autocode/bugs/bug-archived-20261004-2.md）。
        if(endsub){
            return itr.next()
        }else if(let Some(f) <- sub.next()){
            return f
        }
        endsub = true
        next()
    }
}