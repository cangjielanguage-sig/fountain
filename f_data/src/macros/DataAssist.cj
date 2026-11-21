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
macro package fountain::f_data.macros

import std.ast
import std.ast.*
import std.collection.{HashSet, ArrayList}
import fountain::f_data.*
import fountain::f_macros.*

/**
 * 支持以下特性，不分大小写
 * ToString：实现ToString接口
 * Props：为非公共的实例成员变量添加公共实例成员属性
 * Hash：实现Hashable
 * Compare: 实现Comparable<T>
 * Equal: 实现Equatable<T>
 * Fields: 实现实例复制
 * @DataAssist只能修饰类，并且要使用fields属性，类的实例成员变量类型T必须是实现了fountain.data.DataFields<T>接口的类型。
 * fountain.data包对基本类型、字符串、Duration、DateTime、实现了DataFields接口的类型和被@DataAssist[fields]修饰的类做泛型实参的数组、集合、Option实现了DataFields的扩展。
 * 只有类的实例成员变量是这些类型才可以被@DataAssist[fields]修饰，否则会报错。
 * 被@DataAssist[fields]修饰的类可以被转换为JsonValue和实例成员复制。
 * 如果@DataAssist[fields]修饰的是泛型类，而泛型形参是实例成员变量的类型，则会编译错误。
 * 因为实例成员变量的类型会作为fountain.data.{ReadonlyField, MutableField}类型的泛型实参，而@DataAssist[fields]展开用它们的实例数组声明了静态成员变量。
 * 现在的编译器不允许泛型形参出现在静态成员变量的声明当中，所以会编译错误。
 * 展开末尾会归一化被修饰类的父接口列表（重复项去重、`Comparable<T>` 存在时删掉冗余的 `Equatable<T>`），
 * 所以类可以同时显式实现 `Comparable<T>` 和 `Equatable<T>`；详见 `normalizeSuperTypes`。
 */
public macro DataAssist(attr: Tokens, input: Tokens): Tokens {
    let (decl, index) = parseDeclFragment(input)
    let remainder = if(index < input.size){
        input[index..]
    }else{
        `empty_tokens`
    }
    let tokens = quote(
        $(assist(attr, decl))
        $(typeRegistration(attr, decl))
        $(remainder)
    )
    tokens
}
/**
 * 生成「包初始化时把自己登记进 `DataTypeRegistry`」的语句。
 *
 * 必要性：f_codec 的类型创建者表只在该进程**编码过**该类型时才登记，只解码不编码的一侧
 * （客户端第一次收响应、服务端第一次收请求）以及**嵌套**对象字段都会踩「object type murmur is not registered」
 * （.autocode/bugs/bug-archived-on-20261004.md 7.10 第 10 层 / 7.11）。f_data 不能反向依赖 f_codec（成环），所以这里只登记到 f_data 自己的表，
 * f_codec 解码未命中时按名字补算 murmur 再拉取。
 *
 * 只在非泛型类上生成：文件级拿不到泛型实参。只声明 `fields` 时生成（`toData()` 与 `ObjectData<T>` 都由它带来）。
 */
private func typeRegistration(attr: Tokens, decl: Decl): Tokens {
    match (decl) {
        case c: ClassDecl =>
            if (c.isGenericDecl) {
                return `empty_tokens`
            }
            var hasFields = false
            for (t in attr) {
                if (t.value.toAsciiLower() == 'fields') {
                    hasFields = true
                }
            }
            if (!hasFields) {
                return `empty_tokens`
            }
            let klass = c.identifier
            quote(
                private let _ = DataTypeRegistry.registerDataType<$klass>()
            )
        case _ => `empty_tokens`
    }
}
private func assist(attr: Tokens, input: Decl): Tokens {
    match (input) {
        case d: ClassDecl =>
            let set = HashSet<String>()
            for (t in attr) {
                set.add(t.value.toAsciiLower())
            }
            func generate(tag: String, decl: ClassDecl, exclusion: HashSet<String>,
                fn: (ClassDecl, HashSet<String>) -> Unit): Unit {
                if (set.contains(tag)) {
                    fn(decl, exclusion)
                }
            }
            let excludeProp = HashSet<String>()
            let excludeHash = HashSet<String>()
            let excludeEqual = HashSet<String>()
            let excludeCompare = HashSet<String>()
            let excludeToString = HashSet<String>()
            let excludeFields = HashSet<String>()
            func populateExclusion(message: MacroMessage, name: String, set: HashSet<String>): Unit {
                if (message.hasItem(name)) {
                    set.add(message.getString(name))
                }
            }
            for (message in getChildMessages('DataExclude')) {
                populateExclusion(message, 'prop', excludeProp)
                populateExclusion(message, 'hash', excludeHash)
                populateExclusion(message, 'equal', excludeEqual)
                populateExclusion(message, 'compare', excludeCompare)
                populateExclusion(message, 'tostring', excludeToString)
                populateExclusion(message, 'field', excludeFields)
            }
            // `generateProps` 会把私有字段改名成 `<name>_`，而 hash/equal/compare/tostring/fields 的生成都在改名之后运行，
            // 只登记源码名会让 `@DataExclude[hash]`/`[equal]` 对**私有 var** 静默失效（ServiceMeta.weight 正是这种，
            // 见 .autocode/bugs/bug-archived-on-20261004.md 7.10：weight 未被排除 ⇒ 客户端 stub 与服务端注册的 meta 哈希不同 ⇒ 查表永远落空）。
            // 这里把改名后的名字一并登记。prop 不在其列：props 生成发生在改名之前。
            for (set in [excludeHash, excludeEqual, excludeCompare, excludeToString, excludeFields]) {
                for (name in set.toArray()) {
                    set.add('${name}_')
                }
            }
            excludeEqual.add('__hAsh__')
            excludeCompare.add('__hAsh__')
            excludeToString.add('__hAsh__')
            generate('props', d, excludeProp, generateProps)
            generate('hash', d, excludeHash, generateHash)
            generate('equal', d, excludeEqual, generateEqual)
            generate('compare', d, excludeCompare, generateCompare)
            generate('tostring', d, excludeToString, generateToString)
            generate('fields', d, excludeFields, generateToFields)
            normalizeSuperTypes(d)
            d.toTokens()
        case d: MacroExpandDecl => 
            var ind = d
            while(let md: MacroExpandDecl <- ind.macroInputDecl) {
                ind = md
            }
            let tokens = assist(attr, ind.macroInputDecl)
            ind.macroInputDecl = parseDecl(tokens)
            d.toTokens()
        case _ =>
            diagReport(ERROR, input.toTokens(), 'input must be class decl', '')
            throw IllegalArgumentException("input must be a class decl")
    }
}

/**
 * 归一化被修饰类的父接口列表，消除重复路径。
 *
 * 必要性（SDK 1.3.0-alpha，nightly 20261110 起 std 合入 local mode）：std 里 `Comparable<T> <: Equatable<T>`。
 * 一个类同时列出 `Comparable<X>` 与 `Equatable<X>` 时，`Equatable<X>` 有两条继承路径，编译器会要求实现
 * 带 `@local!` 模态的 `!=`（普通模式写不出来，补 `@local!` 又报 `is not a subtype of`）；同一父接口列两遍
 * 则直接报 `duplicate interface`。宏无条件追加父接口，所以这两种形态都必须在这里归一化掉。
 *
 * 只删冗余声明，不改变类最终实现的接口集合：`Comparable<X>` 存在时删掉 `Equatable<X>`，类仍是二者的实例。
 * 因此用户显式写 `<: Comparable<X> & Equatable<X>` 配 `@DataAssist` 合法。
 */
private func normalizeSuperTypes(decl: ClassDecl): Unit {
    let superTypes = decl.superTypes
    if (superTypes.size < 2) {
        return
    }
    // 子接口/父接口隐含的冗余声明：删掉会被多条路径继承的项。
    // - `Comparable<X>` 隐含 `Equatable<X>`；
    // - `LocalEquatable<X>` 隐含 `Equatable<X>`；
    // - `LocalComparable<X>` 隐含 `Comparable<X>` / `Equatable<X>` / `LocalEquatable<X>`。
    let implied = HashSet<String>()
    func implyDerived(text: String, prefix: String, targets: Array<String>): Unit {
        if (text.startsWith(prefix)) {
            let rest = text[prefix.size .. text.size]
            for (target in targets) {
                implied.add(target + rest)
            }
        }
    }
    for (t in superTypes) {
        let text = superTypeText(t)
        implyDerived(text, 'Comparable<', ['Equatable<'])
        implyDerived(text, 'LocalEquatable<', ['Equatable<'])
        implyDerived(text, 'LocalComparable<', ['Comparable<', 'Equatable<', 'LocalEquatable<'])
    }
    let kept = ArrayList<TypeNode>()
    let seen = HashSet<String>()
    for (t in superTypes) {
        let text = superTypeText(t)
        if (seen.contains(text) || implied.contains(text)) {
            continue
        }
        seen.add(text)
        kept.add(t)
    }
    if (kept.size < superTypes.size) {
        decl.superTypes = kept
    }
}

/** 父接口的规范化文本：拼上词法单元的值并跳过换行 / 注释，使 `Comparable<X>` 与 `Comparable< X >` 视为同一项。 */
private func superTypeText(t: TypeNode): String {
    var text = ''
    for (token in t.toTokens()) {
        if (token.kind == NL || token.kind == COMMENT) {
            continue
        }
        text += token.value
    }
    text
}

func generateProps(decl: ClassDecl, exclusion: HashSet<String>) {
    let decls = decl.body.decls
    let appended = ArrayList<Decl>()
    func gen(v: VarDecl, macroTokens: Tokens) {
        if (v.isStatic() || v.isPublic()) {
            return
        }
        let name = v.identifier
        if (exclusion.contains(name.value)) {
            return
        }
        let t = v.declType
        let mutable = v.keyword.value == 'var'
        let nameVal = name.value
        v.identifier = Token(IDENTIFIER, if(nameVal.startsWith('`')){nameVal[1 .. nameVal.size - 1]}else{nameVal} + '_')
        let (mutToken, setter) = if (mutable) {
            (quote(mut), quote(
                set(value){
                    $(v.identifier) = value
                }
            ))
        } else {
            let empty = quote()
            (empty, empty)
        }
        let propDecl = PropDecl(
                quote(
            public $mutToken prop $name: $(t){
                get(){
                    $(v.identifier)
                }
                $(setter)
            }
        ))
        appended.add(if(macroTokens.size == 0){
            propDecl
        }else{
            let md = MacroExpandDecl(macroTokens)
            var m = md
            while(let x: MacroExpandDecl <- m.macroInputDecl) {
                m = x
            }
            m.macroInputDecl = propDecl
            md
        })
    }
    let vars = ArrayList<Decl>()
    let assigns = ArrayList<ast.Node>()
    for (decl in decls) {
        match (decl) {
            case d: VarDecl where !(d.isStatic() || d.isPublic()) => gen(d, quote())
            case d: PrimaryCtorDecl =>
                let funcParams = d.funcParams
                for (i in 0 .. funcParams.size) {
                    func gen(p: FuncParam, macroTokens: Tokens){
                        let paramTokens = p.toTokens()
                        var c = 0
                        for (j in 0 .. paramTokens.size where paramTokens[j].kind == IDENTIFIER) {
                            c = j
                            break
                        }
                        var end = paramTokens.size
                        if (paramTokens[end - 1].kind == COMMA) {
                            end--
                        }
                        funcParams[i] = FuncParam(paramTokens[c .. end])
                        let member = VarDecl()
                        member.modifiers = p.modifiers
                        member.keyword = p.keyword
                        member.identifier = p.identifier
                        member.colon = p.colon
                        member.declType = p.paramType
                        vars.add(member)
                        p.modifiers = ArrayList<Modifier>()
                        p.keyword = Token(ILLEGAL)
                        gen(member, macroTokens)
                        assigns.add(parseExpr(quote(this.$(member.identifier) = $(p.identifier))))
                    }
                    let p = funcParams[i]
                    if (let x: MacroExpandParam <- p) {//TODO: x.macroInputDecl x.toTokens()有BUG，无法完成，等待修复
                        let mp = extract(x)
                        if(mp.isMemberParam()){
                            gen(mp, x.toTokens())
                        }
                    } else if (p.isMemberParam()) {
                        gen(p, quote())
                    }
                }
                d.block.nodes.add(all: assigns, at: 0)
            case d: MacroExpandDecl => 
                var md = extract(d)
                if(let x: VarDecl <- md && !(x.isStatic() || x.isPublic())){
                    gen(x, d.toTokens())
                }
            case _ => continue
        }
    }
    decls.add(all: vars, at: 0)
    decls.add(all: appended)
}

func generateHash(d: ClassDecl, exclusion: HashSet<String>) {
    if (d.superTypes.isEmpty()) {
        d.upperBound = `upperbound`[0]
    }
    d.superTypes.add(RefType(quote(Hashable)))
    var hashed = `nl`
    for (d in d.body.decls where d is VarDecl &&
        !(isStatic(d) || exclusion.contains(d.identifier.value) || exclusion.contains('${d.identifier.value}_'))) {
        // 集合字段不能用默认 hashCode：Array/ArrayList 等满足 Hashable，但它们的 hashCode 是**身份**哈希，
        // “内容相同”的两个实例会得到不同哈希 ⇒ 用它当 map key（例如 ServiceMeta.argTypeNames）查表永远落空
        // （见 .autocode/bugs/bug-archived-on-20261004.md 7.10：客户端 stub 与服务端注册各自构造 meta，数组实例不同）。
        // 集合按内容（toString）参与哈希；万一碰撞也只多一次 equals 检查，不影响正确性。
        let typeText = match (d) {
            case x: VarDecl => x.declType.toTokens().toString()
            case _ => ''
        }
        let isCollection = typeText.contains('Array') || typeText.contains('ArrayList') ||
            typeText.contains('HashSet') || typeText.contains('HashMap') || typeText.contains('TreeMap') ||
            typeText.contains('TreeSet') || typeText.contains('Collection') || typeText.contains('DataList')
        if (isCollection) {
            hashed += quote(hasher.append($(d.identifier).toString())$(`nl`))
        } else {
            hashed += quote(hasher.append($(d.identifier))$(`nl`))
        }
    }
    d.body.decls.add(
            all: [VarDecl(quote(
        private var __hAsh__ = 0
    )),
                FuncDecl(
                quote(
        public $(openTokens(d)) func hashCode(): Int64{
            if(__hAsh__ == 0){
                let hasher = HashBuilder()
                $hashed
                __hAsh__ = hasher.build()
            }
            __hAsh__
        }
    ))])
}

/** 字段声明类型是否为已知的 Copyable 类型；用于选择 demode 版 helper。 */
private func isCopyableFieldType(d: Decl): Bool {
    match (d) {
        case x: VarDecl =>
            let text = x.declType.toTokens().toString().trimAscii()
            text == 'Int8' || text == 'Int16' || text == 'Int32' || text == 'Int64' || text == 'IntNative' ||
                text == 'UInt8' || text == 'UInt16' || text == 'UInt32' || text == 'UInt64' || text == 'UIntNative' ||
                text == 'Float16' || text == 'Float32' || text == 'Float64' || text == 'Bool' || text == 'Rune'
        case _ => false
    }
}

/** 字段声明类型的 Tokens；用于生成具体的 `Equatable<FieldType>` / `Comparable<FieldType>` 匹配。 */
private func fieldTypeTokens(d: Decl): Tokens {
    match (d) {
        case x: VarDecl => x.declType.toTokens()
        case _ => quote()
    }
}

/**
 * 生成 `localEq(this @ local?, other: T @ local?)`。
 *
 * 非 Copyable 字段不用泛型 helper，而是按字段的具体类型生成 `match`，只走接口的
 * `@ local?` 成员；不可比时退回 refEq，与非模态 `f_data_eq` 的兜底语义一致。
 */
func generateEqual(d: ClassDecl, exclusion: HashSet<String>) {
    if (d.superTypes.isEmpty()) {
        d.upperBound = `upperbound`[0]
    }
    let typeName = quote($(d.identifier)$(d.genericParamTokens))
    d.superTypes.add(RefType(quote(LocalEquatable<$typeName>)))
    // 普通路径：保持原实现，不经过 local 视图（普通实例没有 local region）
    var eq = quote(f_data_hash_eq(this, other)$(`nl`))
    for (field in d.body.decls where field is VarDecl &&
        !(isStatic(field) || exclusion.contains(field.identifier.value) || exclusion.contains('${field.identifier.value}_'))) {
        eq += `and` + quote(f_data_eq(this.$(field.identifier), other.$(field.identifier))) + `nl`
    }
    var body = quote(
        if (refEq(this, other)) {
            return true
        }
    ) + `nl`
    var idx = 0
    for (field in d.body.decls where field is VarDecl &&
        !(isStatic(field) || exclusion.contains(field.identifier.value) || exclusion.contains('${field.identifier.value}_'))) {
        if (isCopyableFieldType(field)) {
            body += quote(
                if (!f_data_eq_copy(this.$(field.identifier), other.$(field.identifier))) {
                    return false
                }
            ) + `nl`
        } else {
            let fieldType = fieldTypeTokens(field)
            let okName = Token(IDENTIFIER, '__eq_ok_${idx}')
            body += quote(
                let $(okName) = match (this.$(field.identifier)) {
                    case __x: Equatable<$fieldType> => __x == other.$(field.identifier)
                    case _ => match ((this.$(field.identifier), other.$(field.identifier))) {
                        case (__x: Object, __y: Object) => refEq(__x, __y)
                        case _ => false
                    }
                }
                if (!$(okName)) {
                    return false
                }
            ) + `nl`
            idx++
        }
    }
    body += quote(true)
    d.body.decls.add(
            all: [FuncDecl(
                quote(
        public $(openTokens(d)) operator func ==(other: $typeName): Bool {
            refEq(this, other) || ($eq)
        }
    )),
                FuncDecl(
                quote(
        public $(openTokens(d)) operator func !=(other: $typeName): Bool {
            !(this == other)
        }
    )),
                FuncDecl(
                quote(
        public $(openTokens(d)) func localEq(this @ local?, other: $typeName @ local?): Bool {
            $body
        }
    ))])
}

/** 生成 `localCompare`；比较逻辑与 `generateEqual` 同构，不可比字段返回 EQ。 */
func generateCompare(d: ClassDecl, exclusion: HashSet<String>) {
    if (d.superTypes.isEmpty()) {
        d.upperBound = `upperbound`[0]
    }
    let typeName = quote($(d.identifier)$(d.genericParamTokens))
    d.superTypes.add(RefType(quote(LocalComparable<$typeName>)))
    // 普通路径：保持原实现，不经过 local 视图（普通实例没有 local region）
    var cmp = `nl`
    for (field in d.body.decls where field is VarDecl &&
        !(isStatic(field) || exclusion.contains(field.identifier.value) || exclusion.contains('${field.identifier.value}_'))) {
        cmp += quote(result = f_data_cmp(this.$(field.identifier), other.$(field.identifier))) + `nl` + quote(
            if(result != EQ){
                return result
            }
            $(`nl`)
        )
    }
    var body = quote(var result = Ordering.EQ) + `nl`
    var idx = 0
    for (field in d.body.decls where field is VarDecl &&
        !(isStatic(field) || exclusion.contains(field.identifier.value) || exclusion.contains('${field.identifier.value}_'))) {
        if (isCopyableFieldType(field)) {
            // 必须把比较结果写回 `result`：此前只求值不赋值，`compare` 对任何输入都返回 EQ（`@DataAssist[compare]` 实际失效）
            body += quote(
                result = f_data_cmp_copy(this.$(field.identifier), other.$(field.identifier))
                if (result != EQ) {
                    return result
                }
            ) + `nl`
        } else {
            let fieldType = fieldTypeTokens(field)
            let cmpName = Token(IDENTIFIER, '__cmp_ok_${idx}')
            body += quote(
                let $(cmpName) = match (this.$(field.identifier)) {
                    case __x: Comparable<$fieldType> => __x.compare(other.$(field.identifier))
                    case _ => EQ
                }
                if ($(cmpName) != EQ) {
                    return $(cmpName)
                }
            ) + `nl`
            idx++
        }
    }
    body += quote(result)
    d.body.decls.add(
            all: [FuncDecl(
                quote(
        public $(openTokens(d)) func compare(other: $typeName): Ordering {
            var result = Ordering.EQ
            $cmp
            result
        }
    )),
                FuncDecl(
                quote(
        public $(openTokens(d)) func localCompare(this @ local?, other: $typeName @ local?): Ordering {
            $body
        }
    ))])
}

func generateToString(d: ClassDecl, exclusion: HashSet<String>) {
    if (d.superTypes.isEmpty()) {
        d.upperBound = `upperbound`[0]
    }
    d.superTypes.add(RefType(quote(ToString)))
    var str = quote(
        result.append<$(d.identifier)$(d.genericParamTokens)>()
    )
    for (d in d.body.decls where d is VarDecl &&
        !(isStatic(d) || exclusion.contains(d.identifier.value) || exclusion.contains('${d.identifier.value}_'))) {
        str += `nl` + quote(result.append($(d.identifier.value), $(d.identifier)))
    }
    d.body.decls.add(
            FuncDecl(
                quote(
        public $(openTokens(d)) func toString(): String {
            var result = DataToString()
            $str
            result.toString()
        }
    )))
}

func generateToFields(d: ClassDecl, exclusion: HashSet<String>) {
    let klassDecl = (d as ClassDecl).getOrThrow {
        DataException("current decl ${d.identifier.value} must be a class decl")
    }
    let klassIdentifier = quote($(klassDecl.identifier)$(d.genericParamTokens))
    if (klassDecl.superTypes.isEmpty()) {
        klassDecl.upperBound = `upperbound`[0]
    }
    let superTypes = klassDecl.superTypes
    superTypes.add(RefType(quote(ObjectData<$(klassIdentifier)>)))
    let body = klassDecl.body.decls
    let fields = ArrayList<Expr>()
    for (d in body where (!isStatic(d) && isPublic(d) && !exclusion.contains(d.identifier.value)) || (d is MacroExpandDecl)) {
        func appendExpr(d: Decl, dt: Tokens, isVar: Bool){
            var declType = dt
            if (declType[0].kind == QUEST) {
                declType = declType[1..]
            } else if (declType[0].kind == IDENTIFIER && declType[0].value == 'Option') {
                declType = declType[2..declType.size - 1]
            }
            let tokens = if (isVar) {
                quote(MutableField)
            } else {
                quote(ReadonlyField)
            } + quote(.new<$(klassIdentifier), $(declType)>($(d.identifier.value), {o => o.$(d.identifier)})) + if (isVar) {
                quote({o, v => o.$(d.identifier) = v})
            } else {
                `empty_tokens`
            }
            let expr = parseExpr(tokens)
            fields.add(expr)
        }
        func appendExpr(dt: Tokens, isVar: Bool){
            appendExpr(d, dt, isVar)
        }
        match (d) {
            case x: VarDecl => appendExpr(x.declType.toTokens(), x.isVar())
            case x: PropDecl => appendExpr(x.declType.toTokens(), x.isMut())
            case x: PrimaryCtorDecl =>
                for (p in x.funcParams where p.isMemberParam() && isPublic(p)) {
                    appendExpr(p, p.paramType.toTokens(), isVar(p))
                }
                continue
            case x: MacroExpandDecl => 
                match (extract(x)) {
                    case x: VarDecl where !isStatic(x) && isPublic(x) => appendExpr(x, x.declType.toTokens(), x.isVar())
                    case x: PropDecl where !isStatic(x) && isPublic(x) => appendExpr(x, x.declType.toTokens(), x.isMut())
                    case x: PrimaryCtorDecl where isPublic(d) =>
                        for (p in x.funcParams) {
                            match(p){
                                case x: MacroExpandParam => 
                                    var m: Decl = x
                                    while(let d: MacroExpandParam <- m){
                                        m = d.macroInputDecl
                                    }
                                    if(let x: FuncParam <- m && x.isMemberParam() && isPublic(x)){
                                        appendExpr(x, x.paramType.toTokens(), isVar(x))
                                    }
                                case x: FuncParam where x.isMemberParam() && isPublic(p) => appendExpr(x, x.paramType.toTokens(), isVar(x))
                                case _ => continue
                            }
                            appendExpr(p.paramType.toTokens(), isVar(p))
                        }
                        continue
                    case _ => continue
                }
            case _ => continue
        }
    }
    let openModi = openTokens(klassDecl)
    var fieldTokens = `lsquare`
    for (f in fields) {
        if (fieldTokens.size > 1) {
            fieldTokens += `comma`
        }
        fieldTokens += f.toTokens()
    }
    fieldTokens += `rsquare`
    body.add(
        all: [
            FuncDecl(
                quote(
        public static func dataFields(): ObjectFields {
            ObjectFields.getObjectFields<$klassIdentifier>{
                ($fieldTokens, {=>$klassIdentifier()})
            }
        }
    )),
            FuncDecl(
                quote(
        public $openModi func toData(): Data {
            DataObject<$klassIdentifier>(this)
        }
    )),
            FuncDecl(
                quote(
        public static func tryFromData(data: Data, flag: DataConversionFlag): Any {
            f_data_tryFromData<$klassIdentifier>(data, flag)
        }
    ))
        ]
    )
}

private func openTokens(klassDecl: ClassDecl): Tokens {
    if (klassDecl.isAbstract() || klassDecl.isOpen()) {
        `open`
    } else {
        `empty_tokens`
    }
}
