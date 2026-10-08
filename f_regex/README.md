# f_regex

## STDX依赖

配置环境变量：`export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`

正则表达式扩展、正则缓存与正则DSL。也可以使用`fountain::fountain.regex`包使用本模块的同名API。

## 正则表达式扩展

```cj
public interface ExtendRegex {
    /**判定整数的正则表达式*/
    static prop INTEGER: Regex
    /**判定小数的正则表达式*/
    static prop DECIMAL: Regex
    /**判定实数的正则表达式*/
    static prop REAL_NUMBER: Regex
    /**判定电邮的正则表达式*/
    static prop EMAIL: Regex
    /**判定Duration字符串的正则表达式*/
    static prop DURATION: Regex
    /**判定标识符的正则表达式*/
    static prop IDENTIFIER: Regex
    /**判定BASE64的正则表达式*/
    static prop BASE64: Regex
    /**把带通配符的字符串转换为正则表达式*/
    static func wildcard(wildcard: String): Regex
    /**从index开始查找input替换第一个找到的子串*/
    func doReplace(input: String, replacement!: String, index!: Int64): String
    /**替换index后面所有的子串*/
    func doReplaceAll(input: String, replacement!: String, index!: Int64): String
    /**替换index后面所有的子串，替换的子串是replacement的返回值，如果返回了None就不替换*/
    func doReplaceAll(input: String, replacement!: (MatchData) -> ?String, index!: Int64): String
}
```

## 字符串扩展

```cj
/**
 * 字符串扩展此接口，将当前字符串初始化为正则表达式
 * solid如果是true，则正则表达式会在整个进程生命周期内存在，否则会使用fountain::f_cache.HeapCache缓存，最多缓存10000个正则表达式，缓存寿命是一天
 */
public interface RegexFromString {
    func regex(flags!: Array<RegexFlag>, solid!: Bool): Regex
}
```

## 正则DSL

`RegexBuilder`把常用的正则片段串成可读的构造式（不可变，每次调用返回新的builder）：

```cj
public class RegexBuilder <: ToString & Equatable<RegexBuilder> {
    public func build(flags!: Array<RegexFlag> = [], solid!: Bool = false): Regex
    // 字符类：digit / notDigit / whitespace / wordChar / alpha / lowerAlpha / upperAlpha / boundary / decimal ...
    // 量词：zeroOrOne / zeroOrMore / oneOrMore / greedy / notGreedy / startRange(min) / endRange(max) / range(min, max)
    // 分组：group(part) / group(dir, part) / notCapture / lookAhead / notLookAhead / lookBehind / notLookBehind
    // 字符集：builder[parts]、builder[notIn: true, parts]
    // 断言：start / end / any
    public func text(part: ToString): RegexBuilder
    public func oneOf<T>(parts: Iterable<T>): RegexBuilder where T <: ToString
}
```

配套类型：`SearchDirection`（分组方向）、`RegexReplacement`（`$n` 形式的替换模板）、`RegexBuilderException`。

```cj
import fountain::f_regex.*

let re = RegexBuilder()
    .start
    .oneOf(['a', 'b'])
    .digit.oneOrMore
    .end
    .build()
re.matches('a123')  // true
```

## 注意事项

- `regex(flags:, solid: true)`的实例常驻进程（每次访问静态prop都会编译），`solid: false`走`HeapCache`缓存（上限10000、寿命一天，`Regex`对象被回收后缓存可能失效）。
- `doReplace`/`doReplaceAll`的`index`是**字节下标**（`String[index..]`），中文等多字节字符需要自己换算。
- `RegexBuilder`的每个prop/func都返回新实例，可以安全地分叉复用。

---

## 其他公开 API

以下声明未在上文展开，按「模块级 / 类型」分组列出（`extend` 里的成员归到被扩展的类型）；完整语义见 `src/` 下对应文件。

- `RegexBuilder`：`prop alpha: RegexBuilder`、`prop alphaDigit: RegexBuilder`、`prop any: RegexBuilder`、`prop blank: RegexBuilder`、`prop boundary: RegexBuilder`、`prop decimal: RegexBuilder`、`greedy`（prop）、`prop headBlanks: RegexBuilder`、`prop headOrTailBlanks: RegexBuilder`、`prop lookAhead: RegexBuilder`、`prop lookBehind: RegexBuilder`、`prop lowerAlpha: RegexBuilder`、`prop lowerAlphaDigit: RegexBuilder`、`prop lparan: RegexBuilder`、`prop lsquare: RegexBuilder`、`prop notAlpha: RegexBuilder`、`prop notAlphaDigit: RegexBuilder`、`prop notBlank: RegexBuilder`、`prop notCapture: RegexBuilder`、`prop notDigit: RegexBuilder`、`prop notGreedy: RegexBuilder`、`prop notLookAhead: RegexBuilder`、`prop notLookBehind: RegexBuilder`、`prop notLowerAlpha: RegexBuilder`、`prop notLowerAlphaDigit: RegexBuilder`、`func notOneOf<T>(parts: Iterable<T>): RegexBuilder where T <: ToString`、`prop notUpperAlpha: RegexBuilder`、`prop notUpperAlphaDigit: RegexBuilder`、`prop notWhitespace: RegexBuilder`、`prop notWordChar: RegexBuilder`、`prop or: RegexBuilder`、`prop rparan: RegexBuilder`、`prop rsquare: RegexBuilder`、`prop tailBlanks: RegexBuilder`、`prop upperAlpha: RegexBuilder`、`prop upperAlphaDigit: RegexBuilder`、`version`（prop）、`prop whitespace: RegexBuilder`、`prop wordChar: RegexBuilder`、`prop zeroOrMore: RegexBuilder`、`prop zeroOrOne: RegexBuilder`
