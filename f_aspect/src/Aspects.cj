/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_aspect

import std.collection.concurrent.ConcurrentHashMap
import std.sync.ReentrantMutex
import f_base.*
import f_bean.{BeanFactory, BeanManager}
import f_collection.*
import f_macros.*
import f_regex.*

public class Aspects {
    private static let aspects = ConcurrentHashMap<QualifiedFuncInfo, (Array<Any>) -> Any>()
    private static let mutex = ReentrantMutex()
    private static func doProceed<T>(funcInfo: InvocationFuncInfo, fn: (Array<Any>) -> T): T {
        let r = if(let Some(f) <- aspects.get(funcInfo.qualifiedFuncInfo)){
            f
        }else{
            synchronized(mutex){
                if(let Some(f) <- aspects.get(funcInfo.qualifiedFuncInfo)){
                    f
                }else{
                    let list = ArrayList<String>()
                    for(m in BeanFactory.instance.iterator<Aspect>() 
                        where m.beanType.findAnnotation<AspectRoute>()?.matches(funcInfo) ?? false){
                        list.add(m.name)
                    }
                    var f: (Array<Any>) -> Any = {args => fn(args)}
                    for(i in list.size - 1 ..= 0){
                        let aspected = f
                        f = {args => 
                            BeanFactory.instance.get<Aspect>(list[i]).getOrThrow().proceed(funcInfo, aspected)
                        }
                    }
                    aspects[funcInfo.qualifiedFuncInfo] = f
                    f
                }
            }
        }(funcInfo.args)
        match(r){
            case x: T => x
            case _ => throw TypeCastException('Type of ${TypeInfo.of(r)} does not match ${TypeInfos.get<T>()}')
        }
    }
    private static let recursiveInvocationFlag = ThreadLocal<Bool>()
    /**本函数不是给开发者用的，是给工具库生成切点使用的*/
    public static func proceed<T>(funcInfo: InvocationFuncInfo, fn: (Array<Any>) -> T): T {
        func setRecursiveSerial() {
            try {//避免递归调用切点函数时切面也被重复执行
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
