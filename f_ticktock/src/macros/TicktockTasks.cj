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
macro package fountain::f_ticktock.macros

import std.ast.*
import fountain::f_macros.*
import fountain::f_ticktock.exception.*

public import fountain::f_bean.macros.Bean

public macro TicktockTasks(input: Tokens): Tokens {
    input |> parseDecl |> expand
}

private func expand(decl: Decl): Tokens {
    match(decl){
        case d: ClassDecl => expand(d)
        case d: MacroExpandDecl => 
            var md = d
            while(let x: MacroExpandDecl <- md.macroInputDecl){
                md = x
            }
            md.macroInputDecl = md.macroInputDecl |> expand |> parseDecl
            d.toTokens()
        case _ => 
            diagReport(ERROR, decl.toTokens(), 'only class decl is allowed', '')
            throw TicktockException('only class decl is allowed')
    }
}
/**
 * 带注解的成员在语法树上被包成 `MacroExpandDecl`（`@CronTask[...] public func f()`），
 * 修饰符（public / static）与函数签名都在内层声明上 ⇒ 先剥掉注解包装再判断。
 */
private func unwrapAnnotated(decl: Decl): Decl {
    match (decl) {
        case d: MacroExpandDecl => unwrapAnnotated(d.macroInputDecl)
        case d => d
    }
}

private func expand(decl: ClassDecl): Tokens {
    let name = decl.identifier
    var map = quote(
        let map = HashMap<String, () -> Unit>()
    ) + `nl`
    for(m in decl.body.decls){
        let member = unwrapAnnotated(m)
        if(isPublic(member) && !isStatic(member)){
            if(let f: FuncDecl <- member && f.funcParams.isEmpty()){
                map += quote(
                    map[$(f.identifier.value)] = {=> 
                        lookup<$name>().$(f.identifier)()
                        ()
                    }
                ) + `nl`
            }
        }
    }
    // 任务名 = "类名#方法名"：时间轮按 name 登记，同名会被后登记的覆盖。
    let taskNamePrefix = Token(TokenKind.STRING_LITERAL, "${name.value}#")
    quote(
        @Bean
        $decl
        private let _ = {=>
            $map
            for((t, n) in CronTicktockTaskImpl.extract<$name>()){
                CronTicktockTaskImpl($taskNamePrefix + n, t, map[n]) |> Ticktock.instance.addOrReplaceTask
            }
            for((t, n) in DelayedTicktockTaskImpl.extract<$name>()){
                DelayedTicktockTaskImpl($taskNamePrefix + n, t, map[n]) |> Ticktock.instance.addOrReplaceDelayTask
            }
        }()
    )
}