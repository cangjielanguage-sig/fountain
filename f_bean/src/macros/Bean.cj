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

/**
 * 只能修饰类。将@Bean修饰的类注册到BeanFactory。如果不是泛型类型建议使用无属性的@Bean宏。
 * 本宏的属性仅仅用来指定泛型类型的泛型实参，可以使用|分隔指定多组泛型实参。
 */
public macro Bean(attr: Tokens, input: Tokens): Tokens {
    let klass = extractClassDecl(input)
    expandBean(attr, input, klass)
}
/**
 * 只能修饰类。将@Bean修饰的类注册到BeanFactory。如果不是泛型类型建议使用无属性的@Bean宏
 */
public macro Bean(input: Tokens): Tokens {
    let klass = extractClassDecl(input)
    expandBean(quote(), input, klass)
}
private func extractClassDecl(input: Tokens): ClassDecl {
    match(parseDecl(input)){
        case x: ClassDecl => x
        case x: MacroExpandDecl => 
            match(extract(x)){
                case x: ClassDecl => x
                case _ => 
                    diagReport(ERROR, input, '@Bean modify class decl only', '')
                    throw BeanException()
            }
        case _ => 
            diagReport(ERROR, input, '@Bean modify class decl only', '')
            throw BeanException()
    }
}
private func expandBean(attr: Tokens, input: Tokens, klass: ClassDecl): Tokens {
    let identifier = klass.identifier
    let list = ArrayList<Tokens>()
    list.add(quote())
    for(i in 0 .. attr.size){
        let a = attr[i]
        if(a.kind == TokenKind.BITOR){
            list.add(quote())
            continue
        } else {
            let last = list.size - 1
            list[last] = list[last] + a
        }
    }
    if(list.size > 1){
        list.removeIf{g => g.size == 0}
    }
    var tokens = input
    for(g in list){
        let beanType = if(g.size == 0){
            quote($identifier)
        }else{
            quote($identifier<$g>)
        }
        var ctorTokens = quote(
            let ctors = HashMap<String, ()-> $beanType>()$(`nl`)
        )
        for (d in klass.body.decls) {
            match (d) {
                case f: FuncDecl where f.identifier.value == 'init' => ctorTokens += quote(
                        ctors['init'] = {=> $(beanType)()}$(`nl`)
                    )
                case f: FuncDecl where isStatic(f) && isPublic(f) && f.funcParams.isEmpty() =>
                    let fname = f.identifier.value
                    ctorTokens += quote(
                        ctors[$fname] = {=> $(beanType).$(f.identifier)()}$(`nl`)
                    )
                case f: PrimaryCtorDecl where isPublic(f) && f.funcParams.isEmpty() => ctorTokens += quote(
                        ctors['init'] = {=> $(beanType)()}$(`nl`)
                    )
                case med: MacroExpandDecl =>
                    var md: Decl = med
                    while (let d: MacroExpandDecl <- md) {
                        md = d.macroInputDecl
                        match (md) {
                            case f: FuncDecl where f.identifier.value == 'init' => ctorTokens += quote(
                                    ctors['init'] = {=> $(beanType)()}$(`nl`)
                                )
                            case f: FuncDecl where isStatic(f) && isPublic(f) && f.funcParams.isEmpty() =>
                                let fname = f.identifier.value
                                ctorTokens += quote(
                                    ctors[$fname] = {=> $(beanType).$(f.identifier)()}
                                    $(`nl`)
                                )
                            case f: PrimaryCtorDecl where isPublic(f) && f.funcParams.isEmpty() => ctorTokens += quote(
                                    ctors['init'] = {=> $(beanType)()}
                                    $(`nl`)
                                )
                            case f: MacroExpandDecl => continue
                            case _ => break
                        }
                        break
                    }
                case _ => continue
            }
        }
        tokens += `nl` + topMacroAnonymousClosure(quote(
            $ctorTokens
            var constructor = if (ctors.isEmpty()) {
                {=> $beanType()}
            } else {
                var ctor = None<() -> $beanType>
                for ((n, f) in ctors where TypeInfos.withAnnotation<$beanType, Constructor>(n, [])) {
                    ctor = f
                    break
                }
                if (ctor.isNone() && let Some(f) <- ctors.get("init")) {
                    ctor = f
                }
                ctor
            }
            BeanFactory.instance.register<$beanType>(constructor.getOrThrow{
                let beanTypeName = $(beanType.toString())
                BeanException('class ' + beanTypeName + ' must be with a public parameterless constructor or a public static parameterless function.')
            })
        ))
    }
    tokens
}