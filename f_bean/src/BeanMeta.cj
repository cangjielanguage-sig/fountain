/*
    Copyright (c) 2022 WuJingrun（吴京润）
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_bean

/**
 * bean元数据
 */
@Annotation[target: [MemberFunction, Type]]
public class BeanMeta <: Comparable<BeanMeta> {
    public const BeanMeta(
        public let name!: String = '',
        public let lazy!: Bool = true,
        public let scope!: BeanScope = BeanScope.singleton,
        public let order!: Int64 = 0,
        public let primary!: Bool = false,
        public let condition!: BeanCondition = NoneBeanCondition.instance
    ) {}

    public func compare(meta: BeanMeta): Ordering {
        if (this.primary && !meta.primary) {
            LT
        } else if (!this.primary && meta.primary) {
            GT
        } else {
            match (this.order.compare(meta.order)) {
                case EQ where !(this.name.isEmpty() || meta.name.isEmpty()) => this.name.compare(meta.name)
                case x => x
            }
        }
    }
}
