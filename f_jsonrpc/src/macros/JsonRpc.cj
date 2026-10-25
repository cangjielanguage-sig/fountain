/*
Copyright (c) 2026 WuJingrun（吴京润）

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
macro package fountain::f_jsonrpc.macros

internal import std.ast.*
internal import std.collection.HashSet
internal import fountain::f_macros.*

/**
 * `@JsonRpc[namespace: knowledge]`：把类里的每个 public 实例方法注册成一个 JSON-RPC 方法。
 *
 * 展开结果：
 * - 类上加 `@Bean`
 * - 每个方法一段 `private let _ = {=> ... }()`，在加载期调用 `JsonRpcRegistry.register`
 * - 方法名是 `<namespace>.<fnName>`；没有 namespace 时就是 `<fnName>`
 * - 描述与超时从运行期反射的 `@JsonRpcMeta` 读取
 */
public macro JsonRpc(input: Tokens): Tokens {
    expand('', input)
}

public macro JsonRpc(attr: Tokens, input: Tokens): Tokens {
    expand(namespaceOf(attr), input)
}

private func namespaceOf(attr: Tokens): String {
    var i = 0
    while (i < attr.size) {
        if (attr[i].kind == IDENTIFIER && attr[i].value == 'namespace') {
            if (i + 2 < attr.size && attr[i + 1].kind == COLON) {
                return attr[i + 2].value
            }
            diagReport(ERROR, attr, "expect @JsonRpc[namespace: <name>]", '')
            return ''
        }
        i++
    }
    if (attr.size > 0) {
        // 旧写法 `@JsonRpc[topic: ...]` 也会走到这里：直接报错，避免静默丢掉命名空间。
        diagReport(ERROR, attr, "expect @JsonRpc[namespace: <name>]", '')
    }
    ''
}

private func expand(ns: String, input: Tokens): Tokens {
    let (decl, _) = extractFirstDecl(input)
    let klass = match (decl) {
        case c: ClassDecl => c
        case m: MacroExpandDecl => match (extract(m)) {
            case c: ClassDecl => c
            case _ =>
                diagReport(ERROR, input.toTokens(), '@JsonRpc modify class decl only', '')
                return input.toTokens()
        }
        case _ =>
            diagReport(ERROR, input.toTokens(), '@JsonRpc modify class decl only', '')
            return input.toTokens()
    }
    let klassName = klass.identifier.value
    var registrations = quote()
    let seen = HashSet<String>()
    for (item in klass.body.decls) {
        match (asFunc(item)) {
            case Some(f) =>
                if (isPublic(f) && !isStatic(f) && f.identifier.value != 'init') {
                    let fullName = if (ns.isEmpty()) {
                        f.identifier.value
                    } else {
                        '${ns}.${f.identifier.value}'
                    }
                    if (seen.contains(fullName)) {
                        diagReport(ERROR, f.identifier.toTokens(),
                            "duplicate json-rpc method '${fullName}': overloaded public methods need distinct names", '')
                    } else {
                        seen.add(fullName)
                        registrations += generateMethod(ns, klassName, f)
                    }
                }
            case _ => ()
        }
    }
    quote(
        @Bean
        $input
        $registrations
    )
}

private func asFunc(decl: Decl): Option<FuncDecl> {
    match (decl) {
        case f: FuncDecl => Some(f)
        case m: MacroExpandDecl => match (extract(m)) {
            case f: FuncDecl => Some(f)
            case _ => None<FuncDecl>
        }
        case _ => None<FuncDecl>
    }
}

private func generateMethod(ns: String, klassName: String, f: FuncDecl): Tokens {
    let fnName = f.identifier.value
    let fullName = if (ns.isEmpty()) {
        fnName
    } else {
        '${ns}.${fnName}'
    }
    let multi = f.funcParams.size > 1
    let classToken = ident(klassName)
    let paramsVar = ident('__jsonrpc_params')
    // 未使用的形参用 `_`，避免宏生成的代码在构建日志里刷 unused variable 警告
    let handlerHead = if (f.funcParams.size > 0) {
        quote(_, $paramsVar)
    } else {
        quote(_, _)
    }
    var argDecls = quote()
    var argList = quote()
    var argTypes = quote([)
    var index = 0
    for (fp in f.funcParams) {
        let p = match (fp) {
            case x: MacroExpandParam => extract(x)
            case x => x
        }
        let pname = p.identifier.value
        let argVar = ident('__jsonrpc_arg_${index}')
        let named = if (multi) {
            quote(named: true)
        } else {
            quote(named: false)
        }
        if (index > 0) {
            argTypes += `comma`
        }
        argTypes += quote(TypeInfo.of<$(p.paramType)>())
        argDecls += `nl` + quote(
            let $argVar = JsonRpcArgs.extract<$(p.paramType)>(
                $paramsVar, $(Token(STRING_LITERAL, pname)), $named)
        )
        if (index > 0) {
            argList += `comma`
        }
        if (p.not.kind == NOT) {
            argList += quote($(p.identifier): $argVar)
        } else {
            argList += quote($argVar)
        }
        index++
    }
    argTypes += quote(])
    let registration = quote(
        let __jsonrpc_meta = JsonRpcRegistry.getMeta<$classToken>(
            $(Token(STRING_LITERAL, fnName)), $argTypes)
        JsonRpcRegistry.register(JsonRpcMethodMeta(
            name: $(Token(STRING_LITERAL, fullName)),
            handler: {$handlerHead =>
                $argDecls
                let __jsonrpc_result = lookup<$classToken>().$(f.identifier)($argList)
                JsonRpcArgs.toJson(__jsonrpc_result)
            },
            description: __jsonrpc_meta.description,
            timeout: if (__jsonrpc_meta.timeout.isEmpty()) {
                None<Duration>
            } else {
                Some(__jsonrpc_meta.timeoutDuration)
            }
        ))
    )
    `nl` + topMacroAnonymousClosure(registration)
}

private func ident(name: String): Token {
    Token(IDENTIFIER, name)
}
