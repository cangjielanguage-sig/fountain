高级特性
- `const`
- 注解
- 宏
---

## 常量
- 编译时求值
- 用关键词`const`声明
- 不可修改
满足以下规则的表达式可以用来声明常量：
1. 数值类型、Bool、Unit、Rune、String 类型的字面量（不包含插值字符串）。
2. 所有元素都是 const 表达式的 Array 字面量（不能是 Array 类型，可以使用 VArray 类型），tuple 字面量。
3. const 变量，const 函数形参，const 函数中的局部变量。
4. const 函数，包含使用 const 声明的函数名、符合 const 函数要求的 lambda、以及这些函数返回的函数表达式。
5. const 函数调用（包含 const 构造函数），该函数的表达式必须是 const 表达式，所有实参必须都是 const 表达式。
6. 所有参数都是 const 表达式的 enum 构造器调用，和无参数的 enum 构造器。
7. 数值类型、Bool、Unit、Rune、String 类型的算术表达式、关系表达式、位运算表达式，所有操作数都必须是 const 表达式。
8. if、match、try、throw、return、is、as。这些表达式内的表达式必须都是 const 表达式。
9. const 表达式的成员访问（不包含属性的访问），tuple 的索引访问。
10. const init 和 const 函数中的 this 和 super 表达式。
11. const 表达式的 const 实例成员函数调用，且所有实参必须都是 const 表达式。

## 注解
- 使用`@Annotation`修饰的类
- 至少有一个构造函数使用`const`声明，且只有const构造函数可以用于注解初始化
- 注解可以用`@AnnotationName` `@Annotation[注解的const构造函数实参]`修饰一个声明，注解可修饰的声明由`@Annotation[target: [可修饰的声明种类]]`，默认是所有种类的声明都可以
- 声明带着的注解只有运行期可见，对宏不可见
```cj
public enum AnnotationKind {
    | Type //被Type标注的注解可修饰类 结构体 接口 枚举的声明
    | Parameter //可修饰函数形参
    | Init //可修饰构造函数
    | MemberProperty //可修饰成员属性
    | MemberFunction //可修饰成员函数
    | MemberVariable //可修饰成员变量
    | EnumConstructor //可修饰枚举构造器
    | GlobalFunction //可修饰顶级函数声明
    | GlobalVariable //可修饰顶变量声明
    | Extension //可修饰扩展
    | 
}
```

## 宏
- 编译期元编程
- 只能是顶级声明
- 宏的包只能是macro package 声明，在macro package 只有宏可以是public，且宏只能是public，
- 宏以外的顶级声明只能是internal 或private
- 宏不可以嵌套声明，但是可以嵌套调用
    - 嵌套调用的宏，由内而外展开
    - 内部的嵌套宏可以借助`std.ast`的API向外部宏发送消息，外部宏可以收到内部宏发送的消息
```cj
macro package package_name.for_macro 
import std.ast.*
//Tokens是std.ast的类型，参数Tokens是被宏修饰的声明或表达式转换的Tokens，返回的是宏展开的结果，宏展开的结果应当是可被仓颉编译器编译运行的代码
//非属性宏
public macro MacroName(input: Tokens): Tokens {

}
//属性宏
//宏也可重载，但是宏要么只有一个input参数，要么有一个attr和一个input参数
//attr可以用来控制宏的行为以及定义一些元数据
public macro MacroName(attr: Tokens, input: Tokens): Tokens {
    //宏体
    //两个Tokens实例可以用+连接起来
    quote(
        let a = $(expr)
    )//quote() 这对括号里面包含的都会被编译器转换为Tokens
    //$() 包含的表达式可以正常运行，运行的结果会被转换为Tokens
}
```
⚠️ **重要**：`$(...)`只能在`quote()`内部使用
⚠️ **重要**：`$(token.value)`，value是字符串，这个`$(token.value)`的运行结果相当于以下代码
⚠️ **重要**：宏操作的都是声明类型实例（Decl）和表达式类型实例（Expr）跟Tokens之间的互相转换。
    - Token是一个结构体有两个成员，kind和value，kind是一个表示Token类型的枚举，value是表示Token内容的字体串。
    - Tokens是一个类，它内部是一系列Tokens，常用成员：
    ```cj
    prop size: Int64 //Tokens包含的Token数量
    operator func [](index: Int64): Token //返回指定索引的Token
    operator func [](index: Int64, value!: Token): Unit //修改指定索引的Token
    func iterator(): Iterator<Token> //遍历Tokens
    ```
```cj
let tv = token.value
let st = Token(STRING_LITERAL, tv)
let tokens = quote($(st))
tokens
```
```cj
@MacroName//可以用来修饰各种声明和表达式，甚至不符合仓颉语法的Tokens，只要输出的Tokens符合仓颉语法就可以
public class TypeName{}

@MacroName[....]//方括号内的就是宏的属性
public class TypeName2{}
```
