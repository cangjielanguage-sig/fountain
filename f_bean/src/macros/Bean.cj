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
macro package f_bean.macros

//Autowired Constructor Value只能是宏否则会用到大量反射
/**
 * 只能修饰类。将@Bean修饰的类注册到BeanFactory
 */
public macro Bean(input: Tokens): Tokens {
    let klass = match(parseDecl(input)){
        case x: ClassDecl => x
        case x: MacroExpandDecl => 
            return replaceMacroInputDecl(quote(@Bean), x).toTokens()
        case _ => 
            diagReport(ERROR, input, 'illegal decl', '')
            throw BeanException()
    }
    let identifier = klass.identifier
    var ctorTokens = quote(
        let ctors = HashMap<String, ()-> $identifier>()
    ) + `nl`
    for (d in klass.body.decls) {
        match (d) {
            case f: FuncDecl where f.identifier.value == 'init' => ctorTokens += quote(
                    ctors['init'] = {=> $(identifier)()}
                ) +
                `nl`
            case f: FuncDecl where isStatic(f) && isPublic(f) && f.funcParams.isEmpty() =>
                let fname = f.identifier.value
                ctorTokens += quote(
                    ctors[$fname] = {=> $(identifier).$(f.identifier)()}
                ) +
                    `nl`
            case f: PrimaryCtorDecl where isPublic(f) && f.funcParams.isEmpty() => ctorTokens += quote(
                    ctors['init'] = {=> $(identifier)()}
                ) +
                `nl`
            case med: MacroExpandDecl =>
                var md: Decl = med
                while (let d: MacroExpandDecl <- md) {
                    md = d.macroInputDecl
                    match (md) {
                        case f: FuncDecl where f.identifier.value == 'init' => ctorTokens += quote(
                                ctors['init'] = {=> $(identifier)()}
                            ) +
                            `nl`
                        case f: FuncDecl where isStatic(f) && isPublic(f) && f.funcParams.isEmpty() =>
                            let fname = f.identifier.value
                            ctorTokens += quote(
                                ctors[$fname] = {=> $(identifier).$(f.identifier)()}
                            ) +
                                `nl`
                        case f: PrimaryCtorDecl where isPublic(f) && f.funcParams.isEmpty() => ctorTokens += quote(
                                ctors['init'] = {=> $(identifier)()}
                            ) +
                            `nl`
                        case f: MacroExpandDecl => continue
                        case _ => break
                    }
                    break
                }
            case _ => continue
        }
    }
    quote(
        $input
        private let _ = {=>
            $ctorTokens
            var constructor = None<() -> $identifier>
            for ((n, f) in ctors where TypeInfos.withAnnotation<$identifier, Constructor>(n, [])) {
                constructor = n
                break
            }
            if (constructor.isNone() && let Some(f) <- ctors.get("init")) {
                constructor = f
            }
            BeanFactory.instance.register<$identifier>(constructor.getOrThrow{
                BeanException('class $(identifier.value) must be with a public parameterless constructor or a public static parameterless function.')
            })
        }()
    )
}