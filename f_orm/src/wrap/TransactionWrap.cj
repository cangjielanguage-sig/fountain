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

public class TransactionWrap <: Transaction {
    public TransactionWrap(
        private let transaction: Transaction,
        public var connection: Connection,
        public var suspend!: Bool = false
    ) {}

    public var wrapping = None<TransactionWrap>
    public prop isDummy: Bool {
        get() {
            transaction is DummyTransaction
        }
    }

    public func setIsoLevel(level: TransactionIsoLevel): TransactionWrap {
        transaction.isoLevel = level
        this
    }
    public mut prop isoLevel: TransactionIsoLevel {
        get() {
            transaction.isoLevel
        }
        set(value) {
            transaction.isoLevel = value
        }
    }
    public func setAccessMode(mode: TransactionAccessMode): TransactionWrap {
        transaction.accessMode = mode
        this
    }
    public mut prop accessMode: TransactionAccessMode {
        get() {
            transaction.accessMode
        }
        set(value) {
            transaction.accessMode = value
        }
    }
    public func setDeferrableMode(mode: TransactionDeferrableMode): TransactionWrap {
        transaction.deferrableMode = mode
        this
    }
    public mut prop deferrableMode: TransactionDeferrableMode {
        get() {
            transaction.deferrableMode
        }
        set(value) {
            transaction.deferrableMode = value
        }
    }
    public func begin(): Unit {
        transaction.begin()
    }
    public func commit(): Unit {
        transaction.commit()
    }
    public func rollback(): Unit {
        transaction.rollback()
    }
    public func save(savePointName: String): Unit {
        transaction.save(savePointName)
    }
    public func rollback(savePointName: String): Unit {
        transaction.rollback(savePointName)
    }
    public func release(savePointName: String): Unit {
        transaction.release(savePointName)
    }
}
