/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_orm

import std.collection.{Set, HashSet}
import std.collection.concurrent.ConcurrentHashMap
import std.reflect.*
import std.sync.ReentrantMutex
import f_aspect.*
import f_base.*
import f_bean.{BeanFactory, BeanMeta}
import f_collection.*
import f_orm.wrap.ORMConfig

@AspectRoute[OrRouteRule(FuncAnnotationRouteRule("f_orm.Transactional"), ConfigExecutionRouteRule(ORMConfig.transactionalFuncExecution))]
@BeanMeta
public class TransactionAspect <: Aspect {
    public static func initialize(): Unit {
        BeanFactory.instance.register<TransactionAspect>{TransactionAspect()}
    }
    private init(){}
    private let rollbackExceptions = ConcurrentHashMap<String, HashSet<TypeInfo>>()
    private let mutex = ReentrantMutex()
    private let transactionalMap = ConcurrentHashMap<String, Transactional>()
    
    public func proceed(funcInfo: InvocationFuncInfo, point: (Array<Any>) -> Any): Any {
        let transactional = funcInfo.funcInfo.findAnnotation<Transactional>()
        var driverName = ""
        var propagation = Propagation.Required
        var isoLevel = None<TransactionIsoLevel>
        var accessMode = None<TransactionAccessMode>
        var deferrableMode = None<TransactionDeferrableMode>
        if(let Some(x) <- transactional){
            driverName = x.driverName
            if(let Some(p) <- x.propagation){
                propagation = p
            }
            isoLevel = x.isoLevel
            accessMode = x.accessMode
            deferrableMode = x.deferrableMode
        }
        try(exe = ORM.executor(driverName)){
            try {
                exe.newTxAndBegin(
                    propagation: propagation,
                    isoLevel: isoLevel,
                    accessMode: accessMode,
                    deferrableMode: deferrableMode
                )
                let result = point()
                exe.commit()
                result
            } catch (e: Exception) {
                let et = TypeInfo.of(e)
                func genExceptionSet(ex: String){
                    if(let Some(s) <- rollbackExceptions.get(ex)){
                        s
                    }else{
                        let set = HashSet<TypeInfo>()
                        for(e in ex.split("|") where e.size > 0){
                            set.add(TypeInfos.get(e.trimAscii()))
                        }
                        rollbackExceptions[ex] = set
                        set
                    }
                }
                if (let Some(noRollbackFor) <- transactional?.noRollbackFor) {
                    let set: Set<TypeInfo> = genExceptionSet(noRollbackFor)
                    for(noRollback in set where et.isSubtypeOf(noRollback)){
                        throw exe.noRollbackFor(e)
                    }
                }
                if(let Some(rollbackFor) <- transactional?.rollbackFor){
                    let set: Set<TypeInfo> = genExceptionSet(rollbackFor)
                    for(rollback in set where et.isSubtypeOf(rollback)){
                        throw exe.rollbackFor(e)
                    }
                    throw exe.noRollbackFor(e)
                } else {
                    exe.rollback()
                    throw e
                }
            }
        }
    }
}
