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

public enum TransactionStatus <: Equatable<TransactionStatus> & ToString {
    | Unknown
    | Committed
    | Rollback

    public operator func ==(other: TransactionStatus): Bool {
        match ((this, other)) {
            case (Unknown, Unknown) | (Committed, Committed) | (Rollback, Rollback) => true
            case _ => false
        }
    }
    public prop isUnknown: Bool {
        get() {
            this == Unknown
        }
    }
    public prop isCommitted: Bool {
        get() {
            this == Committed
        }
    }
    public prop isRollback: Bool {
        get() {
            this == Rollback
        }
    }
    public func toString(): String {
        match (this) {
            case Unknown => 'Unknown'
            case Committed => 'Committed'
            case Rollback => 'Rollback'
        }
    }
}
