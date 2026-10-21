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
package fountain::f_jit.base

/**
 * 仓颉类型名 → `LocalType` 码（反射验签用）。
 *
 * 用途：`std.reflect` 的 `FunctionTypeInfo.parameters[i].name` / `returnType.name` 给出的是
 * **类型名字符串**（`Int64`、`String`、`ReflectUser`、`ArrayList<Int64>`…），而签名描述符存的是
 * `LocalType` 码。两者比对前需要这一层映射。
 *
 * **不能归到 14 的名字**由调用方用类注册表核对——本函数只做「看起来像宿主对象」的粗分类：
 * 内建与容器以外的一切都返回 `HOST_OBJECT`，具体类是否匹配由签名里的类名逐字比对。
 */
public class TypeNames {
    private init() {}

    /** 类型名 → 码；无法判定为内建/容器的一律 `HOST_OBJECT`（14）。 */
    public static func codeOf(name: String): UInt16 {
        match (name) {
            case 'Int64' => LocalType.I64
            case 'Float64' => LocalType.F64
            case 'Bool' => LocalType.BOOL
            case 'Unit' => LocalType.UNIT
            case 'String' => LocalType.STRING
            case 'Decimal' => LocalType.DECIMAL
            case 'DateTime' => LocalType.DATETIME
            case 'Duration' => LocalType.DURATION
            case 'Range' => LocalType.RANGE
            case 'Regex' => LocalType.REGEX
            // M3：JSON 内建码（16–19）——反射侧 `TypeInfo.name` 就是这几个短名
            case 'JsonValue' => LocalType.JSON_VALUE
            case 'JsonObject' => LocalType.JSON_OBJECT
            case 'JsonArray' => LocalType.JSON_ARRAY
            case 'JsonNull' => LocalType.JSON_NULL
            case _ =>
                if (name.startsWith('ArrayList<') || name.startsWith('List<') ||
                    name.startsWith('Array<')) {
                    LocalType.LIST
                } else if (name.startsWith('HashMap<') || name.startsWith('Map<')) {
                    LocalType.MAP
                } else if (name.startsWith('(') || name.contains('->')) {
                    // 函数类型：签名里 T/R 禁高阶，落到 NONE 让验签直接失败
                    LocalType.NONE
                } else {
                    LocalType.HOST_OBJECT
                }
        }
    }
}
