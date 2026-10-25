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
 * 属性写法 `@Mcp['kb-server']` 或 `@Mcp[kbServer]`，作为 `serverInfo` 的 name；
 * 不写属性时 name 为 `fountain-mcp`。version 取配置项 `mcp_version`，默认 `1.0.0`。
 *
 * 展开结果：
 * - 类上加 `@Bean`
 * - 一个加载期闭包：设置 `serverInfo`，对每个函数调用 `get*Meta`，有注解时调用对应 `register*Meta`
 * - 最后调用 `McpRegistry.build()`
 */
public macro Mcp(input: Tokens): Tokens {
    expand('fountain-mcp', input)
}

public macro Mcp(attr: Tokens, input: Tokens): Tokens {
    expand(serverNameOf(attr), input)
}

private func serverNameOf(attr: Tokens): String {
    if (attr.size == 0) {
        return 'fountain-mcp'
    }
    if (attr.size == 1) {
        let kind = attr[0].kind
        if (kind == IDENTIFIER || kind == STRING_LITERAL || kind == SINGLE_QUOTED_STRING_LITERAL) {
            return attr[0].value
        }
    }
    diagReport(WARNING, attr, "expect @Mcp[<name>] where <name> is a string literal or identifier", '')
    'fountain-mcp'
}

private func expand(serverName: String, input: Tokens): Tokens {
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
    let serverNameToken = Token(STRING_LITERAL, serverName)
    var body = quote(let __mcp_service = lookup<$classToken>())
    body += `nl`
    body += quote(McpRegistry.serverInfo($serverNameToken))
    body += `nl`
    let processed = HashSet<String>()
    var index = 0
    for (item in klass.body.decls) {
        let kinds = annotationKinds(item)
        if (kinds.isEmpty()) {
            continue
        }
        match (asFunc(item)) {
            case Some(f) =>
                if (isPublic(f) && !isStatic(f) && f.identifier.value != 'init' && !processed.contains(f.identifier.value)) {
                    processed.add(f.identifier.value)
                    body += generateFunction(classToken, f, index, kinds) + `nl`
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

private func generateFunction(classToken: Token, f: FuncDecl, index: Int64, kinds: ArrayList<String>): Tokens {
    let fnName = f.identifier.value
    var argTypes = quote([)
    var toolArgs = quote()
    var promptArgs = quote()
    var count = 0
    for (fp in f.funcParams) {
        let p = match (fp) {
            case x: MacroExpandParam => extract(x)
            case x => x
        }
        if (count > 0) {
            argTypes += `comma`
            toolArgs += `comma`
            promptArgs += `comma`
        }
        argTypes += quote(TypeInfo.of<$(p.paramType)>())
        toolArgs += quote(McpConvert.argument<$(p.paramType)>(__mcp_raw))
        promptArgs += quote(McpConvert.argument<$(p.paramType)>(__mcp_raw[$count]))
        count++
    }
    argTypes += quote(])
    let nameToken = Token(STRING_LITERAL, fnName)
    let plainCall = quote(__mcp_service.$(f.identifier)())
    let toolCall = if (count == 0) {
        plainCall
    } else {
        quote(__mcp_service.$(f.identifier)($toolArgs))
    }
    let promptCall = if (count == 0) {
        plainCall
    } else {
        quote(__mcp_service.$(f.identifier)($promptArgs))
    }
    var generated = quote()
    if (kinds.contains('McpToolMeta')) {
        let toolId = Token(IDENTIFIER, '__mcp_tool_${index}')
        generated += quote(
            let $toolId = McpRegistry.getToolMeta<$classToken>($nameToken, $argTypes)
            if ($toolId.isSome()) {
                McpRegistry.registerToolMeta<$classToken>($nameToken, $toolId.getOrThrow(), $argTypes,
                    {__mcp_raw: JsonValue =>
                        McpConvert.toolResult($toolCall)
                    })
            }
        )
    }
    if (kinds.contains('McpResourceMeta')) {
        let resourceId = Token(IDENTIFIER, '__mcp_resource_${index}')
        let resourceCall = if (count == 0) {
            quote({=> McpConvert.resourceContents($plainCall)})
        } else {
            // 参数个数不合法时 registerResourceMeta 会在注册期报错；这里保持闭包可编译。
            quote({=> ArrayList<ResourceContent>()})
        }
        generated += quote(
            let $resourceId = McpRegistry.getResourceMeta<$classToken>($nameToken, $argTypes)
            if ($resourceId.isSome()) {
                McpRegistry.registerResourceMeta<$classToken>($nameToken, $resourceId.getOrThrow(), $argTypes,
                    $resourceCall)
            }
        )
    }
    if (kinds.contains('McpPromptMeta')) {
        let promptId = Token(IDENTIFIER, '__mcp_prompt_${index}')
        generated += quote(
            let $promptId = McpRegistry.getPromptMeta<$classToken>($nameToken, $argTypes)
            if ($promptId.isSome()) {
                McpRegistry.registerPromptMeta<$classToken>($nameToken, $promptId.getOrThrow(), $argTypes,
                    {__mcp_raw: Array<JsonValue> =>
                        McpConvert.promptMessages($promptCall)
                    })
            }
        )
    }
    generated
}
