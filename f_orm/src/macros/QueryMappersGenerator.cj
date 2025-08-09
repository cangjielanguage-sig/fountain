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
    let decl = match(parseDecl(input)){
        case d: ClassDecl => d
        case d: MacroExpandDecl => 
            return replaceMacroInputDecl(quote(@QueryMappersGenerator), d).toTokens()
        case _ => 
            diagReport(ERROR, input, 'QueryMappersGenerator supports a class', '')
            throw ORMException("QueryMappersGenerator supports a class") 
    }
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
    ) +
        `nl`
    for (st in superTypes) {
        mapperTokens += quote(
            if (let Some(x) <- QueryMappers<$st.create<$name>(creator, mappers)) {
                return x
            }
        ) +
            `nl`
    }
    if (superTypes.isEmpty()) {
        decl.upperBound = `upperbound`[0]
    }
    decl.superTypes.add(QualifiedType(quote(orm.QueryMappersInit<$name>)))
    body.add(
        all: [parseDecl(
            quote(
        private static let $queryMappersName = {=>
            $mapperTokens
            QueryMappers<$name> (
                creator: creator,
                mappers: mappers
            )
        }()
    )),
            parseDecl(
            quote(
        public static prop isSimpleData: Bool {
            get(){
                false
            }
        }
    )),
            parseDecl(
            quote(
        public static func queryMappers(): QueryMappers<$name>{
            $queryMappersName
        }
    ))])
    decl.toTokens()
}

func generateMappers(name: Tokens, props: Array<PropDecl>, mapperMetaFn: (String) -> (Bool, String, Token)): Tokens {
    var tokens = `empty_tokens`
    for (i in 0..props.size) {
        if (i > 0) {
            tokens += `comma`
        }
        let decl = props[i]
        var propName = decl.identifier
        let dts = quote($(decl.declType))
        let meta = mapperMetaFn(propName.value)
        tokens += generateMappers(name, propName, dts, meta)
    }
    tokens
}

func generateMappers(name: Tokens, vars: Array<VarDecl>, mapperMetaFn: (String) -> (Bool, String, Token)): Tokens {
    var tokens = `empty_tokens`
    for (i in 0..vars.size) {
        if (i > 0) {
            tokens += `comma`
        }
        let decl = vars[i]
        var varName = decl.identifier
        let dts = quote($(decl.declType))
        let meta = mapperMetaFn(varName.value)
        tokens += generateMappers(name, varName, dts, meta)
    }
    tokens
}

func generateMappers(name: Tokens, fieldName: Token, dts: Tokens, meta: (Bool, String, Token)): Tokens {
    var dataType = `empty_tokens`
    var nullable = false
    for (j in 0..dts.size) {
        let dt = dts[j]
        if (j == 0 && dt.value == "?") {
            nullable = true
            dataType += dts[j + 1]
        } else if (j == 0 && dt.value == "Option") {
            nullable = true
            dataType += dts[j + 2]
        } else {
            dataType += dt
        }
        break
    }
    let dataTypeToken = Token(IDENTIFIER, '${dataType[0].value}DataType')
    let fieldNameStr = Token(STRING_LITERAL, fieldName.value)
    let columnName = Token(STRING_LITERAL, meta[1])
    let columnType = meta[2]
    if (meta[0]) {
        if (columnType.value.isEmpty()) {
            quote(
                    IdQueryMapper<$dataType, $name>(
                        dataType: $(dataTypeToken)($nullable, $columnName),
                        putter: {o, v => o.$fieldName = orm.convert<$dataType>(v)}
                    )
                )
        } else {
            quote(
                    IdQueryMapper<$dataType, $name>(
                        dataType: $(dataTypeToken)($nullable, $columnName),
                        putter: {o, v => o.$fieldName = orm.convert<$dataType>(v)}
                    )
                )
        }
    } else if (dataType[0].value == "ArrayList") {
        var listGeneric = `empty_tokens`
        for (j in 2..dataType.size - 1) {
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
        }
        if (nullable) {
            listGeneric += `gt`
        }
        if (nullable && columnType.value.isEmpty()) {
            quote(
                    if ($(listGeneric) is InputStream || $(listGeneric).isSimpleData()) {
                        GroupedSingleQueryMapper<$listGeneric, $name>(
                            name: $columnName,
                            groupedGetter: {o => o.$fieldName}
                        )
                    } else {
                        NullableGroupedQueryMapper<$listGeneric, $name>(
                            ignoreNone: false,
                            grouped: $(listGeneric).queryMappers,
                            groupedGetter: {o => o.$fieldName}
                        )
                    }
                )
        } else if (nullable) {
            quote(
                    if ($(listGeneric) is InputStream || $(listGeneric).isSimpleData()) {
                        GroupedSingleQueryMapper<$listGeneric, $name>(
                            name: $columnName,
                            groupedGetter: {o => o.$fieldName}
                        )
                    } else {
                        NullableGroupedQueryMapper<$listGeneric, $name>(
                            ignoreNone: false,
                            grouped: $(listGeneric).queryMappers,
                            groupedGetter: {o => o.$fieldName}
                        )
                    }
                )
        } else if (columnType.value == "") {
            quote(
                    if ($(listGeneric) is InputStream || $(listGeneric).isSimpleData()) {
                        GroupedSingleQueryMapper<$listGeneric, $name>(
                            name: $columnName,
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
                    if ($(listGeneric) is InputStream || $(listGeneric).isSimpleData()) {
                        GroupedSingleQueryMapper<$listGeneric, $name>(
                            name: $columnName,
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
        }
    } else if (nullable && columnType.value == "") {
        quote(
                if($(dataType) is InputStream){
                    FieldQueryMapper<$dataType, $name> (
                        dataType: InputStreamDataType($nullable, $columnName),
                        putter: {o, v => o.$fieldName = v}
                    )
                }else if ($(dataType).isSimpleData()) {
                    FieldQueryMapper<$dataType, $name> (
                        dataType: $(dataTypeToken)($nullable, $columnName),
                        putter: {o, v => o.$fieldName = v}
                    )
                } else {
                    NullableNestQueryMapper<$dataType, $name> (
                        nested: $(dataType).queryMappers,
                        nestGetter: {o => o.$fieldName}
                        nestPutter: {o, v => o.$fieldName = v}
                    )
                }
            )
    } else if (nullable) {
        quote(
                if($(dataType) is InputStream){
                    FieldQueryMapper<$dataType, $name> (
                        dataType: InputStreamDataType($nullable, $columnName),
                        putter: {o, v => o.$fieldName = v}
                    )
                }else if ($(dataType).isSimpleData()) {
                    FieldQueryMapper<$dataType, $name> (
                        dataType: $(dataTypeToken)($nullable, $columnName),
                        putter: {o, v => o.$fieldName = v}
                    )
                } else {
                    NullableNestQueryMapper<$dataType, $name> (
                        nested: $(dataType).queryMappers,
                        nestGetter: {o => o.$fieldName}
                        nestPutter: {o, v => o.$fieldName = v}
                    )
                }
            )
    } else if (columnType.value == "") {
        quote(
                if($(dataType) is InputStream){
                    QueryMapper<$name> (
                        dataType: InputStreamDataType($nullable, $columnName),
                        putter: {o, v =>
                            o.$fieldName =
                            match(v){
                                case x: Option<$dataType> => x.getOrThrow{ORMException("current value for " + $fieldNameStr + " must not be None")}
                                case x: $dataType =>  x
                                case _ => throw ORMException("current value must be type of " + $(dataType).dataType.toString())
                            }
                    })
                }else if ($(dataType).isSimpleData()) {
                    QueryMapper<$name> (
                        dataType: $(dataTypeToken)($nullable, $columnName),
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
                        nested: $(dataType).queryMappers,
                        nestPutter: {o, v => o.$fieldName = v}
                    )
                }
            )
    } else {
        quote(
                if($(dataType) is InputStream){
                    QueryMapper<$name> (
                        dataType: InputStreamDataType($nullable, $columnName),
                        putter: {o, v =>
                            o.$fieldName =
                            match(v){
                                case x: Option<$dataType> => x.getOrThrow{ORMException("current value for " + $fieldNameStr + " must not be None")}
                                case x: $dataType =>  x
                                case _ => throw ORMException("current value must be type of " + $(dataType).dataType.toString())
                            }
                    })
                }else if ($(dataType).isSimpleData()) {
                    QueryMapper<$name> (
                        dataType: $(dataTypeToken)($nullable, $columnName),
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
                        nested: $(dataType).queryMappers,
                        nestPutter: {o, v => o.$fieldName = v}
                    )
                }
            )
    }
}
