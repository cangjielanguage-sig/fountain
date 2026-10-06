# f_exception

语义化异常名库：统一挂在`f_base.BaseException`下，供各模块抛出/捕获。

```cj
public import fountain::f_base.BaseException

// 每个异常类都是同一个模子：
public class XXXException <: BaseException {
    public init()
    public init(message: String)
    public init(caused: Exception)
    public init(message: String, caused: Exception)
}
```

也可以使用`fountain::fountain.exception`包使用本模块的同名API。

## 异常清单

| 类型 | 用途 |
|---|---|
| `DuplicateInstanceException` | 实例/单例重复 |
| `IllegalAccessException` | 非法访问（未初始化、越权使用） |
| `IllegalArgException` | 非法参数（**不是**std的`IllegalArgumentException`） |
| `IllegalSizeException` | 长度/大小非法 |
| `IllegalStateException` | 对象状态不允许该操作 |
| `NoSuchElementException` | 无元素可取 |
| `NotConsideredException` | 逻辑上未考虑的分支 |
| `NotInstantiatedException` | 尚未实例化/初始化 |
| `NotSupportedTypeException` | 不支持的类型 |
| `NumberFormatException` | 数字格式错误 |
| `OutOfBoundsException` | 越界（**不是**std的`IndexOutOfBoundsException`） |
| `StatusException` | 状态（机）不对 |
| `TypeCastException` | 类型转换失败 |
| `TypeNotMatchException` | 类型不匹配 |
| `UnexpectedTokenException` | 意外的token（词法/语法/协议解析） |
| `UnreachableException` | 不可达分支（`match`兜底最常用） |
| `UnreadableException` | 不可读 |
| `UnsupportedAccessException` | 不支持的访问方式 |
| `UnsupportedOperatorException` | 不支持的运算符 |
| `UnwritableException` | 不可写 |

## 使用示例

```cj
import fountain::f_exception.*

func parsePort(s: String): Int64 {
    if (s.isEmpty()) {
        throw IllegalArgException('illegal port: ${s}')
    }
    Int64.parse(s)
}

let ex = IllegalStateException('cleanup failed')
ex.addSuppressed(UnreadableException('cannot read tmp file'))  // BaseException 支持被压制异常
ex.printStackTrace(stdOutWriter())
```

## 注意事项

- 所有异常都只有4个构造器、**没有额外字段**：需要带上下文（索引、键名）时只能写进`message`，或自行继承添加字段（`f_pool`的`UnknownKeyException`就是加`key`字段的例子）。
- `IllegalArgException`/`OutOfBoundsException`/`NumberFormatException`等与std同名异常**不是同一类型**，按std异常名`catch`捕获不到本模块的异常。
