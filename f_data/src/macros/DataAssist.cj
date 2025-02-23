/*
   Copyright (c) [2022] [WuJingrun（吴京润）]
   fountain is licensed under Mulan PSL v2.
   You can use this software according to the terms and conditions of the Mulan PSL v2.
   You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
   THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
   See the Mulan PSL v2 for more details.
 */

macro package f_data.macros

import std.ast.*
import std.collection.{HashSet, ArrayList}
import f_data.*
import f_macros.*

/*
 * ToString Props Hash Compare Equal Fields
 * tostring props hash compare equal fields
 * TOSTRING PROPS HASH COMPARE EQUAL FIELDS
 * toString
 */
public macro DataAssist(attr: Tokens, input: Tokens): Tokens {
    match (parseDecl(input)) {
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
            excludeEqual.add('__hAsh__')
            excludeCompare.add('__hAsh__')
            excludeToString.add('__hAsh__')
            generate('props', d, excludeProp, generateProps)
            generate('hash', d, excludeHash, generateHash)
            generate('equal', d, excludeEqual, generateEqual)
            generate('compare', d, excludeCompare, generateCompare)
            generate('tostring', d, excludeToString, generateToString)
            generate('fields', d, excludeFields, generateToFields)
            d.toTokens()
        case _ => throw IllegalArgumentException("input must be a class decl")
    }
}

func generateProps(decl: ClassDecl, exclusion: HashSet<String>) {
    let decls = decl.body.decls
    let appended = ArrayList<Decl>()
    func gen(v: VarDecl) {
        if (v.isStatic() || v.isPublic()) {
            return
        }
        let name = v.identifier
        if (exclusion.contains(name.value)) {
            return
        }
        let t = v.declType
        let mutable = v.keyword.value == 'var'
        v.identifier = Token(IDENTIFIER, v.identifier.value + '_')
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
        appended.add(
            PropDecl(
                quote(
            public $mutToken prop $name: $(t){
                get(){
                    $(v.identifier)
                }
                $(setter)
            }
        )
            ))
    }
    for (decl in decls) {
        match (decl) {
            case d: VarDecl where !(d.isStatic() || d.isPublic()) => gen(d)
            case d: PrimaryCtorDecl =>
                let vars = ArrayList<Decl>()
                let assigns = ArrayList<Node>()
                let args = ArrayList<FuncParam>()
                for (p in d.funcParams where p.isMemberParam()) {
                    let member = VarDecl()
                    member.modifiers = p.modifiers
                    member.keyword = p.keyword
                    member.identifier = p.identifier
                    member.colon = p.colon
                    member.declType = p.paramType
                    if (p.assign.kind.toString() == 'ASSIGN') {
                        member.assign = p.assign
                        member.expr = p.expr
                    }
                    vars.add(member)
                    args.add(p)
                    p.modifiers = ArrayList<Modifier>()
                    p.keyword = Token(ILLEGAL)
                    gen(member)
                    assigns.add(parseExpr(quote(this.$(member.identifier) = $(p.identifier))))
                }
                for (i in 0..vars.size) {
                    decls.add(vars[i], at: i)
                }
                for (i in 0..assigns.size) {
                    d.block.nodes.add(assigns[i], at: i)
                }
            case _ => continue
        }
    }
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
        hashed += quote(hasher.write($(d.identifier))) + `nl`
    }
    d.body.decls.add(parseDecl(quote(
        private var __hAsh__ = 0
    )))
    d
        .body
        .decls
        .add(
            parseDecl(
                quote(
        public func hashCode(): Int64{
            if(__hAsh__ == 0){
                var hasher = DataHasher()
                $hashed
                __hAsh__ = hasher.finish()
            }
            __hAsh__
        }
    )
            ))
}

func generateEqual(d: ClassDecl, exclusion: HashSet<String>) {
    if (d.superTypes.isEmpty()) {
        d.upperBound = `upperbound`[0]
    }
    let typeName = quote($(d.identifier)$(d.genericParamTokens))
    d.superTypes.add(RefType(quote(Equatable<$typeName>)))
    var eq = quote((!(this is Hashable) || this.hashCode() == other.hashCode())) + `nl`
    for (d in d.body.decls where d is VarDecl &&
        !(isStatic(d) || exclusion.contains(d.identifier.value) || exclusion.contains('${d.identifier.value}_'))) {
        let declType = (d as VarDecl).getOrThrow().declType
        eq += `and` + quote(f_data_eq(this.$(d.identifier), other.$(d.identifier))) + `nl`
    }
    d
        .body
        .decls
        .add(
            all: [parseDecl(
                quote(
        public operator func ==(other: $typeName): Bool {
            $eq
        }
    )),
                parseDecl(
                quote(
        public operator func !=(other: $typeName): Bool {
            !(this == other)
        }
    )
            )])
}

func generateCompare(d: ClassDecl, exclusion: HashSet<String>) {
    if (d.superTypes.isEmpty()) {
        d.upperBound = `upperbound`[0]
    }
    let typeName = quote($(d.identifier)$(d.genericParamTokens))
    d.superTypes.add(RefType(quote(Comparable<$typeName>)))
    var cmp = `nl`
    for (d in d.body.decls where d is VarDecl &&
        !(isStatic(d) || exclusion.contains(d.identifier.value) || exclusion.contains('${d.identifier.value}_'))) {
        let declType = (d as VarDecl).getOrThrow().declType
        cmp += quote(f_data_cmp(this.$(d.identifier), other.$(d.identifier))) + `nl` + quote(
            if(result != EQ){
                return result
            }
        ) +
            `nl`
    }
    d
        .body
        .decls
        .add(
            parseDecl(
                quote(
        public func compare(other: $typeName): Ordering {
            var result = Ordering.EQ
            $cmp
            result
        }
    )
            ))
}

func generateToString(d: ClassDecl, exclusion: HashSet<String>) {
    if (d.superTypes.isEmpty()) {
        d.upperBound = `upperbound`[0]
    }
    d.superTypes.add(RefType(quote(ToString)))
    var str = quote(
        result.append<$(d.identifier)$(d.genericParamTokens)>()
    )
    var empty = true
    for (d in d.body.decls where d is VarDecl &&
        !(isStatic(d) || exclusion.contains(d.identifier.value) || exclusion.contains('${d.identifier.value}_'))) {
        str += `nl` + quote(result.append($(d.identifier.value), $(d.identifier)))
        empty = false
    }
    d
        .body
        .decls
        .add(
            parseDecl(
                quote(
        public func toString(): String {
            var result = DataToString()
            $str
            result.toString()
        }
    )
            ))
}

func generateToFields(d: ClassDecl, exclusion: HashSet<String>) {
    let klassDecl = (d as ClassDecl).getOrThrow {
        DataException("current decl ${d.identifier.value} must be a class decl")
    }
    let klassIdentifier = quote($(klassDecl.identifier)$(d.genericParamTokens))
    if (klassDecl.superTypes.isEmpty()) {
        klassDecl.upperBound = `upperbound`[0]
    }
    klassDecl.superTypes.add(RefType(quote(ObjectData<$(klassIdentifier)>)))
    let body = klassDecl.body.decls
    var fields = ArrayList<Expr>()
    for (d in body where (d is VarDecl || d is PropDecl) && !isStatic(d) && isPublic(d) &&
        !exclusion.contains(d.identifier.value)) {
        let expr = match (d) {
            case x: VarDecl =>
                var declType = x.declType.toTokens()
                if (declType[0].kind == QUEST) {
                    declType = declType[1..]
                } else if (declType[0].kind == IDENTIFIER && declType[0].value == 'Option') {
                    declType = declType[2..declType.size - 1]
                }
                if (x.isVar()) {
                    TrailingClosureExpr(
                        quote(
                            MutableField.new<$(klassIdentifier), $(declType)>($(x.identifier.value), {o => o.$(x.identifier)}){o, v => o.$(x.identifier) = v})
                    )
                } else {
                    TrailingClosureExpr(
                        quote(
                            ReadonlyField.new<$(klassIdentifier), $(declType)>($(x.identifier.value)){o => o.$(x.identifier)})
                    )
                }
            case x: PropDecl =>
                var declType = x.declType.toTokens()
                if (declType[0].kind == QUEST) {
                    declType = declType[1..]
                } else if (declType[0].kind == IDENTIFIER && declType[0].value == 'Option') {
                    declType = declType[2..declType.size - 1]
                }
                if (x.isMut()) {
                    TrailingClosureExpr(
                        quote(
                            MutableField.new<$(klassIdentifier), $(declType)>($(x.identifier.value), {o => o.$(x.identifier)}){o, v => o.$(x.identifier) = v})
                    )
                } else {
                    TrailingClosureExpr(
                        quote(
                            ReadonlyField.new<$(klassIdentifier), $(declType)>($(x.identifier.value)){o => o.$(x.identifier)})
                    )
                }
            case _ => continue
        }
        fields.add(expr)
    }
    let openModi = if (klassDecl.isAbstract() || klassDecl.isOpen()) {
        `open`
    } else {
        `empty_tokens`
    }
    let fieldsName = Token(IDENTIFIER, "___dAtA__fIElds_")
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
            VarDecl(
                quote(
        private static let $(fieldsName) = ObjectFields<$klassIdentifier>($fieldTokens){
            $klassIdentifier()
        }
    )
            ),
            FuncDecl(
                quote(
        public static func dataFields(): ObjectFields<$klassIdentifier> {
            $fieldsName
        }
    )
            ),
            FuncDecl(
                quote(
        public $openModi func toData(): Data {
            DataObject<$klassIdentifier>(this)
        }
    )
            ),
            FuncDecl(
                quote(
        public static func tryFromData(data: Data, flag!: DataConversionFlag = SILENCE): Any {
            f_data_tryFromData<$klassIdentifier>(data, flag)
        }
    )
            )
        ]
    )
}
