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
package fountain::f_aspect

import std.collection.concurrent.ConcurrentHashMap
import fountain::f_base.*
import fountain::f_bean.{BeanFactory, BeanManager}
import fountain::f_collection.*
import fountain::f_macros.*
import fountain::f_aspect.exception.AspectException

/**
 * 织入中的线程本地状态（`Aspects.proceed` 用）：`state` 为 true 表示当前线程已在某次织入调用内
 * （嵌套调用不再织入，见 README「嵌套调用与递归（设计）」）。
 * 用按线程的可变对象而不是 `ThreadLocal<Bool>`：每调用只读一次引用 + 读写一个 Bool 字段，
 * 省掉 `?Bool` 装箱与第二次 ThreadLocal 访问；对象每线程只在首次调用时创建一次，之后不再产生垃圾
 * （旧写法每次最外层调用都会把 `true` 装箱进 ThreadLocal、`remove()` 再 `set(None)`）。
 */
private class RecursionState {
    var state = false
}

public class Aspects {
    /**
     * 切面链缓存：按「(类型, 函数)」只在切点函数首次被调用时构建一次，之后一直复用，这是刻意的设计。
     *
     * 建链要遍历 IoC 中全部 Aspect bean 并逐条做织入规则匹配（见 doProceed），成本高，而匹配结果只取决于切点函数的签名（类型 + 函数），
     * 与实例无关，所以只算一次；由此织入的粒度是「类型」而不是「实例」：同一类型的多个实例共享同一条链，
     * 链尾保存的是首次调用传入的 callee（宏展开出的原函数体闭包，含该次调用的接收者），见 f_aspect/README.md「织入逻辑会在这些函数首次调用时执行」。
     *
     * 链上**不保存调用数据**：链的构造只依赖不可变的函数元数据（`qualifiedFuncInfo`）；实参按调用逐层传递，
     * 每层用本次调用的 `args` 新建一个 `InvocationFuncInfo` 交给切面（见 doProceed 的层闭包），
     * 因此并发调用之间不共享任何可变状态。
     *
     * 前提：被织入的对象必须是 IoC 管理的 bean（singleton 或 prototype 均可），手工 new 出来的实例不在支持范围内。
     */
    // 值里带一个「是否空链」标记：空链时 doProceed 走快路径，把本次调用的 fn 按 T 直接返回，返回值不经 Any（值类型不装箱/解箱）
    private static let aspects = ConcurrentHashMap<QualifiedFuncInfo, (Bool, (Array<Any>) -> Any)>()
    /**
     * 空链占位：没有任何切面命中该切点时用它占位（doProceed 走快路径、不会调用它），
     * 于是空链既不必包装 lambda，也不会捕获首次调用的 callee。
     */
    private static let emptyChain: (Array<Any>) -> Any = {
        _ => throw AspectException('no aspect matches this pointcut')
    }
    private static func doProceed<T>(funcInfo: InvocationFuncInfo, fn: (Array<Any>) -> T): T {
        let qualifiedFuncInfo = funcInfo.qualifiedFuncInfo // 链只依赖这个不可变的函数元数据
        let entry = aspects.computeIfAbsent(qualifiedFuncInfo) {
            let list = ArrayList<BeanManager>()
            for (m in BeanFactory.instance.iterator<Aspect>() where m
                .beanType
                .findAnnotation<AspectRoute>()?
                .matches(funcInfo) ?? false) {
                list.add(m)
            }
            if (list.isEmpty()) {
                // 没有任何切面命中：不建链、不捕获本次调用的 fn（快路径在下面）
                (true, emptyChain)
            } else {
                // 链尾固化首次调用传入的 fn（原函数体闭包）—— 链属于「类型」，设计说明见 aspects 声明处
                var f: (Array<Any>) -> Any = {args => fn(args)}
                for (i in list.size - 1..=0 : -1) {
                    let aspected = f
                    let aspectBeanManager = list[i]
                    f = {
                        args =>
                            // 实参逐调用传递：用本次调用的 args 新建 InvocationFuncInfo，切面与后续层只持有它，
                            // 不再改写链上首个实例（见 bug.md §1.4：原来 setArgs 写共享槽，并发下参数互串）
                            match(aspectBeanManager.bean){
                                case x: Aspect => 
                                    let info = InvocationFuncInfo(qualifiedFuncInfo, args)
                                    x.proceed(info, aspected)
                                case _ => throw AspectException('Aspect bean is not an Aspect')
                            }
                    }
                }
                (false, f)
            }
        }
        if (entry[0]) {
            // 空链快路径：直接执行本次调用的原函数体，返回值类型就是 T（不装箱/解箱、不多一层包装调用）
            fn(funcInfo.args)
        } else {
            match (entry[1](funcInfo.args)) {
                case x: T => x
                case r => throw TypeCastException('Type of ${TypeInfo.of(r)} does not match ${TypeInfo.of<T>()}')
            }
        }
    }
    /** 每线程一份的可变状态，说明见文件顶部 `RecursionState` */
    private static let recursion = ThreadLocal<RecursionState>()
    /**本函数不是给开发者用的，是给工具库生成切点使用的*/
    public static func proceed<T>(funcInfo: InvocationFuncInfo, fn: (Array<Any>) -> T): T {
        let st = recursion.getOrCompute({=> RecursionState()})
        func setRecursiveSerial() {
            try { //避免递归调用切点函数时切面也被重复执行
                st.state = true
                doProceed<T>(funcInfo, fn)
            } finally {
                st.state = false
            }
        }
        if (st.state) {
            fn(funcInfo.args)
        } else {
            setRecursiveSerial()
        }
    }
}
