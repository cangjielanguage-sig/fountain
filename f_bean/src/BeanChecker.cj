/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_bean



struct BeanChecker <: IBeanCondition {
    BeanChecker(
        let dependency!: Bool = true,
        let nameDef!: ?BeanNameDef = None,
        let typeDef!: ?TypeDef = None,
        let beanDef!: ?BeanDef = None
    ) {}
    public func on(): Bool {
        var result = true
        var nameMatchedCount = 0
        var beanMatchedCount = 0

        let tree = BeanFactory.instance.getBeanManagers<Any>()
        for (bean in tree) {
            let name = bean.name
            if (let Some(n) <- nameDef) {
                result &&= match (n) {
                    case WithName(n) where n == name =>
                        nameMatchedCount++
                        true
                    case WithoutName(n) where n != name => true
                    case WithPrefix(n) where name.startsWith(n) =>
                        nameMatchedCount++
                        true
                    case OnlyOnePrefix(n) where name.startsWith(n) =>
                        nameMatchedCount++
                        if (nameMatchedCount > 1) {
                            false
                        } else {
                            true
                        }
                    case MultiPrefix(n) where name.startsWith(n) =>
                        nameMatchedCount++
                        true
                    case WithoutPrefix(n) where !name.startsWith(n) => true
                    case WithSuffix(n) where name.endsWith(n) =>
                        nameMatchedCount++
                        true
                    case OnlyOneSuffix(n) where name.endsWith(n) =>
                        nameMatchedCount++
                        if (nameMatchedCount > 1) {
                            false
                        } else {
                            true
                        }
                    case MultiSuffix(n) where name.endsWith(n) =>
                        nameMatchedCount++
                        true
                    case WithoutSuffix(n) where !name.endsWith(n) => true
                    case WithRegex(n) where n.regex().matched(name) =>
                        nameMatchedCount++
                        true
                    case OnlyOneRegex(n) where n.regex().matched(name) =>
                        nameMatchedCount++
                        if (nameMatchedCount > 1) {
                            false
                        } else {
                            true
                        }
                    case MultiRegex(n) where n.regex().matched(name) =>
                        nameMatchedCount++
                        true
                    case WithoutRegex(n) where !n.regex().matched(name) => true
                    case WithWildcard(n) where n.replace("?", ".?").replace("*", ".*").regex().matched(name) =>
                        nameMatchedCount++
                        true
                    case WithoutWildcard(n) where !n.replace("?", ".?").replace("*", ".*").regex().matched(name) => true
                    case OnlyOneWildcard(n) where n.replace("?", ".?").replace("*", ".*").regex().matched(name) =>
                        nameMatchedCount++
                        if (nameMatchedCount > 1) {
                            false
                        } else {
                            true
                        }
                    case MultiWildcard(n) where n.replace("?", ".?").replace("*", ".*").regex().matched(name) =>
                        nameMatchedCount++
                        true
                    case _ => false
                }
                result &&= if (nameMatchedCount == 0) {
                    match (n) {
                        case MultiPrefix(_) => false
                        case MultiSuffix(_) => false
                        case MultiRegex(_) => false
                        case MultiWildcard(_) => false
                        case OnlyOnePrefix(_) => false
                        case OnlyOneSuffix(_) => false
                        case OnlyOneRegex(_) => false
                        case OnlyOneWildcard(_) => false
                        case WithName(_) => false
                        case WithPrefix(_) => false
                        case WithSuffix(_) => false
                        case WithRegex(_) => false
                        case WithWildcard(_) => false
                        case _ => true
                    }
                } else {
                    match (n) {
                        case WithoutName(_) => false
                        case WithoutPrefix(_) => false
                        case WithoutSuffix(_) => false
                        case WithoutRegex(_) => false
                        case WithoutWildcard(_) => false
                        case _ => true
                    }
                }
            }
            if (let Some(td) <- typeDef) {
                result &&= match (td) {
                    case WithSubType(t) where bean.typeInfo.isSubtypeOf(TypeInfos.get(t)) =>
                        beanMatchedCount++
                        true
                    case WithoutSubType(t) where !bean.typeInfo.isSubtypeOf(TypeInfos.get(t)) => true
                    case OnlyOneSubType(t) where bean.typeInfo.isSubtypeOf(TypeInfos.get(t)) =>
                        beanMatchedCount++
                        if (nameMatchedCount > 1) {
                            false
                        } else {
                            true
                        }
                    case MultiSubType(t) where bean.typeInfo.isSubtypeOf(TypeInfos.get(t)) =>
                        beanMatchedCount++
                        true
                    case WithType(t) =>
                        let ti = try {
                            TypeInfos.get(t)
                        } catch (_) {
                            return false
                        }
                        if (bean.typeInfo == ti || bean.typeInfo.isSubtypeOf(ti)) {
                            beanMatchedCount++
                            true
                        } else {
                            false
                        }
                    case Missing(t) =>
                        let ti = try {
                            TypeInfos.get(t)
                        } catch (_) {
                            return true
                        }
                        if (bean.typeInfo == ti || bean.typeInfo.isSubtypeOf(ti)) {
                            beanMatchedCount++
                            false
                        } else {
                            true
                        }
                    case _ => false
                }
            }
            if (let Some(bd) <- beanDef) {
                result &&= match (bd) {
                    case Single => nameMatchedCount == 1 && beanMatchedCount == 1
                    case Multi => nameMatchedCount > 1 && beanMatchedCount > 1
                    case Missing => nameMatchedCount == 0 && beanMatchedCount == 0
                }
            }
            if (!result) {
                return false
            }
        }
        result
    }
}
