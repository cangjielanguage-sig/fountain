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

/**
 * bean定义有指定数量时为true
 */
public enum BeanDefCount {
    /**
     * 没有bean定义
     */
    | Zero
    /**
     * 只有一个bean定义
     */
    | OnlyOne
    /**
     * 至少有一个bean定义
     */
    | AtLeastOne
    /**
     * 多于一个bean定义
     */
    | MoreThanOne
}
public enum BeanType{
    /**
     * 不判断bean类型
     */
    | IgnoreType
    /**
     * bean定义的类型必须是指定类型
     */
    | Current(String)
    /**
     * bean定义的类型是指定类型或指定类型的后代类型
     */
    | CurrentOrSubOf(String)
    /**
     * bean定义的类型必须是指定类型的后代类型
     */
    | SubOfOnly(String)
    /**
     * bean定义的类型必须是指定类型或指定类型的祖先类型
     */
    | CurrentOrSuperOf(String)
    /**
     * bean定义的类型必须是指定类型的祖先类型
     */
    | SuperOfOnly(String)
    public func on(beanType: TypeInfo){
        match(this){
            case IgnoreType => true
            case Current(t) => TypeInfos.get(t) == beanType
            case CurrentOrSubOf(t) => 
                let ti = TypeInfos.get(t)
                ti == beanType || beanType.isSubtypeOf(ti)
            case SubOfOnly(t) => beanType.isSubtypeOf(TypeInfos.get(t))
            case CurrentOrSuperOf(t) => 
                let ti = TypeInfos.get(t)
                ti == beanType || ti.isSubtypeOf(beanType)
            case SuperOfOnly(t) => TypeInfos.get(t).isSubtypeOf(beanType)
        }
    }
}

/**
 * beanType是全限定类型名，指定类型有bean定义则on返回true
 */
public class BeanDef <: BeanCondition {
    public const BeanDef(public let beanType!: BeanType = IgnoreType, 
                      public let beanName!: StringCond = IgnoreCond,
                      public let count!: BeanDefCount = AtLeastOne,
                      public let scope!: ?BeanScope = None){}
    public func on(factory: BeanFactory): Bool {
        match((beanType, beanName)){
            case (IgnoreType, IgnoreName) => return true//相当于没有指定bean初始化条件
            case (CurrentOrSubOf(t), _) => on(factory, TypeInfos.get(t))
            case (Current(t), _) => on(factory, TypeInfos.get(t))
            case (SubOfOnly(t), _) =>on(factory, TypeInfos.get(t))
            case _ => on(factory, TypeInfos.get<Object>())
        }
    }
    private func on(factory: BeanFactory, typeInfo: TypeInfo): Bool {
        var count = 0
        for(m in factory.beanManagers(typeInfo) 
            where beanType.on(m.beanType) && beanName.on(m.name) && 
                 (scope.isNone() || scope.getOrThrow() == m.meta.scope)){
            count++
            match(this.count){
                case AtLeastOne => return true
                case MoreThanOne where count > 1 => return true
                case OnlyOne where count > 1 => return false
                case Zero => return false 
                case _ => continue
            }
        }
        match(this.count){
            case AtLeastOne => count > 0
            case MoreThanOne => count > 1
            case OnlyOne => count == 1
            case Zero => count == 0
        }
    }
}