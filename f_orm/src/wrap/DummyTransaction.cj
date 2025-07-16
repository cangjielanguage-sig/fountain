/*
   Copyright (c) 2022 WuJingrun（吴京润）
   fountain is licensed under Mulan PSL v2.
   You can use this software according to the terms and conditions of the Mulan PSL v2.
   You may obtain a copy of Mulan PSL v2 at:
           http://license.coscl.org.cn/MulanPSL2
   THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
   See the Mulan PSL v2 for more details.
 */

package f_orm.wrap

public enum DummyTransactionMode {
    | Common
    | Mandatory
    | Never
    | StartFailure
}

public class DummyTransaction <: Transaction {
    public DummyTransaction(private let mode: DummyTransactionMode, private let ex: ?Exception) {}
    private var level: TransactionIsoLevel = TransactionIsoLevel.Unspecified
    public mut prop isoLevel: TransactionIsoLevel {
        get() {
            level
        }
        set(value) {
            level = value
        }
    }
    private var access: TransactionAccessMode = TransactionAccessMode.Unspecified
    public mut prop accessMode: TransactionAccessMode {
        get() {
            access
        }
        set(value) {
            access = value
        }
    }
    private var deferrable: TransactionDeferrableMode = TransactionDeferrableMode.Unspecified
    public mut prop deferrableMode: TransactionDeferrableMode {
        get() {
            deferrable
        }
        set(value) {
            deferrable = value
        }
    }
    public func begin(): Unit {
        match ((mode, ex)) {
            case (Mandatory, Some(e)) => throw MandatoryTransactionException(e)
            case (Mandatory, _) => throw MandatoryTransactionException()
            case (Never, Some(e)) => throw NeverTransactionException(e)
            case (Never, _) => throw NeverTransactionException()
            case (StartFailure, Some(e)) => throw StartFailureTransactionException("transaction is not be created", e)
            case (StartFailure, _) => throw StartFailureTransactionException("transaction is not be created")
            case (_, Some(e)) => throw TransactionException(e)
            case _ => ()
        }
    }
    public func commit(): Unit {}
    public func rollback(): Unit {}
    public func save(savePointName: String): Unit {}
    public func rollback(savePointName: String): Unit {}
    public func release(savePointName: String): Unit {}
}
