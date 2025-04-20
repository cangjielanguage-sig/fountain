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

private func getConfig(config: String): String {
    Config.getString(config).getOrThrow{AspectException('There is not a ${config} item.')}.trimAscii()
}
public class ConfigExecutionRouteRule <: RouteRule {
    private let config: String
    public const init(config: String){
        this.config = config
    }
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        let qualified = getConfig(config)
        let colon = qualified.lastIndexOf(':').getOrThrow{AspectException('${qualified} does not contain returnType')}
        let rparen = qualified.lastIndexOf(')', colon).getOrThrow{AspectException('${qualified} does not contain argTypes')}
        let lparen = qualified.lastIndexOf('(', rparen).getOrThrow{AspectException('${qualified} does not contain argTypes')}
        let lastDot = qualified.lastIndexOf('.', lparen).getOrThrow{AspectException('${qualified} does not contain qualifiedName or funcName')}
        let returnType = qualified[colon + 1 ..]
        let argTypes = qualified[lparen + 1 .. rparen]
        let funcName = qualified[lastDot + 1 .. lparen]
        let qualifiedName = qualified[0 .. lastDot]
        ExecutionRouteRule(qualifiedName, funcName, argTypes, returnType).matches(funcInfo)
    }
    public const operator func &(other: RouteRule): AndRouteRule {
        AndRouteRule(ConfigExecutionRouteRule(config), other)
    }
    public const operator func |(other: RouteRule): OrRouteRule {
        OrRouteRule(ConfigExecutionRouteRule(config), other)
    }
    public const operator func !(): NotRouteRule {
        NotRouteRule(ConfigExecutionRouteRule(config))
    }
}
public class ConfigWithinRouteRule <: RouteRule {
    private let config: String
    public const init(config: String){
        this.config = config
    }
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        let qualified = getConfig(config)
        WithinRouteRule(qualified).matches(funcInfo)
    }
    public const operator func &(other: RouteRule): AndRouteRule {
        AndRouteRule(ConfigWithinRouteRule(config), other)
    }
    public const operator func |(other: RouteRule): OrRouteRule {
        OrRouteRule(ConfigWithinRouteRule(config), other)
    }
    public const operator func !(): NotRouteRule {
        NotRouteRule(ConfigWithinRouteRule(config))
    }
}
public class ConfigArgsRouteRule <: RouteRule {
    private let config: String
    public const init(config: String){
        this.config = config
    }
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        let qualified = getConfig(config)
        ArgsRouteRule(qualified).matches(funcInfo)
    }
    public const operator func &(other: RouteRule): AndRouteRule {
        AndRouteRule(ConfigArgsRouteRule(config), other)
    }
    public const operator func |(other: RouteRule): OrRouteRule {
        OrRouteRule(ConfigArgsRouteRule(config), other)
    }
    public const operator func !(): NotRouteRule {
        NotRouteRule(ConfigArgsRouteRule(config))
    }
}
public class ConfigReturnTypeRouteRule <: RouteRule {
    private let config: String
    public const init(config: String){
        this.config = config
    }
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        let qualified = getConfig(config)
        ReturnTypeRouteRule(qualified).matches(funcInfo)
    }
    public const operator func &(other: RouteRule): AndRouteRule {
        AndRouteRule(ConfigReturnTypeRouteRule(config), other)
    }
    public const operator func |(other: RouteRule): OrRouteRule {
        OrRouteRule(ConfigReturnTypeRouteRule(config), other)
    }
    public const operator func !(): NotRouteRule {
        NotRouteRule(ConfigReturnTypeRouteRule(config))
    }
}
public class ConfigFuncTypeRouteRule <: RouteRule {
    private let config: String
    public const init(config: String){
        this.config = config
    }
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        let funcType = getConfig(config)
        let colon = funcType.lastIndexOf(':').getOrThrow{AspectException('${funcType} does not contain returnType')}
        let rparen = funcType.lastIndexOf(')', colon).getOrThrow{AspectException('${funcType} does not contain argTypes')}
        let lparen = funcType.lastIndexOf('(', rparen).getOrThrow{AspectException('${funcType} does not contain argTypes')}
        let returnType = funcType[colon + 1 ..]
        let argTypes = funcType[lparen + 1 .. rparen]
        FuncTypeRouteRule(argTypes, returnType).matches(funcInfo)
    }
    public const operator func &(other: RouteRule): AndRouteRule {
        AndRouteRule(ConfigFuncTypeRouteRule(config), other)
    }
    public const operator func |(other: RouteRule): OrRouteRule {
        OrRouteRule(ConfigFuncTypeRouteRule(config), other)
    }
    public const operator func !(): NotRouteRule {
        NotRouteRule(ConfigFuncTypeRouteRule(config))
    }
}
public class ConfigFuncNameRouteRule <: RouteRule {
    private let config: String
    public const init(config: String){
        this.config = config
    }
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        let name = getConfig(config)
        FuncNameRouteRule(name).matches(funcInfo)
    }
    public const operator func &(other: RouteRule): AndRouteRule {
        AndRouteRule(ConfigFuncNameRouteRule(config), other)
    }
    public const operator func |(other: RouteRule): OrRouteRule {
        OrRouteRule(ConfigFuncNameRouteRule(config), other)
    }
    public const operator func !(): NotRouteRule {
        NotRouteRule(ConfigFuncNameRouteRule(config))
    }
}
public class ConfigFuncRouteRule <: RouteRule {
    private let config: String
    public const init(config: String){
        this.config = config
    }
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        let funcDecl = getConfig(config)
        let colon = funcDecl.lastIndexOf(':').getOrThrow{AspectException('${funcDecl} does not contain returnType')}
        let rparen = funcDecl.lastIndexOf(')', colon).getOrThrow{AspectException('${funcDecl} does not contain argTypes')}
        let lparen = funcDecl.lastIndexOf('(', rparen).getOrThrow{AspectException('${funcDecl} does not contain argTypes')}
        let returnType = funcDecl[colon + 1 ..]
        let argTypes = funcDecl[lparen + 1 .. rparen]
        let funcName = funcDecl[0 .. lparen]
        FuncRouteRule(funcName, argTypes, returnType).matches(funcInfo)
    }
    public const operator func &(other: RouteRule): AndRouteRule {
        AndRouteRule(ConfigFuncRouteRule(config), other)
    }
    public const operator func |(other: RouteRule): OrRouteRule {
        OrRouteRule(ConfigFuncRouteRule(config), other)
    }
    public const operator func !(): NotRouteRule {
        NotRouteRule(ConfigFuncRouteRule(config))
    }
}
public class ConfigTargetRouteRule <: RouteRule {
    private let config: String
    public const init(config: String){
        this.config = config
    }
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        let qualified = getConfig(config)
        TargetRouteRule(qualified).matches(funcInfo)
    }
    public const operator func &(other: RouteRule): AndRouteRule {
        AndRouteRule(ConfigTargetRouteRule(config), other)
    }
    public const operator func |(other: RouteRule): OrRouteRule {
        OrRouteRule(ConfigTargetRouteRule(config), other)
    }
    public const operator func !(): NotRouteRule {
        NotRouteRule(ConfigTargetRouteRule(config))
    }
}
public class ConfigTargetAnnotationRouteRule <: RouteRule {
    private let config: String
    public const init(config: String){
        this.config = config
    }
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        let annotationTypes = getConfig(config)
        if(annotationTypes.startsWith('<:')){
            TargetAnnotationRouteRule(annotationTypes[2 ..], sub: true)
        }else{
            TargetAnnotationRouteRule(annotationTypes, sub: false)
        }.matches(funcInfo)
    }
    public const operator func &(other: RouteRule): AndRouteRule {
        AndRouteRule(ConfigTargetAnnotationRouteRule(config), other)
    }
    public const operator func |(other: RouteRule): OrRouteRule {
        OrRouteRule(ConfigTargetAnnotationRouteRule(config), other)
    }
    public const operator func !(): NotRouteRule {
        NotRouteRule(ConfigTargetAnnotationRouteRule(config))
    }
}
public class ConfigFuncAnnotationRouteRule <: RouteRule {
    private let config: String
    public const init(config: String){
        this.config = config
    }
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        let annotationTypes = getConfig(config)
        if(annotationTypes.startsWith('<:')){
            FuncAnnotationRouteRule(annotationTypes[2 ..], sub: true)
        }else{
            FuncAnnotationRouteRule(annotationTypes, sub: false)
        }.matches(funcInfo)
    }
    public const operator func &(other: RouteRule): AndRouteRule {
        AndRouteRule(ConfigFuncAnnotationRouteRule(config), other)
    }
    public const operator func |(other: RouteRule): OrRouteRule {
        OrRouteRule(ConfigFuncAnnotationRouteRule(config), other)
    }
    public const operator func !(): NotRouteRule {
        NotRouteRule(ConfigFuncAnnotationRouteRule(config))
    }
}
public class ConfigArgAnnotationsRouteRule <: RouteRule {
    private let config: String
    public const init(config: String){
        this.config = config
    }
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        let annotationTypes = getConfig(config)
        ArgAnnotationsRouteRule(annotationTypes).matches(funcInfo)
    }
    public const operator func &(other: RouteRule): AndRouteRule {
        AndRouteRule(ConfigArgAnnotationsRouteRule(config), other)
    }
    public const operator func |(other: RouteRule): OrRouteRule {
        OrRouteRule(ConfigArgAnnotationsRouteRule(config), other)
    }
    public const operator func !(): NotRouteRule {
        NotRouteRule(ConfigArgAnnotationsRouteRule(config))
    }
}
public class ConfigAnyArgAnnotationsRouteRule <: RouteRule {
    private let config: String
    public const init(config: String){
        this.config = config
    }
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        let annotationTypes = getConfig(config)
        AnyArgAnnotationsRouteRule(annotationTypes).matches(funcInfo)
    }
    public const operator func &(other: RouteRule): AndRouteRule {
        AndRouteRule(ConfigAnyArgAnnotationsRouteRule(config), other)
    }
    public const operator func |(other: RouteRule): OrRouteRule {
        OrRouteRule(ConfigAnyArgAnnotationsRouteRule(config), other)
    }
    public const operator func !(): NotRouteRule {
        NotRouteRule(ConfigAnyArgAnnotationsRouteRule(config))
    }
}
public class ConfigArgPrefixAnnotationsRouteRule <: RouteRule {
    private let config: String
    public const init(config: String){
        this.config = config
    }
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        let annotationTypes = getConfig(config)
        ArgPrefixAnnotationsRouteRule(annotationTypes).matches(funcInfo)
    }
    public const operator func &(other: RouteRule): AndRouteRule {
        AndRouteRule(ConfigArgPrefixAnnotationsRouteRule(config), other)
    }
    public const operator func |(other: RouteRule): OrRouteRule {
        OrRouteRule(ConfigArgPrefixAnnotationsRouteRule(config), other)
    }
    public const operator func !(): NotRouteRule {
        NotRouteRule(ConfigArgPrefixAnnotationsRouteRule(config))
    }
}
public class ConfigArgSuffixAnnotationsRouteRule <: RouteRule {
    private let config: String
    public const init(config: String){
        this.config = config
    }
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        let annotationTypes = getConfig(config)
        ArgSuffixAnnotationsRouteRule(annotationTypes).matches(funcInfo)
    }
    public const operator func &(other: RouteRule): AndRouteRule {
        AndRouteRule(ConfigArgSuffixAnnotationsRouteRule(config), other)
    }
    public const operator func |(other: RouteRule): OrRouteRule {
        OrRouteRule(ConfigArgSuffixAnnotationsRouteRule(config), other)
    }
    public const operator func !(): NotRouteRule {
        NotRouteRule(ConfigArgSuffixAnnotationsRouteRule(config))
    }
}
public class ConfigBeanNameRouteRule <: RouteRule {
    private let config: String
    public const init(config: String){
        this.config = config
    }
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        let beanName = getConfig(config)
        BeanNameRouteRule(beanName).matches(funcInfo)
    }
    public const operator func &(other: RouteRule): AndRouteRule {
        AndRouteRule(ConfigBeanNameRouteRule(config), other)
    }
    public const operator func |(other: RouteRule): OrRouteRule {
        OrRouteRule(ConfigBeanNameRouteRule(config), other)
    }
    public const operator func !(): NotRouteRule {
        NotRouteRule(ConfigBeanNameRouteRule(config))
    }
}