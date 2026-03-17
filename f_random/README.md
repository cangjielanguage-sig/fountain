## STDX依赖
配置环境变量：`export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`

## 随机数扩展
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
             414
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
     * 获取一个 Float16 类型且符合均值为 0.0 标准差为 1.0 的高斯分布的随机数，获取失败会抛异
             常
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

## 蓄水池算法
- `public func randomReservoir<T>(count: Int64, source: Iterable<T>, priv!: Bool = false): ArrayList<T>`
  从source中随机取count个元素，返回的ArrayList大小是count，priv是SecureRandom初始化参数

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
    public func randomAscii(count: Int64)
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
    public func randomPrintableAsciis(min: Int64, max: Int64): String {
        randomPrintableAsciis(rand.nextInt64(min, max))
    }
    /**
     * 从所有UNICODE字符中随机取出count个字符构造一个字符串
     */
    public func randomAllChars(count: Int64): String 
    /**随机字符串长度是从min到max的随机值，从所有的UNICODE字符中随机取出字符*/
    public func randomAllChars(min: Int64, max: Int64): String 
}
```

## ThreadLocalRandom
```cj
/**
 * 为每个线程返回一个单独的SecureRandom实例，返回的SecureRandom使用默认的priv创建
 */
public class ThreadLocalRandom {
    public static prop current: SecureRandom 
}
```