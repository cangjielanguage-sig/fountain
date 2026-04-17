## tool call 函数定义
可以在一个类定义多个tool call函数
```cj
/**
 * 用来修饰类的公共实例函数，这个类必须被@ToolCall宏修饰
 */
@Annotation[target: [MemberFunction]]
public class FunctionDefinition {
    public const FunctionDefinition(
        public let name!: String,
        public let description!: String
    ){}
}
```

```cj
macro package fountain::f_llm.macros
/**
 * 用来定义tool call函数的宏，这个宏用来修饰类，被它修饰的类将被注册到fountain::f_bean，
 * 并且被它修饰的类的公共实例函数将被注册为tool call函数。
 * 只有被@FunctionDefinition修饰的函数才会被注册为tool call函数，否则将抛出异常。
 */
public macro ToolCall(input: Tokens): Tokens 
/**
 * 用来修饰类，这个类将被注册到fountain::f_bean，并且被它修饰的类的公共实例函数将被注册为tool call函数。
 * 只有被@FunctionDefinition修饰的函数才会被注册为tool call函数，否则将抛出异常。
 * 所不同的是这个宏的公共实例函数交被织入符合条件的切面。
 */
public macro WeavedToolCall(input: Tokens): Tokens 
```
