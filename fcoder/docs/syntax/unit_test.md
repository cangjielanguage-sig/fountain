## 单元测试

### 测试宏

- `@Test` - 应用于顶级函数或类，转换为单元测试类
- `@TestCase` - 标记测试类内的函数为测试用例
- `@Fail` - 标记测试失败

### 断言宏

#### Assert 断言（失败停止用例）

```cj
@Assert(leftExpr, rightExpr)      // 判断相等
@Assert(condition: Bool)          // 判断条件
```

#### Expect 断言（失败继续执行）

```cj
@Expect(leftExpr, rightExpr)      // 判断相等
@Expect(condition: Bool)          // 判断条件
```

### 完整示例

```cj
import std.unittest.*
import std.unittest.testmacro.*
@Test
class LexerTest {
    @TestCase
    func test() {
        let a = 1

        // 方式一：手动判断
        if (a != 1) {
            @Fail("a is not 1")
        }

        // 方式二：Assert 条件
        @Assert(a != 1)

        // 方式三：Assert 相等
        @Assert(a, 1)
    }
}
```
