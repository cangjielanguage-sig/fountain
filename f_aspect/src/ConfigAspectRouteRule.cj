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
}