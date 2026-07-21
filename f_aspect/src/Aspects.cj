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

public class Aspects {
    private static let aspects = ConcurrentHashMap<QualifiedFuncInfo, (Array<Any>) -> Any>()
    private static func doProceed<T>(funcInfo: InvocationFuncInfo, fn: (Array<Any>) -> T): T {
        let f = aspects.computeIfAbsent(funcInfo.qualifiedFuncInfo){
                let list = ArrayList<String>()
                for (m in BeanFactory.instance.iterator<Aspect>() where m
                    .beanType
                    .findAnnotation<AspectRoute>()?
                    .matches(funcInfo) ?? false) {
                    list.add(m.name)
                }
                var f: (Array<Any>) -> Any = {args => fn(args)}
                for (i in list.size - 1..=0 : -1) {
                    let aspected = f
                    let aspectName = list[i]
                    f = {
                        args =>
                        funcInfo.setArgs(args)
                        BeanFactory.instance.get<Aspect>(aspectName).getOrThrow().proceed(funcInfo, aspected)
                    }
                }
                f
        }
        match (f(funcInfo.args)) {
            case x: T => x
            case r => throw TypeCastException('Type of ${TypeInfo.of(r)} does not match ${TypeInfo.of<T>()}')
        }
    }
    private static let recursiveInvocationFlag = ThreadLocal<Bool>()
    /**本函数不是给开发者用的，是给工具库生成切点使用的*/
    public static func proceed<T>(funcInfo: InvocationFuncInfo, fn: (Array<Any>) -> T): T {
        func setRecursiveSerial() {
            try { //避免递归调用切点函数时切面也被重复执行
                recursiveInvocationFlag.set(true)
                doProceed<T>(funcInfo, fn)
            } finally {
                recursiveInvocationFlag.remove()
            }
        }
        match (recursiveInvocationFlag.get()) {
            case Some(_) => fn(funcInfo.args)
            case _ => setRecursiveSerial()
        }
    }
}
