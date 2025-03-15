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

import std.collection.HashSet

@Annotation[target: [MemberFunction]]
public class Transactional {
    public const Transactional(
        public let rollbackFor!: String = "",
        public let noRollbackFor!: String = "",
        public let driverName!: String = String.empty,
        public let propagation!: ?Propagation = None,
        public let isoLevel!: ?TransactionIsoLevel = None,
        public let accessMode!: ?TransactionAccessMode = None,
        public let deferrableMode!: ?TransactionDeferrableMode = None
    ) {}

    public func getPropagation(): Propagation {
        if (let Some(p) <- propagation) {
            p
        } else {
            ORMConfig.getTransactionPropagation(driverName: this.driverName)
        }
    }
    public func getIsoLevel(): ?TransactionIsoLevel {
        if (let Some(l) <- isoLevel) {
            l
        } else if (let Some(l) <- ORMConfig.getTransactionLevel(driverName: this.driverName)) {
            l
        } else {
            None
        }
    }
    public func getAccessMode(): ?TransactionAccessMode {
        if (let Some(m) <- accessMode) {
            m
        } else if (let Some(m) <- ORMConfig.getTransactionAccessMode(driverName: this.driverName)) {
            m
        } else {
            None
        }
    }
    public func getDeferrableMode(): ?TransactionDeferrableMode {
        if (let Some(m) <- deferrableMode) {
            m
        } else if (let Some(m) <- ORMConfig.getTransactionDeferrableMode(driverName: this.driverName)) {
            m
        } else {
            None
        }
    }
}
