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
