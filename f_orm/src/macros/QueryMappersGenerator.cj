/*
   Copyright (c) [2022] [WuJingrun（吴京润）]
   fountain is licensed under Mulan PSL v2.
   You can use this software according to the terms and conditions of the Mulan PSL v2.
   You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
   THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
   See the Mulan PSL v2 for more details.
 */

macro package f_orm.macros

import std.ast.*
import std.collection.HashMap
import std.convert.*
import std.sort.*
import f_macros.*
import f_orm.exception.ORMException
import f_util.CaseFormat

/**
 * 必须跟@ORMField配合使用
 * 使用宏@ORMField 注解public mut prop或public var指定当前属性或成员变量是不是主键以及映射的列名，所有的仓颉mut prop必须是驼峰命名法。
 * @ORMField[true LowerUnderScore dataType] 表示当前属性映射主键，属性名转为LowerUnderScore就是列名，列的类型是dataType。
 * @ORMField[true "column_name" dataType] 表示当前属性映射主键，不论属性名是什么列名一定是"column_name"。
 * 第一部分可以是true或false，true表示当前属性映射主键，false表示映射的不是主键。
 * dataType必须是枚举orm.dialect.DataType的值。
 * 每一部分都是可选的。
 * 没有使用@ORMField注解的按照映射的不是主键，且按照列名是LowerUnderScore处理。
 */
public macro QueryMappersGenerator(input: Tokens): Tokens {
    let decl = (parseDecl(input) as ClassDecl).getOrThrow{ORMException("QueryMappersGenerator supports a class")}
    let name = quote($(decl.identifier)$(decl.genericParam))
    let body = decl.body.decls
    let props = extractMutProps(body)
    let vars = extractVars(body)
    let map = HashMap<String, (Bool, String, Token)>()
    for (m in getChildMessages("ORMField")) {
        let name = m.getString("field")
        let id = if (m.hasItem("id")) {
            m.getBool("id")
        } else {
            false
        }
        let column = if (m.hasItem("column")) {
            m.getString("column")
        } else {
            ""
        }
        let dataType = if (m.hasItem("dataType")) {
            m.getString("dataType")
        } else {
            ""
        }
        map[name] = (id, column, Token(IDENTIFIER, dataType))
    }
    let mapperMetaFn = {
        n: String => if (let Some(m) <- map.get(n)) {
            m
        } else {
            (false, CaseFormat.Camel.convert(n, CaseFormat.LowerUnderScore), Token(IDENTIFIER, ""))
        }
    }
    var mappers = `lsquare` + generateMappers(name, props, mapperMetaFn)
    let varMappers = generateMappers(name, vars, mapperMetaFn)
    if (varMappers.size > 0) {
        mappers += `comma` + varMappers
    }
    mappers += `rsquare`
    let queryMappersName = Token(IDENTIFIER, "_qUEry__mAppErs_")
    let superTypes = decl.superTypes
    var mapperTokens = quote(
        let creator = {=> $name()}
        let mappers = $mappers
    ) + `nl`
    for(st in superTypes){
        mapperTokens += quote(
            if (let Some(x) <- QueryMappers<$st.create<$name>(creator, mappers)) {
                return x
            }
        ) + `nl`
    }
    if(superTypes.isEmpty()){
        decl.upperBound = `upperbound`[0]
    }
    decl.superTypes.add(QualifiedType(quote(orm.QueryMappersInit<$name>)))
    body.add(all: [parseDecl(quote(
        private static let $queryMappersName = {=>
            $mapperTokens
            QueryMappers<$name> (
                creator: creator,
                mappers: mappers
            )
        }()
    )), parseDecl(quote(
        public static prop isSimpleData: Bool {
            get(){
                false
            }
        }
    )), parseDecl(quote(
        public static func queryMappers(): QueryMappers<$name>{
            $queryMappersName
        }
    ))])
    decl.toTokens()
}
func generateMappers(name: Tokens, props: Array<PropDecl>, mapperMetaFn: (String) -> (Bool, String, Token)): Tokens {
    var tokens = `empty_tokens`
    var i = 0
    while (i < props.size) {
        if (i > 0) {
            tokens += `comma`
        }
        let decl = props[i]
        var propName = decl.identifier
        let dts = quote($(decl.declType))
        let meta = mapperMetaFn(propName.value)
        tokens += generateMappers(name, propName, dts, meta)
        i++
    }
    tokens
}
func generateMappers(name: Tokens, vars: Array<VarDecl>, mapperMetaFn: (String) -> (Bool, String, Token)): Tokens {
    var tokens = `empty_tokens`
    var i = 0
    while (i < vars.size) {
        if (i > 0) {
            tokens += `comma`
        }
        let decl = vars[i]
        var varName = decl.identifier
        let dts = quote($(decl.declType))
        let meta = mapperMetaFn(varName.value)
        tokens += generateMappers(name, varName, dts, meta)
        i++
    }
    tokens
}

func generateMappers(name: Tokens, fieldName: Token, dts: Tokens, meta: (Bool, String, Token)): Tokens {
    var j = 0
    var dataType = `empty_tokens`
    var nullable = false
    while (j < dts.size) {
        let dt = dts[j]
        if (j == 0 && dt.value == "?") {
            nullable = true
            dataType += quote(Option<)
        } else if (j == 0 && dt.value == "Option") {
            nullable = true
            dataType += dt
        } else {
            dataType += dt
        }
        j++
    }
    if (nullable) {
        dataType += `gt`
    }
    var origin = if (nullable) {
        dataType[2..dataType.size]
    } else {
        dataType
    }
    let fieldNameStr = Token(STRING_LITERAL, fieldName.value)
    let columnName = Token(STRING_LITERAL, meta[1])
    let columnType = meta[2]
    if (meta[0]) {
        if (columnType.value.isEmpty()) {
            quote(
                    IdQueryMapper<$dataType, $name>(
                        name: $columnName,
                        dataType: $(dataType).dataType,
                        putter: {o, v => o.$fieldName = orm.convert<$dataType>(v)}
                    )
                )
        } else {
            quote(
                    IdQueryMapper<$dataType, $name>(
                        name: $columnName,
                        dataType: DataType.$columnType,
                        putter: {o, v => o.$fieldName = orm.convert<$dataType>(v)}
                    )
                )
        }
    } else if (dataType[0].value == "ArrayList") {
        var listGeneric = `empty_tokens`
        var j = 2
        while (j < dataType.size - 1) {
            let dt = dataType[j]
            if (j == 2 && dt.value == "?") {
                nullable = true
                listGeneric += quote(Option<)
            } else if (j == 2 && dt.value == "Option") {
                nullable = true
                listGeneric += dt
            } else {
                listGeneric += dt
            }
            j++
        }
        if (nullable) {
            listGeneric += `gt`
        }
        if (nullable && columnType.value.isEmpty()) {
            quote(
                    if ($(listGeneric).isSimpleData) {
                        GroupedSingleQueryMapper<$listGeneric, $name>(
                            name: $columnName,
                            grouped: FieldQueryMapper<$listGeneric, $name>(
                                name: $columnName,
                                dataType: $(listGeneric).dataType,
                                putter: (o, v => o.$(fieldName) = v)
                            ),
                            groupedGetter: {o => o.$fieldName}
                        )
                    } else {
                        NullableGroupedQueryMapper<$listGeneric, $name>(
                            name: $columnName,
                            ignoreNone: false,
                            grouped: $(listGeneric).queryMappers,
                            groupedGetter: {o => o.$fieldName}
                        )
                    }
                )
        } else if (nullable) {
            quote(
                    if ($(listGeneric).isSimpleData) {
                        GroupedSingleQueryMapper<$listGeneric, $name>(
                            name: $columnName,
                            grouped: FieldQueryMapper<$listGeneric, $name>(
                                name: $columnName,
                                dataType: DataType.$columnType,
                                putter: (o, v => o.$(fieldName) = v)
                            ),
                            groupedGetter: {o => o.$fieldName}
                        )
                    } else {
                        NullableGroupedQueryMapper<$listGeneric, $name>(
                            name: $columnName,
                            ignoreNone: false,
                            grouped: DataType.$columnType,
                            groupedGetter: {o => o.$fieldName}
                        )
                    }
                )
        } else if (columnType.value == "") {
            quote(
                    if ($(listGeneric).isSimpleData) {
                        GroupedSingleQueryMapper<$listGeneric, $name>(
                            name: $columnName,
                            grouped: FieldQueryMapper<$listGeneric, $name>(
                                name: $columnName,
                                dataType: $(listGeneric).dataType,
                                putter: (o, v => o.$(fieldName) = v)
                            ),
                            groupedGetter: {o => o.$fieldName}
                        )
                    } else {
                        GroupedQueryMapper<$listGeneric, $name>(
                            name: $columnName,
                            grouped: $(listGeneric).queryMappers,
                            groupedGetter: {o => o.$fieldName}
                        )
                    }
                )
        } else {
            quote(
                    if ($(listGeneric).isSimpleData) {
                        GroupedSingleQueryMapper<$listGeneric, $name>(
                            name: $columnName,
                            grouped: FieldQueryMapper<$listGeneric, $name>(
                                name: $columnName,
                                dataType: DataType.$columnType,
                                putter: (o, v => o.$(fieldName) = v)
                            ),
                            groupedGetter: {o => o.$fieldName}
                        )
                    } else {
                        GroupedQueryMapper<$listGeneric, $name>(
                            name: $columnName,
                            grouped: DataType.$columnType,
                            groupedGetter: {o => o.$fieldName}
                        )
                    }
                )
        }
    } else if (nullable && columnType.value == "") {
        quote(
                if ($(dataType).isSimpleData) {
                    FieldQueryMapper<$dataType, $name> (
                        name: $columnName,
                        dataType: $(dataType).dataType,
                        putter: {o, v => o.$fieldName = v}
                    )
                } else {
                    NullableNestQueryMapper<$origin, $name> (
                        name: $columnName,
                        nested: $(origin).queryMappers,
                        nestGetter: {o => o.$fieldName}
                        nestPutter: {o, v => o.$fieldName = v}
                    )
                }
            )
    } else if (nullable) {
        quote(
                if ($(dataType).isSimpleData) {
                    FieldQueryMapper<$dataType, $name> (
                        name: $columnName,
                        dataType: DataType.$columnType,
                        putter: {o, v => o.$fieldName = v}
                    )
                } else {
                    NullableNestQueryMapper<$origin, $name> (
                        name: $columnName,
                        nested: $(origin).queryMappers,
                        nestGetter: {o => o.$fieldName}
                        nestPutter: {o, v => o.$fieldName = v}
                    )
                }
            )
    } else if (columnType.value == "") {
        quote(
                if ($(dataType).isSimpleData) {
                    QueryMapper<$name> (
                        name: $columnName,
                        dataType: $(dataType).dataType,
                        putter: {o, v =>
                            o.$fieldName =
                            match(v){
                                case x: Option<$dataType> => x.getOrThrow{ORMException("current value for " + $fieldNameStr + " must not be None")}
                                case x: $dataType =>  x
                                case _ => throw ORMException("current value must be type of " + $(dataType).dataType.toString())
                            }
                    })
                } else {
                    NestQueryMapper<$dataType, $name> (
                        name: $columnName,
                        nested: $(dataType).queryMappers,
                        nestPutter: {o, v => o.$fieldName = v}
                    )
                }
            )
    } else {
        quote(
                if ($(dataType).isSimpleData) {
                    QueryMapper<$name> (
                        name: $columnName,
                        dataType: DataType.$columnType,
                        putter: {o, v =>
                            o.$fieldName =
                            match(v){
                                case x: Option<$dataType> => x.getOrThrow{ORMException("current value for " + $fieldNameStr + " must not be None")}
                                case x: $dataType =>  x
                                case _ => throw ORMException("current value must be type of " + $(dataType).dataType.toString())
                            }
                    })
                } else {
                    NestQueryMapper<$dataType, $name> (
                        name: $columnName,
                        nested: $(dataType).queryMappers,
                        nestPutter: {o, v => o.$fieldName = v}
                    )
                }
            )
    }
}
