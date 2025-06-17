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
import std.sync.Mutex
import f_aspect.*
import f_base.*
import f_bean.{BeanFactory, BeanMeta}
import f_collection.*
import f_orm.wrap.ORMConfig

@AspectRoute[FuncAnnotationRouteRule("f_orm.Transactional") | ConfigExecutionRouteRule(ORMConfig.transactionalFuncExecution)]
@BeanMeta
public class TransactionAspect <: Aspect {
    private init() {}
    private let rollbackExceptions = ConcurrentHashMap<String, HashSet<TypeInfo>>()
    private let mutex = Mutex()
    private let transactionalMap = ConcurrentHashMap<String, Transactional>()

    public func proceed(funcInfo: InvocationFuncInfo, point: (Array<Any>) -> Any): Any {
        let transactional = funcInfo.funcInfo.findAnnotation<Transactional>()
        var driverName = ""
        var propagation = None<Propagation>
        var isoLevel = None<TransactionIsoLevel>
        var accessMode = None<TransactionAccessMode>
        var deferrableMode = None<TransactionDeferrableMode>
        if (let Some(x) <- transactional) {
            driverName = x.driverName
            if (let Some(p) <- x.propagation) {
                propagation = p
            }
            isoLevel = x.isoLevel
            accessMode = x.accessMode
            deferrableMode = x.deferrableMode
        }
        if(propagation.isNone()){
            propagation = ORMConfig.getTransactionPropagation(driverName: driverName)
        }
        if(isoLevel.isNone()){
            isoLevel = ORMConfig.getTransactionLevel(driverName: driverName)
        }
        if(accessMode.isNone()){
            accessMode = ORMConfig.getTransactionAccessMode(driverName: driverName)
        }
        if(deferrableMode.isNone()){
            deferrableMode = ORMConfig.getTransactionDeferrableMode(driverName: driverName)
        }
        var exe = ORM.executor(driverName) // 如果此处发生异常就无所谓回滚事务了，所以ORM.executor(driverName)不必在try块内
        var txStatus = TransactionStatus.Unknown
        try {
            ORM.hooks.beforeTx()
            exe.newTxAndBegin(
                propagation: propagation ?? Propagation.Required,
                isoLevel: isoLevel,
                accessMode: accessMode,
                deferrableMode: deferrableMode
            )
            let result = point()
            ORM.hooks.beforeCommit(exe.isReadOnly)
            exe.commit()
            txStatus = Committed
            ORM.hooks.afterCommit()
            result
        } catch (e: Exception) {
            ORM.hooks.afterThrowing(e)
            let et = ClassTypeInfo.of(e)
            func genExceptionSet(ex: String) {
                if (let Some(s) <- rollbackExceptions.get(ex)) {
                    s
                } else {
                    let set = HashSet<TypeInfo>()
                    for (e in ex.split("|") where e.size > 0) {
                        set.add(TypeInfos.get(e.trimAscii()))
                    }
                    rollbackExceptions[ex] = set
                    set
                }
            }
            
            if (let Some(noRollbackFor) <- transactional?.noRollbackFor) {
                let set: Set<TypeInfo> = genExceptionSet(noRollbackFor)
                for (noRollback in set where et.isSubtypeOf(noRollback)) {
                    ORM.hooks.beforeCommit(exe.isReadOnly)
                    let thrown = exe.noRollbackFor(e)
                    txStatus = Committed
                    ORM.hooks.afterCommit()
                    throw thrown
                }
            }
            if (let Some(rollbackFor) <- transactional?.rollbackFor) {
                let set: Set<TypeInfo> = genExceptionSet(rollbackFor)
                for (rollback in set where et.isSubtypeOf(rollback)) {
                    ORM.hooks.beforeRollback(e)
                    let thrown = exe.rollbackFor(e)
                    txStatus = Rollback
                    ORM.hooks.afterRollback(e)
                    throw thrown
                }
                ORM.hooks.beforeCommit(exe.isReadOnly)
                let thrown = exe.noRollbackFor(e)
                txStatus = Committed
                ORM.hooks.afterCommit()
                throw thrown
            } else {
                ORM.hooks.beforeRollback(e)
                exe.rollback()
                txStatus = Rollback
                ORM.hooks.afterRollback(e)
                throw e
            }
        } finally {
            ORM.hooks.afterComplete(txStatus)
            exe.close()
        }
    }
}
private let _ = BeanFactory.instance.register<TransactionAspect>({=> TransactionAspect()})