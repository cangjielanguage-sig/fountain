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
public import f_aspect.*

@AspectRoute[FuncAnnotationRouteRule("f_orm.Transactional") | ConfigExecutionRouteRule(ORMConfig.transactionalFuncExecution)]
@BeanMeta
public class TransactionAspect <: Aspect {
    static init() {
        BeanFactory.instance.register<TransactionAspect>({=> TransactionAspect()})
    }
    private init() {}
    private let rollbackExceptions = ConcurrentHashMap<String, HashSet<TypeInfo>>()

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
        if (propagation.isNone()) {
            propagation = ORMConfig.getTransactionPropagation(driverName: driverName)
        }
        if (isoLevel.isNone()) {
            isoLevel = ORMConfig.getTransactionLevel(driverName: driverName)
        }
        if (accessMode.isNone()) {
            accessMode = ORMConfig.getTransactionAccessMode(driverName: driverName)
        }
        if (deferrableMode.isNone()) {
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
                rollbackExceptions.computeIfAbsent(ex){
                    let set = HashSet<TypeInfo>()
                    for (e in ex.split("|") where e.size > 0) {
                        set.add(TypeInfos.get(e.trimAscii()))
                    }
                    set
                }
            }

            if (let Some(noRollbackFor) <- transactional?.noRollbackFor && noRollbackFor.size > 0) {
                let set: Set<TypeInfo> = genExceptionSet(noRollbackFor)
                for (noRollback in set where et.isSubtypeOf(noRollback)) {
                    ORM.hooks.beforeCommit(exe.isReadOnly)
                    let thrown = exe.noRollbackFor(e)
                    txStatus = Committed
                    ORM.hooks.afterCommit()
                    throw thrown
                }
            }
            if (let Some(rollbackFor) <- transactional?.rollbackFor && rollbackFor.size > 0) {
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
