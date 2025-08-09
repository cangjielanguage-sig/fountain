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
package f_aspect

/**
 * 拥有已经实现过的全部RouteRule，只是初始化参数是配置项
 */
private func getConfig(config: String): String {
    Config.getString(config).getOrThrow {AspectException('There is not a ${config} item.')}.trimAscii()
}

public class ConfigExecutionRouteRule <: RouteRule {
    private let config: String
    public const init(config: String) {
        this.config = config
    }
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        let qualified = getConfig(config)
        let colon = qualified.lastIndexOf(':').getOrThrow {AspectException('${qualified} does not contain returnType')}
        let rparen = qualified
            .lastIndexOf(')', colon)
            .getOrThrow {AspectException('${qualified} does not contain argTypes')}
        let lparen = qualified
            .lastIndexOf('(', rparen)
            .getOrThrow {AspectException('${qualified} does not contain argTypes')}
        let lastDot = qualified
            .lastIndexOf('.', lparen)
            .getOrThrow {AspectException('${qualified} does not contain qualifiedName or funcName')}
        let returnType = qualified[colon + 1..]
        let argTypes = qualified[lparen + 1..rparen]
        let funcName = qualified[lastDot + 1..lparen]
        let qualifiedName = qualified[0..lastDot]
        ExecutionRouteRule(qualifiedName, funcName, argTypes, returnType).matches(funcInfo)
    }
}

public class ConfigWithinRouteRule <: RouteRule {
    private let config: String
    public const init(config: String) {
        this.config = config
    }
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        let qualified = getConfig(config)
        WithinRouteRule(qualified).matches(funcInfo)
    }
}

public class ConfigArgsRouteRule <: RouteRule {
    private let config: String
    public const init(config: String) {
        this.config = config
    }
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        let qualified = getConfig(config)
        ArgsRouteRule(qualified).matches(funcInfo)
    }
}

public class ConfigReturnTypeRouteRule <: RouteRule {
    private let config: String
    public const init(config: String) {
        this.config = config
    }
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        let qualified = getConfig(config)
        ReturnTypeRouteRule(qualified).matches(funcInfo)
    }
}

public class ConfigFuncTypeRouteRule <: RouteRule {
    private let config: String
    public const init(config: String) {
        this.config = config
    }
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        let funcType = getConfig(config)
        let colon = funcType.lastIndexOf(':').getOrThrow {AspectException('${funcType} does not contain returnType')}
        let rparen = funcType
            .lastIndexOf(')', colon)
            .getOrThrow {AspectException('${funcType} does not contain argTypes')}
        let lparen = funcType
            .lastIndexOf('(', rparen)
            .getOrThrow {AspectException('${funcType} does not contain argTypes')}
        let returnType = funcType[colon + 1..]
        let argTypes = funcType[lparen + 1..rparen]
        FuncTypeRouteRule(argTypes, returnType).matches(funcInfo)
    }
}

public class ConfigFuncNameRouteRule <: RouteRule {
    private let config: String
    public const init(config: String) {
        this.config = config
    }
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        let name = getConfig(config)
        FuncNameRouteRule(name).matches(funcInfo)
    }
}

public class ConfigFuncRouteRule <: RouteRule {
    private let config: String
    public const init(config: String) {
        this.config = config
    }
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        let funcDecl = getConfig(config)
        let colon = funcDecl.lastIndexOf(':').getOrThrow {AspectException('${funcDecl} does not contain returnType')}
        let rparen = funcDecl
            .lastIndexOf(')', colon)
            .getOrThrow {AspectException('${funcDecl} does not contain argTypes')}
        let lparen = funcDecl
            .lastIndexOf('(', rparen)
            .getOrThrow {AspectException('${funcDecl} does not contain argTypes')}
        let returnType = funcDecl[colon + 1..]
        let argTypes = funcDecl[lparen + 1..rparen]
        let funcName = funcDecl[0..lparen]
        FuncRouteRule(funcName, argTypes, returnType).matches(funcInfo)
    }
}

public class ConfigTargetRouteRule <: RouteRule {
    private let config: String
    public const init(config: String) {
        this.config = config
    }
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        let qualified = getConfig(config)
        TargetRouteRule(qualified).matches(funcInfo)
    }
}

public class ConfigTargetAnnotationRouteRule <: RouteRule {
    private let config: String
    public const init(config: String) {
        this.config = config
    }
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        let annotationTypes = getConfig(config)
        if (annotationTypes
            .startsWith('<:')) {
                TargetAnnotationRouteRule(annotationTypes[2..], sub: true)
            } else {
                TargetAnnotationRouteRule(annotationTypes, sub: false)
            }
            .matches(funcInfo)
    }
}

public class ConfigFuncAnnotationRouteRule <: RouteRule {
    private let config: String
    public const init(config: String) {
        this.config = config
    }
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        let annotationTypes = getConfig(config)
        if (annotationTypes
            .startsWith('<:')) {
                FuncAnnotationRouteRule(annotationTypes[2..], sub: true)
            } else {
                FuncAnnotationRouteRule(annotationTypes, sub: false)
            }
            .matches(funcInfo)
    }
}

public class ConfigArgAnnotationsRouteRule <: RouteRule {
    private let config: String
    public const init(config: String) {
        this.config = config
    }
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        let annotationTypes = getConfig(config)
        ArgAnnotationsRouteRule(annotationTypes).matches(funcInfo)
    }
}

public class ConfigAnyArgAnnotationsRouteRule <: RouteRule {
    private let config: String
    public const init(config: String) {
        this.config = config
    }
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        let annotationTypes = getConfig(config)
        AnyArgAnnotationsRouteRule(annotationTypes).matches(funcInfo)
    }
}

public class ConfigArgPrefixAnnotationsRouteRule <: RouteRule {
    private let config: String
    public const init(config: String) {
        this.config = config
    }
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        let annotationTypes = getConfig(config)
        ArgPrefixAnnotationsRouteRule(annotationTypes).matches(funcInfo)
    }
}

public class ConfigArgSuffixAnnotationsRouteRule <: RouteRule {
    private let config: String
    public const init(config: String) {
        this.config = config
    }
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        let annotationTypes = getConfig(config)
        ArgSuffixAnnotationsRouteRule(annotationTypes).matches(funcInfo)
    }
}

public class ConfigBeanNameRouteRule <: RouteRule {
    private let config: String
    public const init(config: String) {
        this.config = config
    }
    public func matches(funcInfo: InvocationFuncInfo): Bool {
        let beanName = getConfig(config)
        BeanNameRouteRule(beanName).matches(funcInfo)
    }
}
