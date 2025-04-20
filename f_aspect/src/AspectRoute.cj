/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_aspect

public import std.reflect.*
import f_base.*
import f_aspect.exception.AspectException
import f_regex.*

/**
 * 用来修饰切面也就是Aspect的实现类
 */
@Annotation[target: [Type]]
public class AspectRoute <: RouteRule {
    public const AspectRoute(public let route: RouteRule) {}
    public func isAspect<T>(): Bool {
        TypeInfos.get<T>().isSubtypeOf(TypeInfos.get<Aspect>())
    }
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        route.matches(funcInfo)
    }
}
/**
 * 以下所有规则除非特别说明都适用本注释的说明。
 * 任意参数都可以用通配符*表示任意大于等于0个字符，?表示0或1个字符
 * packageName参数是包名，
 * - .*、*.、.*. 表示任意包名
 * - .. 表示任意级别的包名
 * typeName参数是类型名，
 * argTypes参数是参数全限定名，多个参数之间用,分割，不适用通配符
 * returnType参数是返回类型全限定名，不适用通配符
 * 类型全限定名不支持反射尚不支持的类型
*/
sealed interface RouteRule {
    func matches(funcInfo: InvocationFuncInfo): Bool
    const operator func &(right: RouteRule): AndRouteRule{
        AndRouteRule(DummyRouteRule.instance, DummyRouteRule.instance)
    }
    const operator func |(right: RouteRule): OrRouteRule{
        OrRouteRule(DummyRouteRule.instance, DummyRouteRule.instance)
    }
    const operator func !(): NotRouteRule {
        NotRouteRule(DummyRouteRule.instance)
    }
}
private class DummyRouteRule <: RouteRule {
    private const init(){}
    static const instance = DummyRouteRule()
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        true
    }
}
/**
 * 匹配的公共实例函数将被织入
 */
public class ExecutionRouteRule <: AbstractAndRouteRule & RouteRule {
    public const ExecutionRouteRule(
        private let within: WithinRouteRule,
        private let funcType: FuncRouteRule
    ){
        super(within, funcType)
    }
    public const init(qualifiedName: String,
                      funcName: String,
                      argTypes: String,
                      returnType: String){
        this(WithinRouteRule(qualifiedName), FuncRouteRule(funcName, argTypes, returnType))
    }
    public const operator func &(other: RouteRule): AndRouteRule {
        AndRouteRule(ExecutionRouteRule(within, funcType), other)
    }
    public const operator func |(other: RouteRule): OrRouteRule {
        OrRouteRule(ExecutionRouteRule(within, funcType), other)
    }
    public const operator func !(): NotRouteRule {
        NotRouteRule(ExecutionRouteRule(within, funcType))
    }
}
/**
 * 类型包名匹配packageName，类型名匹配typeName的全部类型将会匹配，匹配的类型全部公共实例函数将被织入，
 */
public class WithinRouteRule <: RouteRule {
    public const WithinRouteRule(
        public let qualifiedName: String
    ){}
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        Regex.wildcard(qualifiedName).matched(funcInfo.typeInfo.qualifiedName)
    }
    public const operator func &(other: RouteRule): AndRouteRule {
        AndRouteRule(WithinRouteRule(qualifiedName), other)
    }
    public const operator func |(other: RouteRule): OrRouteRule {
        OrRouteRule(WithinRouteRule(qualifiedName), other)
    }
    public const operator func !(): NotRouteRule {
        NotRouteRule(WithinRouteRule(qualifiedName))
    }
}
/**
 * 因为切面修改以后的参数必须是原函数参数的子类型，原函数才能接收切面的修改，
 * 所以参数匹配argTypes的全部公共实例函数将被织入。
 * 多个参数使用,分割，*,表示忽略第一个参数，,*,表示忽略中间某个参数，,*表示忽略最后一个参数
 */
public class ArgsRouteRule <: RouteRule {
    public const ArgsRouteRule(
        public let argTypes: String
    ){}
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        let types = argTypes.split(',')
        let params = funcInfo.funcInfo.parameters
        for(i in 0 .. params.size where !TypeInfos.get(types[i]).isSubtypeOf(params[i].typeInfo)){
            return false
        }
        true
    }
    public const operator func &(other: RouteRule): AndRouteRule {
        AndRouteRule(ArgsRouteRule(argTypes), other)
    }
    public const operator func |(other: RouteRule): OrRouteRule {
        OrRouteRule(ArgsRouteRule(argTypes), other)
    }
    public const operator func !(): NotRouteRule {
        NotRouteRule(ArgsRouteRule(argTypes))
    }
}
/**
 * 因为切面修改以后的返回类型必须是原函数返回类型的子类型，才能按原函数的返回类型返回，
 * 所以returnType是目标函数返回类型的子类型将被织入，returnType是一个类型全限定名
 */
public class ReturnTypeRouteRule <: RouteRule{
    public const ReturnTypeRouteRule(
        public let returnType: String
    ){}
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        TypeInfos.get(returnType).isSubtypeOf(funcInfo.funcInfo.returnType)
    }
    public const operator func &(other: RouteRule): AndRouteRule {
        AndRouteRule(ReturnTypeRouteRule(returnType), other)
    }
    public const operator func |(other: RouteRule): OrRouteRule {
        OrRouteRule(ReturnTypeRouteRule(returnType), other)
    }
    public const operator func !(): NotRouteRule {
        NotRouteRule(ReturnTypeRouteRule(returnType))
    }
}
/**
 * 参数和返回类型匹配的全部公共实例函数将被织入
 */
public class FuncTypeRouteRule <: AbstractAndRouteRule & RouteRule {
    public const FuncTypeRouteRule(
        private let argTypes: ArgsRouteRule,
        private let returnType: ReturnTypeRouteRule
    ){
        super(argTypes, returnType)
    }
    public const init(argTypes: String, returnType: String){
        this(ArgsRouteRule(argTypes), ReturnTypeRouteRule(returnType))
    }
    public const operator func &(other: RouteRule): AndRouteRule {
        AndRouteRule(FuncTypeRouteRule(argTypes, returnType), other)
    }
    public const operator func |(other: RouteRule): OrRouteRule {
        OrRouteRule(FuncTypeRouteRule(argTypes, returnType), other)
    }
    public const operator func !(): NotRouteRule {
        NotRouteRule(FuncTypeRouteRule(argTypes, returnType))
    }
}
public class FuncNameRouteRule <: RouteRule {
    public const FuncNameRouteRule(public let name: String){}
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        Regex.wildcard(name).matched(funcInfo.funcInfo.name)
    }
    public const operator func &(other: RouteRule): AndRouteRule {
        AndRouteRule(FuncNameRouteRule(name), other)
    }
    public const operator func |(other: RouteRule): OrRouteRule {
        OrRouteRule(FuncNameRouteRule(name), other)
    }
    public const operator func !(): NotRouteRule {
        NotRouteRule(FuncNameRouteRule(name))
    }
}
public class FuncRouteRule <: AbstractAndRouteRule & RouteRule{
    public const FuncRouteRule(
        private let name: FuncNameRouteRule,
        private let funcType: FuncTypeRouteRule
    ){
        super(name, funcType)
    }
    public const init(name: String, argTypes: String, returnType: String){
        this(FuncNameRouteRule(name), FuncTypeRouteRule(argTypes, returnType))
    }
    public const operator func &(other: RouteRule): AndRouteRule {
        AndRouteRule(FuncRouteRule(name, funcType), other)
    }
    public const operator func |(other: RouteRule): OrRouteRule {
        OrRouteRule(FuncRouteRule(name, funcType), other)
    }
    public const operator func !(): NotRouteRule {
        NotRouteRule(FuncRouteRule(name, funcType))
    }
}
/**
 * 参数是一个类型全限定名，这个类型及它的子类型全部公共实例函数将被织入
 */
public class TargetRouteRule <: RouteRule {
    public const TargetRouteRule(
        public let targetQualifiedName: String
    ){}
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        funcInfo.typeInfo.isSubtypeOf(TypeInfos.get(targetQualifiedName))
    }
    public const operator func &(other: RouteRule): AndRouteRule {
        AndRouteRule(TargetRouteRule(targetQualifiedName), other)
    }
    public const operator func |(other: RouteRule): OrRouteRule {
        OrRouteRule(TargetRouteRule(targetQualifiedName), other)
    }
    public const operator func !(): NotRouteRule {
        NotRouteRule(TargetRouteRule(targetQualifiedName))
    }
}
private func contains(annotations: Collection<Annotation>, annotationNames: Array<String>, sub!: Bool = false){
    if(sub){
        let list = ArrayList<TypeInfo>()
        let supers = ArrayList<TypeInfo>()
        for(annotation in annotations){
            list.add(TypeInfo.of(annotation))
        }
        for(name in annotationNames){
            supers.add(TypeInfos.get(name.trimAscii()))
        }
        for(superType in supers){
            var matched = false
            for(annotationType in list where annotationType.isSubtypeOf(superType)){
                matched = true
                break
            }
            if(!matched){
                return false
            }
        }
        true
    }else{
        let set = HashSet<String>()
        for(annotation in annotations){
            set.add(TypeInfo.of(annotation).qualifiedName)
        }
        for(name in annotationNames where !set.contains(name.trimAscii())){
            return false
        }
        true
    }
}
/**
 * 如果目标类型有指定类型的注解则目标类型的全部公共实例函数将被织入，本规则不适用通配符
 * 参数是注解类型的全限定名，多个注解类名用&分割，每个注解类型都要能够跟目标类型的注解匹配到才返回true。
 * sub是true时，要求目标类型的注解是指定注解的子类型，否则要求指定的注解全限定名是目标类型注解全限定名的子集。
 */
public class TargetAnnotationRouteRule <: RouteRule {
    public const TargetAnnotationRouteRule(
        public let annotationTypes: String,
        public let sub!: Bool = false
    ){}
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        let annotationNames = annotationTypes.split('&')
        contains(funcInfo.funcInfo.annotations, annotationNames, sub: sub)
    }
    public const operator func &(other: RouteRule): AndRouteRule {
        AndRouteRule(TargetAnnotationRouteRule(annotationTypes, sub: sub), other)
    }
    public const operator func |(other: RouteRule): OrRouteRule {
        OrRouteRule(TargetAnnotationRouteRule(annotationTypes, sub: sub), other)
    }
    public const operator func !(): NotRouteRule {
        NotRouteRule(TargetAnnotationRouteRule(annotationTypes, sub: sub))
    }
}
/**
 * 目标函数有指定类型的注解将被织入，本规则不适用通配符
 * 参数是注解类型的全限定名，多个注解类名用&分割，每个注解类型都要能够跟目标函数的注解匹配到才返回true。
 * sub是true时，要求目标函数的注解是指定注解的子类型，否则要求指定的注解的全限定名是目标函数注解全限定名的子集。
 */
public class FuncAnnotationRouteRule <: RouteRule {
    public const FuncAnnotationRouteRule(
        public let annotationTypes: String,
        public let sub!: Bool = false
    ){}
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        let annotationNames = annotationTypes.split('&')
        contains(funcInfo.funcInfo.annotations, annotationNames, sub: sub)
    }
    public const operator func &(other: RouteRule): AndRouteRule {
        AndRouteRule(FuncAnnotationRouteRule(annotationTypes, sub: sub), other)
    }
    public const operator func |(other: RouteRule): OrRouteRule {
        OrRouteRule(FuncAnnotationRouteRule(annotationTypes, sub: sub), other)
    }
    public const operator func !(): NotRouteRule {
        NotRouteRule(FuncAnnotationRouteRule(annotationTypes, sub: sub))
    }
}
/**
 * 目标函数参数都有指定类型注解将被织入，本规则不适用通配符
 * 参数是注解类型的全限定名，多个注解类型用&分割，每个注解类型依次对应一个参数。
 * 忽略某个参数的注解需要使用*占位，
 * 比如*,a.b.c.AnnotationType表示目标函数有两个参数，忽略第一个参数的注解，第二个参数必须有a.b.c.AnnotationType注解
 * a.Annotation1,*,b.Annotation2表示目标函数有三个参数，忽略第二个参数的注解，第一第三个参数必须有a.Annotation1和b.Annotation2
 */
public class ArgAnnotationsRouteRule <: RouteRule {
    public const ArgAnnotationsRouteRule(
        public let annotationTypes: String
    ){}
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        let params = funcInfo.funcInfo.parameters
        let annotationNames = annotationTypes.split('&')
        for(i in 0 .. params.size){
            let param = params[i]
            let annotationName = annotationNames[i].trimAscii()
            if(annotationName == '*'){
                continue
            }
            for(annotation in param.annotations where TypeInfo.of(annotation).qualifiedName == annotationName){
                continue
            }
            return false
        }
        true
    }
    public const operator func &(other: RouteRule): AndRouteRule {
        AndRouteRule(ArgAnnotationsRouteRule(annotationTypes), other)
    }
    public const operator func |(other: RouteRule): OrRouteRule {
        OrRouteRule(ArgAnnotationsRouteRule(annotationTypes), other)
    }
    public const operator func !(): NotRouteRule {
        NotRouteRule(ArgAnnotationsRouteRule(annotationTypes))
    }
}
/**
 * 目标函数任意一个参数拥有指定的全部注解将被织入，本规则不适用通配符，多个注解用,分割
 */
public class AnyArgAnnotationsRouteRule <: RouteRule {
    public const AnyArgAnnotationsRouteRule(
        public let annotationTypes: String
    ){}
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        let params = funcInfo.funcInfo.parameters
        let annotationNames = annotationTypes.split(',')
        for(param in params where contains(param.annotations, annotationNames)){
            return true
        }
        false
    }
    public const operator func &(other: RouteRule): AndRouteRule {
        AndRouteRule(AnyArgAnnotationsRouteRule(annotationTypes), other)
    }
    public const operator func |(other: RouteRule): OrRouteRule {
        OrRouteRule(AnyArgAnnotationsRouteRule(annotationTypes), other)
    }
    public const operator func !(): NotRouteRule {
        NotRouteRule(AnyArgAnnotationsRouteRule(annotationTypes))
    }
}
private func matches(asc: Bool, funcInfo: InvocationFuncInfo, annotationTypes: String){
    let annotations = annotationTypes.split(',')
    let params = funcInfo.funcInfo.parameters
    let range = if(asc){
        0 .. params.size
    }else{
        params.size - 1 ..= 0
    }
    for(i in range){
        let current = annotations[i]
        var matched = false
        for(annotation in params[i].annotations where TypeInfo.of(annotation).qualifiedName == current){
            matched = true
            break
        }
        if(!matched){
            return false
        }
    }
    true
}
/**
 * 目标函数开头的每个参数拥有指定注解将被织入，本规则不适用通配符，多个注解用,分割
 * 比如a.Annotation1,b.Annotation2 匹配下面的test1和test2
 * public func test1(@Annotation1 a: String, @Annotation2 b: String){}
 * public func test2(@Annotation1 a: String, @Annotation2 b: String, c: String){}
 * public func test3(@Annotation1 a: String, c: String, @Annotation2 b: String){}
 */
public class ArgPrefixAnnotationsRouteRule <: RouteRule {
    public const ArgPrefixAnnotationsRouteRule(
        public let annotationTypes: String
    ){}
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        matches(true, funcInfo, annotationTypes)
    }
    public const operator func &(other: RouteRule): AndRouteRule {
        AndRouteRule(ArgPrefixAnnotationsRouteRule(annotationTypes), other)
    }
    public const operator func |(other: RouteRule): OrRouteRule {
        OrRouteRule(ArgPrefixAnnotationsRouteRule(annotationTypes), other)
    }
    public const operator func !(): NotRouteRule {
        NotRouteRule(ArgPrefixAnnotationsRouteRule(annotationTypes))
    }
}
/**
 * 目标函数结尾的每个参数拥有指定注解将被织入，本规则不适用通配符，多个注解用,分割
 * 比如a.Annotation1,b.Annotation2 匹配下面的test1和test2
 * public func test1(@Annotation1 a: String, @Annotation2 b: String){}
 * public func test2(c: String, @Annotation1 a: String, @Annotation2 b: String){}
 * public func test3(@Annotation1 a: String, c: String, @Annotation2 b: String){}
 */
public class ArgSuffixAnnotationsRouteRule <: RouteRule {
    public const ArgSuffixAnnotationsRouteRule(
        public let annotationTypes: String
    ){}
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        matches(false, funcInfo, annotationTypes)
    }
    public const operator func &(other: RouteRule): AndRouteRule {
        AndRouteRule(ArgSuffixAnnotationsRouteRule(annotationTypes), other)
    }
    public const operator func |(other: RouteRule): OrRouteRule {
        OrRouteRule(ArgSuffixAnnotationsRouteRule(annotationTypes), other)
    }
    public const operator func !(): NotRouteRule {
        NotRouteRule(ArgSuffixAnnotationsRouteRule(annotationTypes))
    }
}
/**
 * 目标对象的beanName符合本规则，目标的全部公共实例函数将被织入
 */
public class BeanNameRouteRule <: RouteRule {
    public const BeanNameRouteRule(
        public let beanName: String
    ) {}
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        let managers = BeanFactory.instance.iterator<Object>(funcInfo.typeInfo)
        let regex = Regex.wildcard(beanName)
        for(m in managers where regex.matched(m.name) && m.beanType == funcInfo.typeInfo){
            return true
        }
        false
    }
    public const operator func &(other: RouteRule): AndRouteRule {
        AndRouteRule(BeanNameRouteRule(beanName), other)
    }
    public const operator func |(other: RouteRule): OrRouteRule {
        OrRouteRule(BeanNameRouteRule(beanName), other)
    }
    public const operator func !(): NotRouteRule {
        NotRouteRule(BeanNameRouteRule(beanName))
    }
}
abstract sealed class AbstractAndRouteRule {
    const AbstractAndRouteRule(public let left: RouteRule, public let right: RouteRule){}
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        left.matches(funcInfo) && right.matches(funcInfo)
    }
}
/**
 * 两个规则都匹配的公共实例函数将被织入
 */
public open class AndRouteRule <: AbstractAndRouteRule & RouteRule {
    public const AndRouteRule(private let _left: RouteRule, private let _right: RouteRule){
        super(_left, _right)
    }
    
    public const operator func &(other: RouteRule): AndRouteRule {
        AndRouteRule(AndRouteRule(_left, _right), other)
    }
    public const operator func |(other: RouteRule): OrRouteRule {
        OrRouteRule(AndRouteRule(_left, _right), other)
    }
    public const operator func !(): NotRouteRule {
        NotRouteRule(AndRouteRule(_left, _right))
    }
}
/**
 * 匹配任意一个规则的公共实例函数将被织入
 */
public class OrRouteRule <: RouteRule {
    public const OrRouteRule(public let left: RouteRule, public let right: RouteRule){}
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        left.matches(funcInfo) || right.matches(funcInfo)
    }
    public const operator func &(other: RouteRule): AndRouteRule {
        AndRouteRule(OrRouteRule(left, right), other)
    }
    public const operator func |(other: RouteRule): OrRouteRule {
        OrRouteRule(OrRouteRule(left, right), other)
    }
    public const operator func !(): NotRouteRule {
        NotRouteRule(OrRouteRule(left, right))
    }
}
/**
 * 对指定规则匹配结果取反。
 */
public class NotRouteRule <: RouteRule {
    public const NotRouteRule(public let rule: RouteRule){}
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        !rule.matches(funcInfo)
    }
    public const operator func &(other: RouteRule): AndRouteRule {
        AndRouteRule(NotRouteRule(rule), other)
    }
    public const operator func |(other: RouteRule): OrRouteRule {
        OrRouteRule(NotRouteRule(rule), other)
    }
    public const operator func !(): NotRouteRule {
        NotRouteRule(NotRouteRule(rule))
    }
}
