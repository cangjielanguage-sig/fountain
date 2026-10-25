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
macro package fountain::f_mcp.macros

internal import std.ast.*
internal import fountain::f_macros.*

/**
 * `@Mcp`：把类里每个 public 实例函数按注解注册为 tool / resource / prompt。
 *
 * 展开结果：
 * - 类上加 `@Bean`
 * - 一个加载期闭包：对每个函数调用 `get*Meta`，有注解时调用对应 `register*Meta`
 * - 最后调用 `McpRegistry.build()`
 */
public macro Mcp(input: Tokens): Tokens {
    expand(input)
}

public macro Mcp(attr: Tokens, input: Tokens): Tokens {
    expand(input)
}

private func expand(input: Tokens): Tokens {
    let (decl, _) = extractFirstDecl(input)
    let klass = match (decl) {
        case c: ClassDecl => c
        case m: MacroExpandDecl => match (extract(m)) {
            case c: ClassDecl => c
            case _ =>
                diagReport(ERROR, input.toTokens(), '@Mcp modify class decl only', '')
                return input.toTokens()
        }
        case _ =>
            diagReport(ERROR, input.toTokens(), '@Mcp modify class decl only', '')
            return input.toTokens()
    }
    let klassName = klass.identifier.value
    let classToken = Token(IDENTIFIER, klassName)
    var body = quote(let __mcp_service = lookup<$classToken>())
    body += `nl`
    let processed = HashSet<String>()
    var index = 0
    for (item in klass.body.decls) {
        if (annotationKinds(item).isEmpty()) {
            continue
        }
        match (asFunc(item)) {
            case Some(f) =>
                if (isPublic(f) && !isStatic(f) && f.identifier.value != 'init' && !processed.contains(f.identifier.value)) {
                    processed.add(f.identifier.value)
                    body += generateFunction(classToken, f, index) + `nl`
                    index++
                }
            case _ => ()
        }
    }
    body += quote(McpRegistry.build())
    quote(
        @Bean
        $input
        private let _ = {=>
            $body
        }()
    )
}

private func asFunc(decl: Decl): Option<FuncDecl> {
    match (decl) {
        case f: FuncDecl => Some(f)
        case m: MacroExpandDecl => asFunc(extract(m))
        case _ => None<FuncDecl>
    }
}

private func annotationKinds(decl: Decl): ArrayList<String> {
    let kinds = ArrayList<String>()
    match (decl) {
        case m: MacroExpandDecl =>
            let name = m.fullIdentifier.value
            if (name == 'McpToolMeta' || name == 'McpResourceMeta' || name == 'McpPromptMeta') {
                kinds.add(name)
            }
            kinds.add(all: annotationKinds(m.macroInputDecl))
        case _ => ()
    }
    kinds
}

private func generateFunction(classToken: Token, f: FuncDecl, index: Int64): Tokens {
    let fnName = f.identifier.value
    var argTypes = quote([)
    var conversions = quote()
    var count = 0
    for (fp in f.funcParams) {
        let p = match (fp) {
            case x: MacroExpandParam => extract(x)
            case x => x
        }
        if (count > 0) {
            argTypes += `comma`
            conversions += `comma`
        }
        argTypes += quote(TypeInfo.of<$(p.paramType)>())
        conversions += quote(McpRegistry.convertArg<$(p.paramType)>(__mcp_raw[$count]))
        count++
    }
    argTypes += quote(])
    let retType = try {
        f.declType.toTokens()
    } catch (_: Exception) {
        quote(Unit)
    }
    let nameToken = Token(STRING_LITERAL, fnName)
    let call = if (count == 0) {
        quote(__mcp_service.$(f.identifier)())
    } else {
        quote(__mcp_service.$(f.identifier)($conversions))
    }
    let toolId = Token(IDENTIFIER, '__mcp_tool_${index}')
    let resourceId = Token(IDENTIFIER, '__mcp_resource_${index}')
    let promptId = Token(IDENTIFIER, '__mcp_prompt_${index}')
    quote(
        let $toolId = McpRegistry.getToolMeta<$classToken, $retType>($nameToken, $argTypes)
        if ($toolId.isSome()) {
            McpRegistry.registerToolMeta<$classToken, $retType>($nameToken, $toolId.getOrThrow(), $argTypes,
                {__mcp_raw: Array<JsonValue> =>
                    $call
                })
        }
        let $resourceId = McpRegistry.getResourceMeta<$classToken, $retType>($nameToken, $argTypes,
            {__mcp_raw: Array<JsonValue> =>
                $call
            })
        if ($resourceId.isSome()) {
            McpRegistry.registerResourceMeta<$classToken, $retType>($nameToken, $resourceId.getOrThrow(),
                $argTypes,
                {__mcp_raw: Array<JsonValue> =>
                    $call
                })
        }
        let $promptId = McpRegistry.getPromptMeta<$classToken, $retType>($nameToken, $argTypes,
            {__mcp_raw: Array<JsonValue> =>
                $call
            })
        if ($promptId.isSome()) {
            McpRegistry.registerPromptMeta<$classToken, $retType>($nameToken, $promptId.getOrThrow(), $argTypes,
                {__mcp_raw: Array<JsonValue> =>
                    $call
                })
        }
    )
}
