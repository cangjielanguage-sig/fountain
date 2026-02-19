# 仓颉语言基础语法参考

> **重要提示**：本文档标注 ⚠️ 的内容为实际使用中容易出错的关键点，AI 编写仓颉代码时请特别关注。

仓颉语言（Cangjie），文件后缀为 `.cj`，简称 `cj`。

---
## 名词解释
- **类型推断：**任意变量、函数声明和任意表达式都可做类型推断
- **顶级声明：**在包声明下面的声明

## main函数
返回类型是Unit或Int64
```cj
main(){//推断为Unit
    println('helloworld')
}
```
```cj
//args是命令行参数
main(args: Array<String>){
    println(args)
}
```
```cj
main(){//推断为Int64
    println('helloworld')
    0
}
```

## 变量声明
- 可以是class struct的成员
- 可以是顶级声明
- 可以是函数体内的局部变量
### 基本语法

```cj
修饰符 变量名: 变量类型 = 初始值
```

###修饰符详解

#### 可变性修饰符

- `let` - **不可变变量**（只能赋值一次，即初始化）
- `var` - **可变变量**（可以被多次赋值）
##### 示例代码

```cj
main() {
    let a: Int64 = 20      // 不可变变量
    var b: Int64 = 12      // 可变变量
    b = 23                // 可以修改 var 变量，赋值表达式的类型是Unit
    println("${a}${b}")
}

⚠️ **重要**：仓颉的 `let` **不支持**像 Rust 那样的变量遮蔽（shadowing），不能在同一个作用域内重新定义同名变量。

#### 声明可见性修饰符

- `private` - class/struct/enum 声明内部可见
- `public` - 任意模块任意包均可见
- `protected` - 当前模块及当前类的子类可见
- `internal` - 仅当前包及子包内可见（**声明可见性的默认值**）

#### 导入可见性

- `internal import` - 这类导入可在当前包的任意代码文件可见，同包的其它代码文件不必重复导入

#### 静态性修饰符

- `static` 
  - `static var` 或 `static let` - 静态成员变量变量必须在类型实例化前完成初始化
  - `static prop` 或 `static mut prop` 或 `static func` 或 `static mut func` - 静态成员属性、静态成员函数不必实例化即可访问，类型内部可以直接在任意成员属性或成员函数内部访问，类型外部可以使用类型名访问.
    - eg. 
        - `TypeName.staticProp` 
        - `TypeName.staticFunc()`
        - `TypeName.staticVariable = 10`
        - `TypeName.staticVariable += 10`
        - `let v = TypeName.staticVariable`

```

---

## 基础类型

### 数值类型

**有符号整数**：`Int8`、`Int16`、`Int32`、`Int64`、`IntNative`

**无符号整数**：`UInt8`、`UInt16`、`UInt32`、`UInt64`、`UIntNative`

**浮点类型**：`Float16`、`Float32`、`Float64`

#### 整型溢出策略
使用以下注解修饰函数，则这个函数内的所有算术运算都按照这个策略执行
- **@OverflowThrowing**: 抛出异常，溢出时抛出异常，**默认行为**
- **@OverflowWrapping**：高位截断，溢出时截断超出当前类型内存究竟的部分，与其它主流编程语言一致的行为
- **@OverflowSaturating**: 饱和，上溢出时取当前类型最大值，下溢出时取当前类型最小值

### 布尔类型

**Bool**:`true`、`false`

### 字符类型（Rune）

使用 `Rune` 表示，可以表示 Unicode 字符集中的所有字符。

```cj
let a: Rune = r'a'
```

#### Rune 转换

- **Rune → UInt32**：`UInt32(e)` - 获取 Unicode scalar value
- **整数 → Rune**：`Rune(num)` - 值必须在有效 Unicode 范围内
  - 有效范围：`[0x0000, 0xD7FF]` 或 `[0xE000, 0x10FFFF]`
  - 编译时可确定值 → 编译报错
  - 运行时确定值 → 抛异常

#### 转义字符

```cj
let slash: Rune = r'\\'
let newLine: Rune = r'\n'
let tab: Rune = r'\t'
```

#### Unicode 字面量

```cj
let he: Rune = r'\u{4f60}'   // 你
let llo: Rune = r'\u{597d}'   // 好
```

### 字符串类型（String）

#### 基本用法

```cj
let s2 = "Hello Cangjie Lang"
```

#### 插值字符串

⚠️ **注意**：插值字符串中使用 `${}` 表达式

```cj
let fruit = "apples"
let count = 10
let s = "There are ${count * count} ${fruit}"
```

#### 字符串转 Rune 数组

```cj
"apples".toRuneArray()
```

#### 多行原始字符串字面量

⚠️ **重要**：以井号（`#`）和引号开头/结尾，**转义规则不适用**

```cj
let s1: String = #""#                              // 空字符串
let s2 = ##'\n'##                                  // \n 不是换行符，是 \ 和 n 两个字符
let s3 = ###"
    Hello,
    Cangjie
    Lang"###
```

### 元组（Tuple）

- **类型表示**：`(T1, T2, ..., TN)`
- **至少二元**：`(Int64, Float64)`、`(Int64, Float64, String)`
- **索引访问**：`tuple[0]`、`tuple[1]`

```cj
var tuple = (true, false)
println(tuple[0])
```

### 数组类型

```cj
Array<T>  // T 是元素类型，可以是任意类型
```

### 区间类型（Range）

- **类型表示**：`Range<T>`（泛型）
- **包含三个值**：`start`、`end`、`step`
- **约束**：
  - `start` 和 `end` 类型相同（T）
  - `step` 类型是 `Int64`
  - `step` 值不能等于 0
  - `step` 可省略，默认是1
- 例子
```cj
1..11 //前闭后开区间
1..=11 //前闭后闭区间
1..11:2 //前闭后开区间，从1开始，步长为2
1..=11:2 //前闭后闭区间，从1开始，步长为2
1..=11:0 //报错，步长不能为0
11..=1:-1 前闭后闭区间，从11开始向下递减，步长为-1
11..1:-2闭闭后开区间，从11开始向下递减，步长为-2
```

### Unit 类型

- **唯一值**：`()`
- **支持操作**：仅赋值、判等、判不等、hashCode()
- ⚠️ **不支持**：其他所有操作

---

### Nothing 类型

- `break` `continue` `throw` `return` 表达式的类型都是`Nothing`
- ⚠️ **不支持**：任意运算、显示声明

## 表达式与控制流

⚠️ **仓颉代码除了声明就是表达式，表达式一定有一个值**
⚠️ **所有循环表达式的值都是`Unit`**

### ⚠️ 分支表达式括号（重要）

**分支表达式的括号不能省略**，这是与很多语言的差异：

### ⚠️ 分支表达式的类型推断
- 每个分支的最后一个表达式的最小公共父类型即为整个分支表达式的值的类型
  - 推断`Any`为最小公共父类型的分支表达式时
    - 不能作为赋值表达式的右值，否则会编译出错
    - 作为函数的最后一个表达式时，只有函数类型明确声明为`Unit`才可以编译

```cj
if (条件) {        // ✅ 必须有括号
    分支 1
} else {
    分支 2
}
```

### if 表达式

⚠️ **if表达式的值**
- 没有else的if表达式的值是`Unit`


#### 基本形式

```cj
if (条件) {
    分支 1
} else {
    分支 2
}
```

### 循环表达式

⚠️ **所有循环表达式都是`Unit`类型**

#### while 表达式

```cj
while (条件) {
    循环体
}

// do-while 形式
do {
    循环体
} while (条件)
```

#### for-in 表达式

```cj
for (迭代变量 in 序列) {
    循环体
}
```

```cj
//逻辑表达式为true的才会执行循环体，否则会跳过当前迭代的值
for(迭代变量 in 序列 where 逻辑表达式) {
    循环体
}
```

##### 元组遍历

```cj
let array = [(1, 2), (3, 4), (5, 6)]
for ((x, y) in array) {
    println("${x}, ${y}")
}
```

##### 区间遍历

```cj
main() {
    var sum = 0
    for (i in 1..=100) {    // 1 到 100（包含）
        sum += i
    }
    println(sum)
}
```

#### ⚠️ 跳转控制（重要）

- 支持 `break`、`continue`
- ⚠️ **不支持标签跳转**
- ⚠️ **完全不支持 `goto`**

---

## 函数

### 函数是一等公民

- 可以作为函数的参数或返回值
- 可以赋值给变量
- 函数本身也有类型
- 可以是class struct enum interface 的成员
- 可以是顶级声明
- 可以在另一个函数体内声明

### 函数类型

**语法**：`(参数类型) -> 返回类型`

- 参数类型用 `()` 括起，多个参数用 `,` 分隔
- 参数类型和返回类型用 `->` 连接

```cj
func add(a: Int64, b: Int64): Int64 {
    return a + b
}

type FnType = (Int64) -> Unit

func display(a: Int64): Unit {
    println(a)
}

// 命名参数:
func name(name!:string)

// 命名参数还可以设置默认值
func name(name!:String = "小王")
```

### ⚠️ 函数参数（重要）

**函数参数默认是 `let` 定义的不可变变量**

```cj
// a 和 b 都是不可变的
func add(a: Int64, b: Int64): Int64 {
    return a + b
}
```

### 返回值简写

```cj
func add(a: Int64, b: Int64): Int64 {
    a + b  // 最后一个表达式自动作为返回值
}

func returnAdd(): (Int64, Int64) -> Int64 {
    add  // 可以直接返回函数
}
```

### Lambda 表达式

#### 语法

```cj
{ p1: T1, ..., pn: Tn => expressions | declarations }
```

#### 示例

```cj
// 完整类型声明
let f1 = { a: Int64, b: Int64 => a + b }

// 无参 Lambda
var display = { =>
    println("Hello")
    println("World")
}

// 类型推断
var sum1: (Int64, Int64) -> Int64 = { a, b => a + b }
var sum2: (Int64, Int64) -> Int64 = { a: Int64, b => a + b }

// Lambda 作为参数
func f(a1: (Int64) -> Int64): Int64 {
    a1(1)
}

main(): Int64 {
    f({ a2 => a2 + 10 })  // 参数类型推断
}
```

#### ⚠️ Lambda 立即调用

```cj
let r2 = { => 123 }()  // r2 = 123，立即执行
var g = { x: Int64 => println("x = ${x}") }
g(2)  // 调用 Lambda
```

---

## 枚举类型（enum）
- 只能是顶级声明

### 定义语法

- 以 `enum` 关头
- 构造器之间使用 `|` 分隔
- **至少存在一个有名字的构造器**
- 可以声明静态只读属性、实例成员属性、静态成员函数、实例成员函数
- 不可声明可读写属性和成员变量

```cj
enum RGBColor {
    | Red(UInt8) 
    | Green(UInt8) 
    | Blue(UInt8)
}
```

### 构造器类型

- **无参构造器**：`C`
- **有参构造器**：`C(p1, p2, ..., pn)`

---

## 模式匹配

### match 表达式

#### 基本语法
⚠️ **case**：不需要{}大括号

```cj
match (待匹配值) {
    case 模式1 => 处理1
    case 模式2 => 处理2
    case 模式3 where 逻辑表达式 => 处理3 // 匹配模式3且逻辑表达式成立的执行此分支
    case _ => 默认处理  // 通配符
}
```

#### 示例

```cj
main() {
    let x = 0
    match (x) {
        case 1 => print("x = 1")
        case 0 => print("x = 0")        // 匹配
        case 2 | 3 | 4 => print("other")  // 多值匹配
        case _ => print("其他")
    }
}
```

### 模式类型详解

#### 常量模式

支持：整数字面量、浮点数字面量、字符字面量、布尔字面量、字符串字面量、Unit 字面量

⚠️ **不支持**：字符串插值

#### 通配符模式

使用 `_` 表示，匹配任意值，通常作为最后一个 case

#### 绑定模式

使用标识符，匹配并绑定值

```cj
main() {
    let x = -10
    let y = match (x) {
        case 0 => "zero"
        case n => "x is not zero and x = ${n}"  // n 绑定匹配的值
    }
    println(y)
}
```

#### Tuple 模式

用于匹配元组值

```cj
main() {
    let tv = ("Alice", 24)
    let s = match (tv) {
        case ("Bob", age) => "Bob is ${age} years old"
        case ("Alice", age) => "Alice is ${age} years old"  // age 是绑定模式
        case (name, 100) => "${name} is 100 years old"
        case (_, _) => "someone"
    }
    println(s)
}
```

#### 类型模式

判断运行时类型是否是某个类型的子类型

```cj
main() {
    var d = Derived()
    var r = match (d) {
        case b: Base => b  // b 是类型模式，匹配 Base 类型
        case _ => 0
    }
    println("r = ${r}")
}
```

#### enum 模式

用于匹配 enum 类型的实例

```cj
enum TimeUnit {
    | Year(UInt64)
    | Month(UInt64)
}

main() {
    let x = Year(2)
    let s = match (x) {
        case Year(n) => "x has ${n * 12} months"      // 匹配
        case TimeUnit.Month(n) => "x has ${n} months"  // TimeUnit.Month 是完整路径
    }
    println(s)
}
```

#### ⚠️ 模式嵌套（重要）

Tuple 模式和 enum 模式可以嵌套任意模式

```cj
enum TimeUnit {
    | Year(UInt64)
    | Month(UInt64)
}

enum Command {
    | SetTimeUnit(TimeUnit)
    | GetTimeUnit
    | Quit
}

main() {
    let command = (SetTimeUnit(Year(2022)), SetTimeUnit(Year(2024)))
    match (command) {
        case (SetTimeUnit(Year(year)), _) => println("Set year ${year}")
        case (_, SetTimeUnit(Month(month))) => println("Set month ${month}")
        case _ => ()
    }
}
```

### if-let while-let模式匹配

⚠️ **<-**左面支持任意模式，右面可以是任意表达式
⚠️ 可以使用`&&`连接任意数量的模式匹配和逻辑表达式

**语法**：`let pattern <- expression`

- `pattern` - 模式，匹配 expression 的类型和内容
- `<-` - 模式匹配操作符
- `expression` - 表达式（优先级不能低于 `..`）

```cj
if (let 模式1 <- 表达式1 && let 模式2 <- 表达式2 && 逻辑表达式) {  // 两个模式都匹配
    分支体
}
while (let 模式 <- 表达式) {
    循环体
}
```

---

## Option 类型

### 定义

```cj
enum Option<T> {
    | Some(T)   // 有值
    | None      // 无值
}
```

### 常用方法
- `let a:Int64 = OptA ?? 0`
- `optA.isSome()` `optA.isNone()`
- `if (let Some(a) <- OptA) {...}`
- `optA ?? return xxx`
- `optA ?? throw Exception("xxx")`

### 使用场景

当需要表示某个类型可能有值，也可能没有值的时候使用。

---

## 类（class）
- 只能是顶级声明

### 定义语法

```cj
class ClassName {
    static let a = 0// 不可变静态成员变量
    static var b: String = '' // 可变静态成员变量
    static init(){// 静态初始化器
        // 可在此处初始化静态成员变量
    }
    let c: Int64// 实例成员变量
    var d: Bool
    
    public init(){// 构造函数，没有声明构造函数的默认会有一个公共无参构造函数
        // 可在构造函数初始化实例成员变量
        // 所有实例成员变量初始化前不可调用实例成员函数和实例成员属性
        this(0, false, '', f: '')//使用this访问另一个构造函数
    }

    public ClassName(c: Int64, d: Bool, let e: String, var f!: String){//主构造函数，与init构造函数不同的是可以带实例成员变量开有参
    //实例成员变量形参必须在普通形参后面
    //命名参数必须在非命名参数后面
    //命名的实例成员变量形参必须在非命名的实例成员变量形参后面
    //命名的参数也可以有默认值
    //主构造函数最多只能声明一个
        this.c = c
        this.d = d
    }

    /*
     * 属性的使用跟成员变量一样。类、结构体、接口都可以声明属性
     * let v = TypeName.staticProp // 取值
     * TypeName.mutStaticProp = v // 赋值
     */
    // 静态成员属性
    static prop readOnlyStaticPropName: PropType {
        get(){
            staticMember//可以是静态变量、另一个静态属性、静态函数
        }
    }
    static mut prop writableStaticPropName: PropType {
        get(){
            ...
        }
        set(value){
            this.varName = value
        }
    }
    // 实例成员属性
    prop readOnlyInstancePropName: PropType {
        get(){
            ...
        }
    }
    prop writableInstancePropName: PropType {
        get(){

        }
        set(value){

        }
    }
    
    // 静态成员函数
    // 实例成员函数
    // 操作符函数
}
```

### 示例

```cj
class Rectangle {
    let width: Int64
    let height: Int64

    public init(width: Int64, height: Int64) {
        this.width = width
        this.height = height
    }

    public func area() {
        width * height
    }
}

let rec = Rectangle(10, 20)
let l = rec.height  // l = 20
```

### ⚠️ 访问修饰符（重要）

对于 class 的成员（变量、属性、构造函数、函数）：

| 修饰符 | 含义 | **默认** |
|--------|------|---------|
| `private` | class 定义内可见 | ❌ |
| `internal` | 当前包及子包（含子包的子包）内可见 | ✅ **默认** |
| `protected` | 当前模块及当前类的子类可见 | ❌ |
| `public` | 模块内外均可见 | ❌ |

⚠️ **重要**：成员的默认访问修饰符是 `internal`，不是 `private` 或 `public`。

### 继承
⚠️ **重要**：默认不可继承，只有使用open修饰的类才可以继承
⚠️ **重要**：只有被open修饰的类的实例成员函数和实例成员属性才可以被子类覆盖
```cj
public open class SuperClass {
    protected open func fn(): Unit {}
}
public class SubClass <: SupperClass {  // <: 是继承标记符
    public func fn(): Unit {}// 覆盖了SuperClass 的fn()，被覆盖的函数可见性可以跟原来一样，也可以更大
}
```

#### 抽象类
⚠️ **重要**：默认具有open语义
```cj
public abstract class AbstractClass {
    public func fn(): Unit //抽象函数没有函数体
}
public class SubClass <: AbstractClass {
    public func fn(): Unit {
        // 继承了抽象类的子类必须实现抽象类的抽象函数，除非子类也是抽象类
    }
}
```

#### 封闭类
⚠️ **重要**：默认具有open语义，且必须是抽象类
⚠️ **重要**：只能被同包的类继承
```cj
public abstract sealed class SealedClass {}
public class SubClass <: SealedClass {}
```

---

## 结构体（struct）
与类的声明几乎一样
- 只能是顶级声明
- 可以实现多个接口
- 可以声明成员
- 可以声明各种构造函数
- 与类的差别
  - 使用struct声明
  - 值类型，传参、赋值、返回都是全复制
  - 绝对不可继承
  - 只有`mut func`声明的函数才能在函数体内修改成员变量

## 接口（interface）
- 只能是顶级声明
- 接口可以声明实例成员函数和属性，也可以声明静态成员函数和属性，
- 接口的成员默认且只能是public可见性
- 声明的成员可以带默认实现，默认实现的成员默认带open语义
- 枚举、结构体、类都可以实现接口
- 基本类型也可以用扩展的方式实现接口
```cj
public interface InterfaceName {
    func funcName(): ReturnType
    prop propName: ReturnType 
    func defaultImpl(): ReturnType{
        ...
    }
}
```
- 实现接口的类型后面同样使用`<:`分隔
```cj
public class ClassName <: InterfaceName{
    ...
}
```
- 可以实现多个接口，多个接口之间用`&`分隔
```cj
public class ClassName <: Interface1 & Interface2 {
    ...
}
```
- 可以同时继承一个父类再实现至少一个接口，实现的接口必须在父类后面，使用`&`分隔
```cj
public class SubClass <: SuperClass & InterfaceName {}
```

## 泛型
- 任意类型的名称标识符后面使用`<T>`即声明一个泛型形参
- 类、结构体、枚举、接口都可以声明泛型
- ⚠️ **重要**：不支持泛型协变、逆变
```cj
public class ClassName<T> {}
let instance = ClassName<String>()
```
- 多个泛形形参使用`,`分隔
```cj
public class ClassName<A, B>{}
```
### 泛型约束
```cj
// 要求泛型实参必须是GenericSuperType子类型，可以用`&`分隔多个泛型约束
public class ClassName<T> where T <: GenericSuperType {}
```

## 扩展（extend）
- 使用`extend` 可扩展任意已有类型，包括基本类型、标准库类型和自定义类型
- 扩展内可声明静态函数、实例函数、静态属性、实例属性
```cj
//这样的扩展只有当前包可见
extend Int64 {}
```
### 接口扩展
- 可以对包外可见，在需要使用扩展的包同时导入扩展所在的包、被扩展类型和扩展的接口即可
- 扩展要么跟被扩展类型在同一包声明，要么跟扩展接口在同一包声明
- 被扩展类型必须实现扩展接口的全部抽象成员，也可以覆盖扩展接口的默认实现成员
```cj
public interface ExtendInterface {}
extend ExtenedType <: ExtendInterface {}
```

### 泛型扩展
- extend关键词后面紧跟`<>`包含的泛型形参
- 被扩展类型的泛型形参必须全部出现在`extend<>`这对`<>`中
```cj
extend<T> Array<T> {
    ...
}
extend<T> ExtendedType<T> <: ExtendInterface<T> where T <: SuperGenericType {}
```

## 集合
>以下添加元素都用`add`方法添加，修改可以使用`[]`下标方式修改， 移除是`remove`, 列表是`remove(at: 1)`
- Array：不需要增加和删除元素，但需要修改元素
  - 字面量:  `let arr:Array<String> = ["A", "B", "C"]`
- ArrayList：需要频繁对元素增删查改
- HashSet：希望每个元素都是唯一的
- HashMap：希望存储一系列的映射关系
  - 字面量:  `let map:HashMap<String, Int> = HashMap( ("A", 1), ("B", 2), ("C",3) )`

## 异常
所有异常都是`std.core.Exception`的子类
```cj
try{
    throw Exception()//主动抛出一个异常
    //try内抛出的异常会被catch捕获
}catch(e: Exception1){//当前catch块可以捕获的异常类型，指定异常和它的子类型会被捕获
    //可以在catch块内处理这个异常，或者包装后重新抛出
    throw Exception(e)
}catch(e: Exception2 | Exception3){//一个catch块可以捕获多个不同类型的异常

}catch(_){//不论什么类型的异常都会被捕获，被捕获的异常会被忽略无法在catch内使用
    //
}finally{
    //在try块捕获的catch块结束以后，finally块的代码一定会执行不论有没有异常
}
```
⚠️ **注意**：
- catch(_) 和catch(e: Exception) 只能是最后一个catch块，且此二者一个try块只能使用一个
- try块后面可以有零个或多个catch块，finally可以有也可以没有
    - 可以同时有try catch finally
    - 可以只有try catch
    - 可以只有try finally
- try表达式不论有没有finally块的类型
    - 是try块和各个catch块的最小公共父类型
    - 当最小公共父类型是Any时可在赋值表达式右边但是不可用于变量类型推断，也不可用于函数类型推断

## 自动关闭
实现了`std.core.Resource`接口的类型的实例可以使用try-with-resource关闭
```cj
try(a = Resource1()
    b = Resource2()){
    // 在此处使用a b两个变量，a b 不可变
}
```
⚠️ **注意**：try-with-resource的类型是`Unit`

## 包

### 声明
```cj
// The directory structure is as follows:
src
`-- directory_0
    |-- directory_1
    |    |-- a.cj
    |    `-- b.cj
    `-- c.cj
`-- main.cj

// a.cj
package demo.directory_0.directory_1
// b.cj
package demo.directory_0.directory_1
// c.cj
package demo.directory_0
// main.cj
package demo

package demo      // root 包 demo
package demo.directory_0 // root 包 demo 的子包 directory_0
```

### 导入
```cj
package a
import std.math.*
import package1.foo
import {package1.foo, package2.bar, package1.MyClass}


直接使用导入的方法，类型
func test() {
    let a = pow(1,2) // std.math.pow
    foo() // 方法
    let b = MyClass()
}
```

## 组织
在模块或项目的cjpm.toml 的`[package]`节点增加`organization = "orgname"`即定义了一个组织名。当前模块下面的包声明都按照以下方式声明：
```cj
//a.cj
package orgname::demo
//b.cj
package orgname::demo.directory_0
```

## 依赖
在模块或项目的cjpm.tom `[dependencies]`按以下方式添加依赖
```toml
[dependencies]
  "orgname::module_name" = "x.y.z" # = 左面是依赖的标识，右面是依赖的版本号；::左面是依赖的模块所属组织，::右面是依赖的模块
  "org2::mod2" = {path = "/path/of/dependency/on/local/machine"}
  "org3::mod3" = {git = "https://domain.name/path/of.git"}
```


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

---

## 常见错误与注意事项

### 变量相关

1. ⚠️ `let` 不支持变量遮蔽，不能在同一作用域重新定义同名变量
2. 函数参数默认是 `let` 不可变的
3. 成员变量默认访问修饰符是 `internal`

### 控制流相关

4. ⚠️ 所有条件表达式（`if`、`while`、`for-in`）的括号不能省略
5. ⚠️ 不支持 `goto`，`break`/`continue` 不支持标签跳转

### 类型转换相关

6. `Rune` 转整数需要确保在有效 Unicode 范围内
7. 原始字符串字面量中转义字符不会被转义

### 模式匹配相关

8. match 表达式的 case 按顺序匹配，不会自动优化
9. 通配符模式 `_` 应放在最后

### 其他

10. `Unit` 类型只支持赋值、判等、判不等操作
11. Lambda 表达式可以立即调用：`{ => 123 }()`
12. 插值字符串使用 `${}` 而非 `{}`
13. `Duration` 和 `sleep` 在 `std.core` 里不需导入

---

## 快速参考

### 代码块

```cj
main() {
    // 条件判断（必须有括号）
    if (条件) {
        // ...
    } else {
        // ...
    }

    // 循环
    while (条件) { }
    do { } while (条件)
    for (变量 in 序列) { }

    // 模式匹配
    match (值) {
        case 模式 => 处理
        case _ => 默认
    }
}
```

### 类型后缀速查

| 类型 | 后缀 |
|------|------|
| 整数 | `Int8`, `Int16`, `Int32`, `Int64`, `IntNative` |
| 无符号整数 | `UInt8`, `UInt16`, `UInt32`, `UInt64`, `UIntNative` |
| 浮点 | `Float16`, `Float32`, `Float64` |
| 字符 | `Rune` |
| 字符串 | `String` |
| 元组 | `(T1, T2, ...)` |
| 数组 | `Array<T>` |
| 区间 | `Range<T>` |
| 函数 | `(T1, T2) -> Rt` |

---

## 标准库
### `std.core`
core 包是标准库的核心包，提供了适用仓颉语言编程最基本的一些 API 能力。

提供了内置类型（有符号整型、无符号整型、浮点型等）、常用函数（print、println、eprint 等）、常用接口（ToString、Hashable、`Equatable<T>`、`Collection<T>`、`Comparable<T>` 等）、常用类和结构体（`Array<T>`、String、`Range<T>` 等）、时间长度（Duration）、线程类型（Thread、`Future<T>`）、可关闭的资源（Resource）、常用异常类（Error、Exception 以及它们的一些细分子类）。

### `std.ast`
宏编程API

### `std.binary`
当前 binary 包提供了如下功能：

仓颉数据类型和二进制字节序列间的互相转换接口，分为大端序和小端序两种转换类型。
仓颉数据类型自身大小端序转换的接口。

### `std.collection`
常用集合类型: 
- `ArrayList<T>`
- `HashMap<K, V> where K <: Hashable & Equatable<K>`
- `TreeMap<K, V> where K <: Comparable<K>`
- `HashSet<T> where T <: Hashable & Equatable<T>`
- `TreeSet<T> where T <: Comparable<T>`
- `LinkedList<T>` - 双向链表

### `std.collection.concurrent`
并发安全的集合类型
- `ArrayBlockingQueue<T>` - 必须指定初始容量的阻塞队列，实例化后不可扩容
- `ConcurrentLinkedQueue<T>` - 并发安全的非阻塞队列，可以指定初始化的固定容量也可以不限制容量
- `LinkedBlockingQueue<T>` - 并发安全的阻塞队列，可以指定初始化的固定容量也可以不限制容量
- `ConcurrentHashMap<K, V> where K <: Hashable & Equatable<K>` - 并发安全的哈希映射

### `std.convert`
从字符串转到特定类型的 Convert 系列函数

### `std.crypto.cipher`
提供对称加解密通用接口

### `std.crypto.digest`
提供常用摘要算法的通用接口，包括 MD5、SHA1、SHA224、SHA256、SHA384、SHA512、HMAC、SM3 等

### `std.database.sql`
提供仓颉访问数据库的接口。

本包提供 SQL/CLI 的通用接口，配合数据库驱动 Driver 完成对数据库的各项操作

### `std.env`
提供当前进程的相关信息与功能、包括环境变量、命令行参数、并发安全的标准流、退出程序。也提供标准输入、标准输出、标准错误进行交互的方法

### `std.fs`
提供对文件、文件夹、路径、文件元数据信息的一些操作函数。

目前支持 Linux，macOS，Windows 平台下使用

### `std.io`
包提供程序与外部设备进行数据交换的能力。

I/O 操作是指程序与外部设备进行数据交换的操作。仓颉提供了流式 I/O 操作的通用接口和一些特殊实现。输入输出流类似一个数据通道，承载一段有序数据，程序从输入流读取数据（来自文件、网络等），往输出流（通往文件、网络等）写入数据

### `std.math`
提供常见的数学运算，常数定义，浮点数处理等功能。

包括了以下能力：
1. 科学常数与类型常数定义；
2. 浮点数的判断，规整；
3. 常用的位运算；
4. 通用的数学函数，如绝对值，三角函数，指数，对数计算；
5. 最大公约数与最小公倍数。

### `std.math.numeric`
对基础类型可表达范围之外提供扩展能力。

例如：
1. 支持大整数(BigInt)；
2. 支持高精度十进制数(Decimal)类型；
3. 提供常见的数学运算能力包括高精度运算规则。

### `std.net`
用于进行网络通信，提供启动 Socket 服务器、连接 Socket 服务器、发送数据、接收数据等功能和 IP 地址、IP前缀（又称IP子网）、Socket 地址的相关数据结构。
支持 UDP/TCP/UDS 三种 Socket 类型，用户可按需选用

### `std.process`
提供 Process 进程操作接口，主要包括进程创建，标准流获取，进程等待，进程信息查询等。

本包提供多平台统一操控能力，目前支持 Linux 平台，macOS 平台，Windows 平台。

### `std.random`
生成伪随机数的能力

### `std.ref`
提供了弱引用相关的能力

### `std.reflect`
反射

### `std.regex`
正则表达式

### `std.runtime`
运行时API

### `std.sort`
排序函数

### `std.sync`
提供并发编程相关的能力

### `std.time`
 包提供了与时间相关的类型，包括日期时间，单调时间和时区等，并提供了计算和比较的功能。

## 仓颉项目/模块目录结构
```
module_dir
`--src
    `-- directory_0
        |-- directory_1
        |    |-- a.cj
        |    `-- b.cj
        `-- c.cj
    `-- module.cj

```
## 构建命令
- **cjpm init --type=dynamic** - 将当前文件夹初始化为一个动态链接库模块，当前文件夹必须是空的
- **cjpm clean** - 当前文件夹是一个仓颉模块，清空这个模块的编译结果
- **cjpm build** - 当前文件夹是一个仓颉模块，构建当前模块
- **cjpm test**
    - **cjpm test -i src/pkg** - 当前文件夹是一个仓颉模块，执行指定文件夹下的单元测试用例
    - **cjpm test -i --filter=<value>** - 执行符合过滤规则的单元测试用例
        - --filter <value> 用于过滤测试的子集，value 的形式如下所示：
        - --filter=* 匹配所有测试类
        - --filter=*.* 匹配所有测试类的所有测试用例（结果和*相同）
        - --filter=*.*Test,*.*case* 匹配所有测试类中以 Test 结尾的用例，或者所有测试类中名字中带有 case 的测试用例
        - --filter=MyTest*.*Test,*.*case*,-*.*myTest 匹配所有 MyTest 开头测试类中以 Test 结尾的用例，或者名字中带有 case 的用例，或者名字中不带有 myTest 的测试用例