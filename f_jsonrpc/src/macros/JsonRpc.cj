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

internal import std.collection.{ArrayList, HashMap}

/**
 * `@jsonrpc[topic: kb]`：把类里的每个 public 实例方法注册成一个 JSON-RPC 方法。
 *
 * 展开结果：
 * - 类上加 `@Bean`
 * - 每个方法一段 `private let _ = {=> ... }()`，在加载期调用 `JsonRpcRegistry.register`
 * - 方法名是 `<topic>.<fnName>`；没有 topic 时就是 `<fnName>`
 */
public macro jsonrpc(input: Tokens): Tokens {
    expand('', input)
}

public macro jsonrpc(attr: Tokens, input: Tokens): Tokens {
    expand(topicOf(attr), input)
}

/**
 * `@jsonrpcmeta['描述', '5s']`：`@JsonRpcMeta[...]` 的语法糖。
 */
public macro jsonrpcmeta(attr: Tokens, input: Tokens): Tokens {
    quote(
        @JsonRpcMeta[$attr]
        $input
    )
}

private func topicOf(attr: Tokens): String {
    var i = 0
    while (i < attr.size) {
        if (attr[i].kind == IDENTIFIER && attr[i].value == 'topic') {
            if (i + 2 < attr.size && attr[i + 1].kind == COLON) {
                return attr[i + 2].value
            }
            diagReport(ERROR, attr, "expect @jsonrpc[topic: <name>]", '')
            return ''
        }
        i++
    }
    ''
}

private func expand(topic: String, input: Tokens): Tokens {
    let (decl, _) = extractFirstDecl(input)
    let klass = match (decl) {
        case c: ClassDecl => c
        case m: MacroExpandDecl => match (extract(m)) {
            case c: ClassDecl => c
            case _ =>
                diagReport(ERROR, input.toTokens(), '@jsonrpc modify class decl only', '')
                return input.toTokens()
        }
        case _ =>
            diagReport(ERROR, input.toTokens(), '@jsonrpc modify class decl only', '')
            return input.toTokens()
    }
    let klassName = klass.identifier.value
    let metas = metaMap(klass)
    var registrations = quote()
    for (item in klass.body.decls) {
        match (asFunc(item)) {
            case Some(f) =>
                if (isPublic(f) && !isStatic(f) && f.identifier.value != 'init') {
                    let meta = metas.get(f.identifier.value) ?? ('', '')
                    registrations += generateMethod(topic, klassName, f, meta)
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

/**
 * 从类的 token 流里把 `@JsonRpcMeta[...]` 映射到紧随其后的函数名。
 *
 * 注解在 `FuncDecl.toTokens()` 里不出现，但在 `ClassDecl.toTokens()` 里是完整源码，
 * 所以以类为单位扫描。编译期取值，避免加载期反射时类型元数据尚未就绪。
 */
private func metaMap(klass: ClassDecl): HashMap<String, (String, String)> {
    let map = HashMap<String, (String, String)>()
    let tokens = klass.toTokens()
    var pending = None<(String, String)>
    var i = 0
    while (i < tokens.size) {
        let token = tokens[i]
        if (token.kind == IDENTIFIER && (token.value == 'JsonRpcMeta' || token.value == 'jsonrpcmeta') && i + 5 < tokens
            .size && tokens[i + 1].kind == LSQUARE && tokens[i + 3].kind == COMMA && tokens[i + 5].kind == RSQUARE &&
            isStringToken(tokens[i + 2]) && isStringToken(tokens[i + 4])) {
            pending = Some((tokens[i + 2].value, tokens[i + 4].value))
            i += 6
            continue
        }
        if (token.kind == FUNC && i + 1 < tokens.size && tokens[i + 1].kind == IDENTIFIER) {
            match (pending) {
                case Some(meta) =>
                    map.add(tokens[i + 1].value, meta)
                    pending = None<(String, String)>
                case _ => ()
            }
        }
        i++
    }
    map
}

private func generateMethod(topic: String, klassName: String, f: FuncDecl, meta: (String, String)): Tokens {
    let fnName = f.identifier.value
    let fullName = if (topic.isEmpty()) {
        fnName
    } else {
        '${topic}.${fnName}'
    }
    let multi = f.funcParams.size > 1
    let classToken = ident(klassName)
    let ctxVar = ident('__jsonrpc_ctx')
    let paramsVar = ident('__jsonrpc_params')
    var argDecls = quote()
    var argList = quote()
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
        argDecls += `nl` + quote(
            let $argVar = JsonRpcArgs.extract<$(p.paramType)>(
                $paramsVar, $(str(pname)), $named)
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
    let (description, timeoutText) = meta
    let registration = quote(
        JsonRpcRegistry.register(JsonRpcMethodMeta(
            name: $(str(fullName)),
            handler: {$ctxVar, $paramsVar =>
                let __jsonrpc_controller = JsonRpcRegister.instance<$classToken>()
                $argDecls
                let __jsonrpc_result = __jsonrpc_controller.$(f.identifier)($argList)
                JsonRpcArgs.toJson(__jsonrpc_result)
            },
            description: $(str(description)),
            timeout: JsonRpcRegister.parseTimeout($(str(timeoutText)))
        ))
    )
    `nl` + topMacroAnonymousClosure(registration)
}

private func isStringToken(token: Token): Bool {
    token.kind == STRING_LITERAL || token.kind == SINGLE_QUOTED_STRING_LITERAL
}

private func ident(name: String): Token {
    Token(IDENTIFIER, name)
}

private func str(value: String): Token {
    Token(STRING_LITERAL, value)
}
