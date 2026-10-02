# f_random

`f_random` 扩展了仓颉标准库的 `std.random.Random` 和 stdx 的 `stdx.crypto.crypto.SecureRandom`，为它们补上区间随机数、
随机数流迭代器等能力，另外提供线程本地随机源 `ThreadLocalRandom`、蓄水池抽样 `randomReservoir`
和随机字符串生成器 `RandomString`。

- 包名：`fountain::f_random`
- 依赖：`fountain::f_base`（用到其中的 `StringGenerator`、`ThreadLocal`）
- 也可以导入根包的 `fountain::fountain.random`，它以 `public import fountain::f_random.*` 的方式导出本模块同名 API

## 目录

- [STDX依赖](#stdx依赖)
- [引入依赖](#引入依赖)
- [快速开始](#快速开始)
- [随机数扩展](#随机数扩展)
- [随机数迭代器](#随机数迭代器)
- [蓄水池算法](#蓄水池算法)
- [随机字符串](#随机字符串)
- [ThreadLocalRandom](#threadlocalrandom)
- [注意事项与已知行为](#注意事项与已知行为)


## STDX依赖

配置环境变量：`export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`

Windows PowerShell：`$env:CANGJIE_STDX_DYNAMIC_PATH = "path\to\dynamic_stdx"`

该变量被 `cjpm.toml` 中每个 target 的 `bin-dependencies.path-option` 引用，未设置会在链接阶段找不到 stdx 动态库。


## 引入依赖

```toml
[dependencies]
  "fountain::f_random" = {path = "../f_random"}
```

本模块把 `Random` 和 `SecureRandom` 一并 `public import` 了出来，因此一次导入即可同时拿到标准库类型和本模块的扩展：

```cj
import fountain::f_random.*
// 或：import fountain::fountain.random.*
```

注意：扩展方法（例如 `nextInt64(min, max, closed:)`）只有在导入本模块后才可见。


## 快速开始

```cj
import fountain::f_random.*

main() {
    let rand = Random()

    // 区间随机整数，closed 为 true 时包含上界：[1, 100]
    let dice = rand.nextInt64(1, 100, closed: true)
    // [0.0, 1.0) 区间的浮点数
    let ratio = rand.nextFloat64(0.0, 1.0)

    // 随机数流：无限迭代器，每次 next() 产出一个新的随机数
    let stream = rand.randomInt64(0, 10)
    let next = stream.next() ?? 0

    // 随机字符串，默认使用 ThreadLocalRandom，各线程之间互不干扰
    let rs = RandomString()
    println(rs.randomLettersNumbers(16))
    println(rs.randomLowerHex(8))

    // 蓄水池抽样：遍历一次数据源即可随机取出指定个数的元素
    let sample = randomReservoir<Int64>(3, [1, 2, 3, 4, 5, 6, 7, 8])
}
```

`SecureRandom` 的用法完全相同，需要密码学强度时把 `Random()` 换成 `SecureRandom()` 或 `ThreadLocalRandom.current` 即可。


## 随机数扩展

本模块用 `extend Random <: ExtendRandom<Random>` 和 `extend SecureRandom <: ExtendRandom<SecureRandom>` 把下面两个接口
实现到 `Random`、`SecureRandom` 两个类上，不需要自己做包装，直接调用即可。

```cj
//std.random.Random和stdx.crypto.crypto.SecureRandom都实现此接口的扩展
public interface ExtendRandom<R> where R <: ExtendRandom<R> {
    func nextFloat64(): Float64
    func nextFloat32(): Float32
    /**
     * 返回范围从min到max的随机数，closed表示是否包含max
     */
    func nextFloat64(min: Float64, max: Float64, closed!: Bool): Float64
    /**
     * 返回范围从min到max的随机数，closed表示是否包含max
     */
    func nextFloat32(min: Float32, max: Float32, closed!: Bool): Float32
    /**
     * 返回范围从min到max的随机数，closed表示是否包含max
     */
    func nextInt64(min: Int64, max: Int64, closed!: Bool): Int64
    /**
     * 返回范围从min到max的随机数，closed表示是否包含max
     */
    func nextUInt64(min: UInt64, max: UInt64, closed!: Bool): UInt64
    /**
     * 返回范围从min到max的随机数，closed表示是否包含max
     */
    func nextInt32(min: Int32, max: Int32, closed!: Bool): Int32
    /**
     * 返回范围从min到max的随机数，closed表示是否包含max
     */
    func nextUInt32(min: UInt32, max: UInt32, closed!: Bool): UInt32
}
```

`ExtendRandom` 的各个方法在**实现**中都给 `closed` 加了默认值 `false`，因此 `rand.nextInt64(1, 100)` 这样的调用是合法的。
`closed` 的实际语义见 [注意事项与已知行为](#注意事项与已知行为)。

```cj

//std.random.Random和stdx.crypto.crypto.SecureRandom都实现此接口的扩展
public interface BaseRandom<R> where R <: BaseRandom<R> {
    /**
     * 获取一个布尔类型的随机数，获取失败会抛异常
     * 返回值 Bool - 一个布尔类型的随机数
     */
    func nextBool(): Bool

    /**
     * 获取一个 UInt8 类型的随机数，获取失败会抛异常
     * 返回值 UInt8 - 一个 UInt8 类型的随机数
     */
    func nextUInt8(): UInt8

    /**
     * 获取一个 UInt16 类型的随机数，获取失败会抛异常
     * 返回值 UInt16 - 一个 UInt16 类型的随机数
     */
    func nextUInt16(): UInt16

    /**
     * 获取一个 UInt32 类型的随机数，获取失败会抛异常
     * 返回值 UInt32 - 一个 UInt32 类型的随机数
     */
    func nextUInt32(): UInt32

    /**
     * 获取一个 UInt64 类型的随机数，获取失败会抛异常
     * 返回值 UInt64 - 一个 UInt64 类型的随机数
     */
    func nextUInt64(): UInt64

    /**
     * 获取一个 Int8 类型的随机数，获取失败会抛异常
     * 返回值 Int8 - 一个 Int8 类型的随机数
     */
    func nextInt8(): Int8

    /**
     * 获取一个 Int16 类型的随机数，获取失败会抛异常
     * 返回值 Int16 - 一个 Int16 类型的随机数
     */
    func nextInt16(): Int16

    /**
     * 获取一个 Int32 类型的随机数，获取失败会抛异常
     * 返回值 Int32 - 一个 Int32 类型的随机数
     */
    func nextInt32(): Int32

    /**
     * 获取一个 Int64 类型的随机数，获取失败会抛异常
     * 返回值 Int64 - 一个 Int64 类型的随机数
     */
    func nextInt64(): Int64

    /**
     * 获取一个 UInt8 类型且在区间 [0, max) 内的随机数，获取失败会抛异常
     * 参数 max - 区间最大值， max <= 0 会抛出参数非法异常
     * 返回值 UInt8 - 一个 UInt8 类型的随机数
     */
    func nextUInt8(max: UInt8): UInt8

    /**
     * 获取一个 UInt16 类型且在区间 [0, max) 内的随机数，获取失败会抛异常
     * 参数 max - 区间最大值， max <= 0 会抛出参数非法异常
     * 返回值 UInt16 - 一个 UInt16 类型的随机数
     */
    func nextUInt16(max: UInt16): UInt16

    /**
     * 获取一个 UInt32 类型且在区间 [0, max) 内的随机数，获取失败会抛异常
     * 参数 max - 区间最大值， max <= 0 会抛出参数非法异常
     * 返回值 UInt32 - 一个 UInt32 类型的随机数
     */
    func nextUInt32(max: UInt32): UInt32

    /**
     * 获取一个 UInt64 类型且在区间 [0, max) 内的随机数，获取失败会抛异常
     * 参数 max - 区间最大值， max <= 0 会抛出参数非法异常
     * 返回值 UInt64 - 一个 UInt64 类型的随机数
     */
    func nextUInt64(max: UInt64): UInt64

    /**
     * 获取一个 Int8 类型且在区间 [0, max) 内的随机数，获取失败会抛异常
     * 参数 max - 区间最大值， max <= 0 会抛出参数非法异常
     * 返回值 Int8 - 一个 Int8 类型的随机数
     */
    func nextInt8(max: Int8): Int8

    /**
     * 获取一个 Int16 类型且在区间 [0, max) 内的随机数，获取失败会抛异常
     * 参数 max - 区间最大值， max <= 0 会抛出参数非法异常
     * 返回值 Int16 - 一个 Int16 类型的随机数
     */
    func nextInt16(max: Int16): Int16

    /**
     * 获取一个 Int32 类型且在区间 [0, max) 内的随机数，获取失败会抛异常
     * 参数 max - 区间最大值， max <= 0 会抛出参数非法异常
     * 返回值 Int32 - 一个 Int32 类型的随机数
     */
    func nextInt32(max: Int32): Int32

    /**
     * 获取一个 Int64 类型且在区间 [0, max) 内的随机数，获取失败会抛异常
     * 参数 max - 区间最大值， max <= 0 会抛出参数非法异常
     * 返回值 Int64 - 一个 Int64 类型的随机数
     */
    func nextInt64(max: Int64): Int64

    /**
     * 获取一个 Float16 类型的随机数，范围在 0.0 到 1.0 之间，获取失败会抛异常
     * 返回值 Float16 - 一个 Float16 类型的随机数
     */
    func nextFloat16(): Float16

    /**
     * 获取一个 Float32 类型的随机数，范围在 0.0 到 1.0 之间，获取失败会抛异常
     * 返回值 Float32 - 一个 Float32 类型的随机数
     */
    func nextFloat32(): Float32

    /**
     * 获取一个 Float64 类型的随机数，范围在 0.0 到 1.0 之间，获取失败会抛异常
     * 返回值 Float64 - 一个 Float64 类型的随机数
     */
    func nextFloat64(): Float64

    /**
     * 获取一个 Float16 类型且符合均值为 0.0 标准差为 1.0 的高斯分布的随机数，获取失败会抛异常
     * 返回值 Float16 - 一个 Float16 类型的随机数
     */
    func nextGaussianFloat16(mean!: Float16, sigma!: Float16): Float16

    /**
     * 获取一个 Float32 类型且符合均值为 0.0 标准差为 1.0 的高斯分布的随机数，获取失败会抛异
             常
     * 返回值 Float32 - 一个 Float32 类型的随机数
     */
    func nextGaussianFloat32(mean!: Float32, sigma!: Float32): Float32

    /**
     * 获取一个 Float64 类型且符合均值为 0.0 标准差为 1.0 的高斯分布的随机数，获取失败会抛异
             常
     * 返回值 Float64 - 一个 Float64 类型的随机数
     */
    func nextGaussianFloat64(mean!: Float64, sigma!: Float64): Float64

    func randomInt64(min: Int64, max: Int64, closed!: Bool): Iterator<Int64>
    func randomUInt64(min: UInt64, max: UInt64, closed!: Bool): Iterator<UInt64>
    func randomInt32(min: Int32, max: Int32, closed!: Bool): Iterator<Int32>
    func randomUInt32(min: UInt32, max: UInt32, closed!: Bool): Iterator<UInt32>
    func nextBytes(length: Int64): Array<Byte> {
        Array<UInt8>(length) {_ => nextUInt8()}
    }
    /**
     * 生成随机数替换入参数组中的每个元素
     * 参数类型 array - 传入一个数组
     * 返回值 Array<UInt8> - 返回替换后的 Array
     */
    func nextUInt8s(array: Array<UInt8>): Array<UInt8> {
        for (i in 0..array.size) {
            array[i] = nextUInt8()
        }
        array
    }

    /**
     * 获取高斯 Float16 的随机数
     * 返回值 Float16 - 返回一个 Float16 类型的高斯随机数
     */
    func randomGaussianFloat16Stream(mean!: Float16, sigma!: Float16): Iterator<Float16>

    /**
     * 获取高斯 Float32 的随机数
     * 返回值 Float32 - 返回一个 Float32 类型的高斯随机数
     */
    func randomGaussianFloat32Stream(mean!: Float32, sigma!: Float32): Iterator<Float32>

    /**
     * 获取高斯 Float64 的随机数
     * 返回值 Float64 - 返回一个 Float64 类型的高斯随机数
     */
    func randomGaussianFloat64Stream(mean!: Float64, sigma!: Float64): Iterator<Float64>
}
```

`BaseRandom` 里声明的这些能力大多来自 `Random`/`SecureRandom` 自带的方法，本模块通过 `extend` 把它们统一到接口上，
对外只额外提供下面一节列出的成员。


## 随机数迭代器

`RandomIterator.cj` 给 `Random` 和 `SecureRandom` 额外扩展了下面这些成员，用来把「一次一个随机数」变成「一条随机数流」：

```cj
// Random 的扩展为 prop current: Random，SecureRandom 的扩展为 prop current: SecureRandom，取值都返回自身
public prop current: Random
public prop current: SecureRandom

// 无限迭代器，每次 next() 产生一个 [min, max) 或 [min, max] 内的随机数
public func randomInt64(min: Int64, max: Int64, closed!: Bool = false): Iterator<Int64>
public func randomUInt64(min: UInt64, max: UInt64, closed!: Bool = false): Iterator<UInt64>
public func randomInt32(min: Int32, max: Int32, closed!: Bool = false): Iterator<Int32>
public func randomUInt32(min: UInt32, max: UInt32, closed!: Bool = false): Iterator<UInt32>

// 高斯分布随机数流，mean 默认 0.0，sigma 默认 1.0
public func randomGaussianFloat16Stream(mean!: Float16 = 0.0, sigma!: Float16 = 1.0): Iterator<Float16>
public func randomGaussianFloat32Stream(mean!: Float32 = 0.0, sigma!: Float32 = 1.0): Iterator<Float32>
public func randomGaussianFloat64Stream(mean!: Float64 = 0.0, sigma!: Float64 = 1.0): Iterator<Float64>
```

说明：

- 这些迭代器的 `next()` 永远返回 `Some`，即它们是**无限迭代器**，需要自己控制取多少个数。
- 具体的迭代器类（`RangeRandomInt64Iterator`、`RandomGaussianFloat64Iterator` 等）只在包内可见，外部不能直接实例化，
  通过上面的工厂方法获取即可。


## 蓄水池算法

```cj
public func randomReservoir<T>(count: Int64, source: Iterable<T>, priv!: Bool = false): ArrayList<T>
```

从 `source` 中随机取 `count` 个元素，只需遍历一次数据源，不需要事先知道元素总数，适合流式或超大数据源抽样。

- `priv` 是内部 `SecureRandom` 的初始化参数；每次调用都会新建一个 `SecureRandom`。
- 返回值大小是 `min(count, 数据源元素个数)`，`source` 元素不足时会小于 `count`。
- `count <= 0` 且数据源非空时会抛参数非法异常，详见 [注意事项与已知行为](#注意事项与已知行为)。

```cj
let sample = randomReservoir<Int64>(2, [1, 2, 3, 4, 6])
```


## 随机字符串

```cj
/*
   Rune 到 UInt32 的转换使用 UInt32(e) 的方式，其中 e 是一个 Rune 类型的表达式， UInt32(e)
   的结果是 e 的 Unicode scalar value 对应的 UInt32 类型的整数值。
   整数类型到 Rune 的转换使用 Rune(num) 的方式，其中 num 的类型可以是任意的整数类型，且仅当
   num 的值落在 [0x0000, 0xD7FF] 或 [0xE000, 0x10FFFF] （即 Unicode scalar value）中时，返
   回对应的 Unicode scalar value 表示的字符，否则，编译报错（编译时可确定 num 的值）或运行时抛
   异常。
 */
public class RandomString{
    public RandomString(private let rand!: SecureRandom = ThreadLocalRandom.current)
    public init(priv: Bool)
    /**返回count个ASCII字符的字符串*/
    public func randomAscii(count: Int64): String
    /**
     * 随机字符串长度是从min到max的随机值，从所有ASCII字符当中随机取出字符
     */
    public func randomAscii(min: Int64, max: Int64): String 
    /**
     * 从source当中随机取出count个字符
     */
    public func random(count: Int64, source: String): String 
    /**
     * 从source当中随机取出count个字符
     */
    public func random(count: Int64, source: Array<Rune>): String 
    /**
     * 随机字符串长度是从min到max的随机值，从source当中随机取出字符
     */
    public func random(min: Int64, max: Int64, source: String): String 
    /**
     * 从小写英文字母当中随机取出count个字符
     */
    public func randomLowerLetters(count: Int64): String 
    /**
     * 随机字符串长度是从min到max的随机值，从小写英文语字母当中随机取出字符
     */
    public func randomLowerLetters(min: Int64, max: Int64): String 
    /**
     * 从大写英文字母当中随机取出count个字符
     */
    public func randomUpperLetters(count: Int64): String 
    /**
     * 随机字符串长度是从min到max的随机值，从大写英文语字母当中随机取出字符
     */
    public func randomUpperLetters(min: Int64, max: Int64): String 
    /**
     * 从英文字母当中随机取出count个字符
     */
    public func randomAllLetters(count: Int64): String 
    /**
     * 随机字符串长度是从min到max的随机值，从英文语字母当中随机取出字符
     */
    public func randomAllLetters(min: Int64, max: Int64): String 
    /**
     * 从数字当中随机取出count个字符
     */
    public func randomNumbers(count: Int64): String 
    /**
     * 随机字符串长度是从min到max的随机值，从数字当中随机取出字符
     */
    public func randomNumbers(min: Int64, max: Int64): String 
    /**
     * 从小写十六进制字符（0-9a-f）当中随机取出count个字符
     */
    public func randomLowerHex(count: Int64): String
    /**
     * 随机字符串长度是从min到max的随机值，从小写十六进制字符当中随机取出字符
     */
    public func randomLowerHex(min: Int64, max: Int64): String
    /**
     * 从大写十六进制字符（0-9A-F）当中随机取出count个字符
     */
    public func randomUpperHex(count: Int64): String
    /**
     * 随机字符串长度是从min到max的随机值，从大写十六进制字符当中随机取出字符
     */
    public func randomUpperHex(min: Int64, max: Int64): String
    /**
     * 从小写英文字母和数字当中随机取出count个字符
     */
    public func randomLowerLettersNumbers(count: Int64): String 
    /**
     * 随机字符串长度是从min到max的随机值，从小写英文字母和数字当中随机取出字符
     */
    public func randomLowerLettersNumbers(min: Int64, max: Int64): String 
    /**
     * 从大写英文字母和数字当中随机取出count个字符
     */
    public func randomUpperLettersNumbers(count: Int64): String 
    /**
     * 随机字符串长度是从min到max的随机值，从大写英文字母和数字当中随机取出字符
     */
    public func randomUpperLettersNumbers(min: Int64, max: Int64): String 
    /**
     * 从英文字母和数字当中随机取出count个字符
     */
    public func randomLettersNumbers(count: Int64): String 
    /**
     * 随机字符串长度是从min到max的随机值，从英文字母和数字当中随机取出字符
     */
    public func randomLettersNumbers(min: Int64, max: Int64): String 
    /**
     * 从所有键盘可打印字符中随机取出count个字符构造字符串
     */
    public func randomPrintableAsciis(count: Int64): String
    /**
     * 随机字符串长度是从min到max的随机值，从所有键盘可打印字符中随机取出字符
     */
    public func randomPrintableAsciis(min: Int64, max: Int64): String 
    /**
     * 从所有UNICODE字符中随机取出count个字符构造一个字符串
     */
    public func randomAllChars(count: Int64): String 
    /**随机字符串长度是从min到max的随机值，从所有的UNICODE字符中随机取出字符*/
    public func randomAllChars(min: Int64, max: Int64): String 
}
```

### 字符集

| 方法 | 取值来源 |
| --- | --- |
| `randomAscii` | `U+0000`–`U+007F`（0–127，含不可打印的控制字符） |
| `randomLowerLetters` | `a`–`z` |
| `randomUpperLetters` | `A`–`Z` |
| `randomAllLetters` | `A`–`Z` + `a`–`z` |
| `randomNumbers` | `0`–`9` |
| `randomLowerHex` | `0`–`9` + `a`–`f` |
| `randomUpperHex` | `0`–`9` + `A`–`F` |
| `randomLowerLettersNumbers` | `a`–`z` + `0`–`9` |
| `randomUpperLettersNumbers` | `A`–`Z` + `0`–`9` |
| `randomLettersNumbers` | `A`–`Z` + `a`–`z` + `0`–`9` |
| `randomPrintableAsciis` | 字母数字 + `` `~!@#$%^&*()-_=+[{]}\\|'";:/?.>,< `` |
| `randomAllChars` | 全部 Unicode scalar：`[0x0000, 0xD7FF]` ∪ `[0xE000, 0x10FFFF]` |
| `random(count, source)` | 调用方给定的字符串或 `Array<Rune>` |

说明：

- 不带 min/max 的重载生成 `count` 个字符；带 min/max 的重载先随机出长度再生成字符。
  长度区间存在不一致：`randomAscii(min, max)` 与 `random(min, max, source)` 用的是 `closed: true`，
  长度落在 `[min, max]`；其余重载长度落在 `[min, max)`。
- `randomAscii` 会把 `nextUInt32(128)` 的结果转成 Rune，包含控制字符；只要可打印字符请用 `randomPrintableAsciis`。
- `randomAllChars` 会避开 UTF-16 代理区间 `0xD800`–`0xDFFF`，因为该区间不是合法的 Unicode scalar value。
- 三个 min/max 重载内部调用的方法名与注释不符，产出结果与预期字符集不同，
  详见 [注意事项与已知行为](#注意事项与已知行为)。


## ThreadLocalRandom

```cj
/**
 * 为每个线程返回一个单独的SecureRandom实例，返回的SecureRandom使用默认的priv创建
 */
public class ThreadLocalRandom {
    private init()
    @Frozen
    public static prop current: SecureRandom 
}
```

- 每个线程首次访问 `current` 时创建一个 `SecureRandom`（默认 `priv`），之后一直复用该实例，
  因此不需要自己处理跨线程加锁或复用问题。
- 构造器是私有的，这个类只用于取 `current`。
- `RandomString()` 的无参构造器默认就把 `ThreadLocalRandom.current` 作为随机源，所以默认的 `RandomString` 实例是线程安全的。


## 注意事项与已知行为

以下条目是当前实现与直觉/注释不一致的地方，文档按代码的实际行为记录，**代码本身未做改动**。

1. **浮点版本的 `closed` 不是「包含上界」**：实现是 `nextFloat64() * (max - min + (closed ? 1 : 0)) + min`。
   `closed: true` 时返回值落在 `[min, max + 1.0)`，即有可能超过 `max`；`closed: false` 时落在 `[min, max)`。
   需要严格不超过上界的浮点数请自己裁剪。
2. **整数版本先转浮点再取整**：`nextInt64`/`nextUInt64` 走 `Float64`，`nextInt32`/`nextUInt32` 走 `Float32`，
   最后用 `floor` 取整，`closed: false` 得到 `[min, max)`、`closed: true` 得到 `[min, max]`。
   区间超出浮点精确表示范围时（例如接近 `Int64.Max`）会有精度损失，甚至溢出。
3. **区间参数没有校验**：`ExtendRandom` 的各方法不检查 `min <= max`，传反了不会报错，只会得到反转区间的结果。
4. **`RandomString` 的三个 min/max 重载调用错了方法**：
   - `randomAllLetters(min, max)` 内部调用的是 `randomLowerLetters`，只会产出小写字母；
   - `randomUpperLettersNumbers(min, max)` 内部调用的是 `randomLowerLettersNumbers`，产出小写字母+数字；
   - `randomLettersNumbers(min, max)` 内部调用的也是 `randomLowerLettersNumbers`，产出小写字母+数字。

   需要对应字符集时请自己算出长度再调用 `(count)` 重载，例如取 8–16 位「大小写字母+数字」的串：

   ```cj
   let rs = RandomString()
   let len = ThreadLocalRandom.current.nextInt64(8, 16, closed: true)
   let s = rs.randomLettersNumbers(len)
   ```

5. **`RandomString` 的长度区间不统一**：只有 `randomAscii(min, max)` 和 `random(min, max, source)` 用了 `closed: true`，
   其余 `(min, max)` 重载的长度是 `[min, max)`。
6. **`randomReservoir` 的边界**：
   - `count <= 0` 且数据源非空时，`nextInt64(0)` 会抛参数非法异常；
   - 返回值大小是 `min(count, 数据源元素个数)`，不是始终等于 `count`；
   - 替换下标取自 `[0, i)`（`i` 为当前元素下标），而经典算法 R 要求取 `[0, i]`，
     少了 `j == i` 这一路分支，抽样结果并非严格均匀。
