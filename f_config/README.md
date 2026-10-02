# f_config

应用配置模块：**不依赖任何配置文件**，配置项来自环境变量、命令行参数、进程内注册（`Config.set`）以及编译期内嵌的敏感配置（`@EmbedSensitive`）。

除配置读写外，本模块还提供 `DateTimeConfConverter`：把某个配置项的值当作时间格式来使用。

## 目录

1. [STDX 依赖](#1-stdx-依赖)
2. [配置来源与优先级](#2-配置来源与优先级)
3. [Config API](#3-config-api)
4. [配置刷新 refresher](#4-配置刷新-refresher)
5. [敏感配置与 SM4 加密](#5-敏感配置与-sm4-加密)
6. [@EmbedSensitive 宏](#6-embedsensitive-宏)
7. [可配置时间转换器](#7-可配置时间转换器)
8. [已知问题](#8-已知问题)

模块依赖：`fountain::f_data`（`DataParsable`）。

---

## 1. STDX 依赖

本模块依赖 `stdx.crypto.crypto`（SM4）与 `stdx.encoding.hex`（密钥/IV 的 16 进制串解析），`cjpm.toml` 中已通过 `${CANGJIE_STDX_DYNAMIC_PATH}` 引入；使用前先配置环境变量：

```bash
export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx
```

---

## 2. 配置来源与优先级

### 2.1 命令行参数

命令行参数会覆盖同名环境变量，合法的写法只有四种：

```
--argName=argValue
--argName            # 等价于 --argName=true
-argName argVal
-argName             # 等价于 -argName true
```

* `--argName=argValue`：key 取 `=` 左侧，value 取 `=` 右侧，两侧都会做 `trimAscii`；
* `-argName argVal`：下一个参数如果以 `-` 开头，则不作为值处理，此时该配置项的值为 `true`；
* 单横线形式不支持 `=` 赋值，`-argName=argValue` 会被整体当成配置项名；
* 不以 `-` 开头的参数会被忽略。
* `env.getCommandLine()[0]`（程序自身路径）不参与解析。

### 2.2 命名风格

本工具不会改写环境变量和命令行参数的命名：仓颉运行时自身的环境变量是驼峰命名，业务配置建议同样采用驼峰命名。

### 2.3 读取优先级

一次 `getString(key)` 的查找顺序如下，先命中者生效：

| 顺序 | 来源 | 说明 |
| --- | --- | --- |
| 1 | 环境变量 / 命令行参数（`ARGS[key]`） | 进程启动时由 `static init` 装载，命令行同名覆盖环境变量 |
| 2 | 带全局前缀的同名项（`ARGS[fountain_key]`） | 见 2.4 |
| 3 | 编译期内嵌的敏感值（`sensitiveMap[key]`） | 见第 5、6 节；配置了 SM4 则此处是密文，读取时解密 |
| 4 | 带全局前缀的敏感值（`sensitiveMap[fountain_key]`） | 见 2.4 |

因此**运行期配置（环境变量/命令行参数）的优先级高于编译期内嵌值**。

### 2.4 全局前缀 `fountain`

`Config` 内置全局前缀 `fountain`。任何通过 `getString(key)` 读取的配置项，在原名未命中时都会再尝试 `fountain_${key}`；`getAll` 的结果里则会把 `fountain_` 去掉。

```bash
export myAppSecret='xxx'          # Config.getString('myAppSecret') 命中
export fountain_myAppSecret='xxx' # 等价写法
```

`getAll(prefix)` 的匹配规则：`prefix` 为空时返回全部配置项，否则 key 需以 `${prefix}_` 或 `fountain_${prefix}_` 开头。

### 2.5 进程内写入

`Config.set` 可以在运行时写入/覆盖配置项（值一律用 `toString()` 转换），并按「配置项名第一段」去触发匹配的刷新回调（见第 4 节）。

---

## 3. Config API

```cj
package fountain::f_config

public import std.convert.Parsable
public import fountain::f_data.DataParsable

/**
 * 不依赖配置文件，所有配置都来自环境变量和命令行参数，命令行参数会覆盖同名环境变量。
 * 本工具不会修改环境变量和命令行参数命名风格，仓颉运行时环境变量都是驼峰命名法，建议用于应用配置的环境变量和命令行参数也采用此风格。
 * 命令行参数需要遵守以下规则
 *   1. --argName=argValue
 *   2. --argName
 *      * 相当于--argName=true
 *   3. -argName argVal
 *   4. -argName
 *      * 相当于-argName true
 * 敏感配置信息使用sm4加密，如果不指定sm4加密参数，会把敏感配置的UTF8字节数组嵌入编译产物。
 * 指定了sm4加密参数，会把敏感配置的密文嵌入编译产物。
 * - sm4Operation SM4 的OperationMode
 * - sm4Padding SM4 的PaddingMode
 * - sm4Key 密钥
 * - sm4Iv IV
 * - sm4Aad 密文填充的AAD
 * - sm4TagSize 密文填充的TagSize
 */
public class Config {
    public static const sm4Operation = 'sm4Operation'
    public static const sm4Padding = 'sm4Padding'
    public static const sm4Key = 'sm4Key'
    public static const sm4Iv = 'sm4Iv'
    public static const sm4Aad = 'sm4Aad'
    public static const sm4TagSize = 'sm4TagSize'

    /**
     * 登记prefix前缀的配置项变化时的刷新回调
     */
    public static func refresher(prefix: String, fn: () -> Unit): Unit
    /**
     * ifAbsent是true，只有当前配置项不存在时才添加，否则用新的配置覆盖旧的
     */
    public static func set<T>(tuples: Array<(String, T)>, ifAbsent!: Bool = false): Unit where T <: ToString
    /**
     * 得到相同前缀的配置项
     */
    public static func getAll(prefix: String): Map<String, String>
    /**
     * 得到所有配置项
     */
    public static func getAll(): Map<String, String>
    /**
     * 得到名是key的配置项
     */
    public static func getString(key: String): ?String
    /**
     * 得到名是key的配置项，调用parser把配置值转为指定类型
     */
    public static func getValue<T>(key: String, parser: (String) -> ?T): ?T
    /**
     * 得到名是key的配置项，把配置值转成指定类型
     */
    public static func getValue<T>(key: String): ?T where T <: Parsable<T>
    /**
     * 得到名是key的配置项，把配置值用delim切割成字符串数组
     */
    public static func getStringArray(key: String, delim!: String = ','): Array<String>
    /**
     * 得到名是key的配置项，把配置值用delim切割成字符串数组，并用数组的每个元素调用parser转换成指定类型的数组
     */
    public static func getValues<T>(key: String, delim!: String = ',', parser!: (String) -> T): Array<T>
    /**
     * 得到名是key的配置项，把配置值用delim切割成字符串数组，并把每个元素转换成指定类型
     */
    public static func getValues<T>(key: String, delim!: String = ','): Array<T> where T <: Parsable<T>
    /**
     * 得到名是key的配置项，把配置值按照指定格式转换成DateTime
     */
    public static func getDateTime(key: String, format!: String = ''): ?DateTime
    /**
     * 得到名是key的配置项，把配置值用delim切割成字符串数组，并按照指定格式转换成DateTime数组
     */
    public static func getDateTimes(key: String, format!: String = '', delim!: String = ','): Array<DateTime>
    /**
     * 得到名是key的配置项，把配置值转换成指定类型
     */
    public static func getData<T>(key: String): ?T where T <: DataParsable<T>
    /**
     * 得到名是key的配置项，把配置值用delim切割成字符串数组，把数组元素转换成指定类型
     */
    public static func getDatas<T>(key: String, delim!: String = ','): Array<T> where T <: DataParsable<T>
    /**
     * 得到名是key的配置项，并转成Duration
     */
    public static func getDuration(key: String): ?Duration
    /**
     * 得到名是key的配置项，把配置值用delim切割成字符串数组，把数组元素转成Duration
     */
    public static func getDurations(key: String, delim!: String = ','): Array<Duration>
    /**
     * 得到名是bufferKey的配置项的缓冲区大小
     */
    public static func bufferSize(bufferKey: String, default: Int64, debugging: Bool): Int64
    /**
     * 按第5节的sm4配置项构造SM4；sm4Key缺失时返回None，参数不合法时抛IllegalArgumentException
     */
    public static func getSM4(): ?SM4
    /**
     * 注册敏感配置项，value是明文的UTF8字节数组或SM4密文，一般由@EmbedSensitive展开调用
     */
    public static func registerSensitive(key: String, value: Array<Byte>): Unit
}
```

### 3.1 行为细则

| 函数 | 说明 |
| --- | --- |
| `set` | `ifAbsent` 为 `false`（默认）时覆盖旧值；为 `true` 时只有该配置项原本不存在才写入。写完后收集每个配置项名的第一段（`_` 之前的部分）作为前缀，触发匹配的刷新回调 |
| `getAll(prefix)` | 返回 `HashMap`，key 已去掉 `fountain_` 全局前缀；同名的运行期配置覆盖编译期内嵌值 |
| `getAll()` | 等价于 `getAll('')`，返回全部配置项（含解密后的敏感配置） |
| `getStringArray` | 按 `delim` 切分并丢弃空片段，每个元素做 `trimAscii`；没有该配置项时返回空数组 |
| `getValue` / `getData` | 单例读取，走 `tryParse`，解析失败返回 `None`，不抛异常；配置项不存在也返回 `None` |
| `getValues` / `getDatas` | 数组读取，走 `parse`（失败抛异常）；配置项不存在时返回空数组 |
| `getDateTime` | 解析失败抛 `TimeParseException`；配置项不存在返回 `None` |
| `getDateTimes` | 解析失败抛 `TimeParseException`；配置项不存在返回空数组 |
| `getDateTime` / `getDateTimes` | `format` 为空时用 `DateTime.parse(s)`，否则用 `DateTime.parse(s, format)`；`format` 本身不合法抛 `IllegalArgumentException` |
| `bufferSize` | 见表下方说明 |
| `getSM4` | 见第 5 节 |

`bufferSize(bufferKey, default, debugging)` 的返回值：

| 条件 | 返回值 |
| --- | --- |
| 配置项不存在，或值解析失败 | `default` |
| 值 `x <= 0` | `default` |
| `debugging == true` 且 `x > 0` | `x` 原样返回（调试期按字面值使用） |
| `x` 是 2 的幂 | `x` |
| 其它 | 向上取整到 2 的幂 `s`；`s >= default` 返回 `s`，否则返回 `default` |

即非调试模式下返回值恒不小于 `default`，且通常是 2 的幂。

示例：

```cj
import fountain::f_config.*

Config.getValue<Int64>('threadCount')                      // None 或 Int64
Config.getValues<Int64>('ports')                           // ports=8080,9090 -> [8080, 9090]
Config.getDateTime('deadline', format: 'yyyy-MM-dd')       // 按指定格式
Config.bufferSize('ringBufferSize', 1024, false)           // 不小于 1024 且向上取到 2 的幂
Config.set<Bool>([('mySwitch', true)], ifAbsent: true)     // 不存在才写入
Config.getAll('orm')                                       // 所有 orm_ / fountain_orm_ 开头的配置项
```

---

## 4. 配置刷新 refresher

其它模块可以把自身配置的解析结果缓存起来，并通过 `Config.refresher` 登记刷新函数；当有人调用 `Config.set` 改动了属于该前缀的配置时，`Config` 会回调 `fn`。

```cj
static init() {
    Config.refresher(confPrefix, LoggerFactory.refresh)
}
```

* `refresher(prefix, fn)` 以 `${prefix}_` 为键登记回调，同名前缀重复登记会覆盖；
* `set` 用「配置项名第一段」去匹配：前缀登记为 `logger` 的配置形如 `logger_asyncWaitTimeout`、`fountain_logger_rootLevel`；
* 一次 `set` 调用中，每个前缀最多触发一次回调。

> 当前实现的匹配存在缺陷，`set` 实际上不会触发任何回调，详见 [8.1](#81-refresher-匹配失效刷新回调不会被引发)。

---

## 5. 敏感配置与 SM4 加密

有些配置（数据库密码、第三方密钥）不便出现在运行环境中。这类配置可以在**编译期**读取编译机上的环境变量/命令行参数，加密后作为字节数组嵌入编译产物；进程启动时由宏展开的代码注册到一个独立的 `sensitiveMap`，再通过 `getString` 等常规接口读取。

* 未配置 SM4 时：嵌入的是敏感值的 **UTF8 明文**字节数组；
* 配置了 SM4 时：嵌入的是 **SM4 密文**，同时把 SM4 参数一并嵌入，供运行期解密；
* 运行期配置（环境变量/命令行参数）优先级更高，同一配置项如果在运行环境中也配置了，以运行环境的值为准。

### 5.1 SM4 配置项

可用 `fboot randhex 32` 生成指定长度的 16 进制串（32 个十六进制字符 = 16 字节）。

| 配置项 | 含义 | 默认值 | 取值 / 格式 |
| --- | --- | --- | --- |
| `sm4Operation` | 工作模式 | `CBC` | `CBC` `CFB` `CTR` `GCM` `OFB`；`ECB` 不安全，明确不支持，其它值抛 `IllegalArgumentException` |
| `sm4Padding` | 填充模式 | `PKCS7Padding` | `NoPadding` `PKCS7Padding`，其它值抛 `IllegalArgumentException` |
| `sm4Key` | 密钥 | 无，必须配置 | 16 字节，以长度 32 的 16 进制字符串表示；缺失或长度不符抛 `IllegalArgumentException` |
| `sm4Iv` | 初始向量 | 无（配置 `sm4Key` 后必须配置） | 16 进制字符串；`CBC`/`OFB`/`CFB` 要求 16 字节，`GCM` 要求 12 字节，不符抛 `IllegalArgumentException` |
| `sm4Aad` | 附加认证数据 | 空字节数组 | 16 进制字符串 |
| `sm4TagSize` | GCM 的 tag 长度 | `16` | `Int64` 字符串 |

以上配置项同样支持 `fountain_` 前缀形式（`fountain_sm4Key` 等）。它们的名称常量为 `Config.sm4Operation`、`Config.sm4Key` 等，可直接引用。

命令行参数示例（编译期）：

```bash
export paySecretKey='......'
export sm4Key=$(fboot randhex 32)   # 16 字节密钥
export sm4Iv=$(fboot randhex 32)    # CBC 的 IV；GCM 用 fboot randhex 24
```

### 5.2 数据结构与读取

```cj
public static func registerSensitive(key: String, value: Array<Byte>): Unit  // 写入 sensitiveMap
public static func getSM4(): ?SM4                                            // sm4Key 缺失时 None
```

* `sensitiveMap` 是 `ConcurrentHashMap<String, Array<Byte>>`，与 `ARGS` 相互独立，只用 registerSensitive 写入；
* `getString` / `getAll` 读到敏感值时调用 `getSM4()` 解密，再按 UTF8 还原字符串；未配置 SM4 时按明文字节还原；
* 每次解密都会**重新构造一次 `SM4` 实例**并读取全部 SM4 配置项，敏感配置多或读取频繁时建议自行缓存结果。

> 注意：SM4 参数本身（含密钥）会以字节数组形式出现在编译产物中。该机制抬高的是「直接从二进制里 grep 出配置」的门槛，不能替代密钥管理服务。

---

## 6. @EmbedSensitive 宏

```cj
macro package fountain::f_config.macros

public macro EmbedSensitive(input: Tokens): Tokens
```

在源文件**顶层**调用，参数是若干需要将编译期取值嵌入产物的配置项名（标识符；逗号分隔亦可，宏只取 `IDENTIFIER` / 字符串字面量 token，其余 token 被忽略）：

```cj
import fountain::f_config.macros.*

@EmbedSensitive(paySecretKey pushToken)
```

宏展开得到一个立即执行的匿名闭包，把敏感值注册到 `sensitiveMap`：

```cj
private let _ = {=>
    Config.registerSensitive('paySecretKey', [...密文或明文字节...])
    Config.registerSensitive('pushToken', [...])
    Config.registerSensitive('sm4Operation', ...)
    Config.registerSensitive('sm4Padding', ...)
    Config.registerSensitive('sm4Key', ...)
    Config.registerSensitive('sm4Iv', ...)
    Config.registerSensitive('sm4Aad', ...)
    Config.registerSensitive('sm4TagSize', ...)
}()
```

嵌入规则：

1. **编译期取不到值的名字会被忽略**（编译机上没有对应环境变量/命令行参数就不注册）；
2. 编译期配置了 `sm4Key` 时写入 SM4 密文，否则写入 UTF8 明文字节数组；
3. 只有在「至少注册了一项敏感值」且「`sm4Key` 非空」时，才会把 SM4 的 operation / padding / key / iv / aad / tagSize 一并写入，供运行期解密；SM4 参数本身按明文字节写入；
4. 同名项重复注册以最后一次为准；
5. 运行期再读取时遵循 [2.3 的优先级](#23-读取优先级)：环境变量/命令行参数 > 内嵌值。

`f_orm` 是基于该宏的封装示例：`f_orm/src/ProtectedMacros/EmbedSensitive.cj` 生成 ORM 的连接串、用户名、口令键并转调 `@EmbedSensitive`，最终在 `f_orm/src/base/imports.cj` 中以 `@ORMEmbedSensitive()` 触发。

---

## 7. 可配置时间转换器

把某个配置项的值当作 `DateTime` 的解析格式使用：`fountain::f_data.AbstractDateTimeConverter` 的子类，可标注在成员属性、成员变量和参数上。

```cj
package fountain::f_config

import fountain::f_data.*

@Annotation[target: [MemberProperty, MemberVariable, Parameter]]
public class DateTimeConfConverter <: AbstractDateTimeConverter {
    public const DateTimeConfConverter(private let conf: String, private let default!: String = 'yyyy-MM-dd HH:mm:ss'){}
    public func convert(data: Data, flag!: DataConversionFlag = DEFAULT_DATA_FLAG): ?DateTime
}
```

* `conf`：保存时间格式的配置项名，按 [2.3](#23-读取优先级) 读取（支持 `fountain_` 前缀回退）；
* `default`：该配置项不存在时使用的格式，默认 `'yyyy-MM-dd HH:mm:ss'`。

```cj
@DateTimeConfConverter[myDateFormat]
private var createdAt: DateTime = DateTime.now()

// export myDateFormat='yyyy/MM/dd'
```

---

## 8. 已知问题

### 8.1 refresher 匹配失效，刷新回调不会被引发

`refresher` 以 `${prefix}_`（带尾随下划线）为键登记回调，而 `Config.set` 收集的前缀是配置项名在第一个 `_` **之前**的片段：

```cj
REFRESHER['${prefix}_'] = fn                    // 例如 'logger_'
...
if (let Some(x) <- name.indexOf('_')) {
    set.add(name[0..x])                         // 'logger_asyncWaitTimeout' -> 'logger'（不含下划线）
...
for (k in set where k.startsWith(prefix) || k.startsWith('${Config.prefix}_${prefix}')) {
```

仓颉的 `a..b` 是左闭右开区间，因此 `k` 恒为 `'logger'`，`'logger'.startsWith('logger_')` 恒为 `false`，第二个条件 `'fountain_logger_'` 更不可能匹配。结果是 **`set` 写入配置不会触发任何刷新回调**（疑似 `name[0..x]` 应为 `name[0..=x]`）。

影响：`f_log` 的 `LoggerFactory.refresh` 登记后永远不会被再次调用；`f_orm` 的 `ORMConfig.refresh{...}` 只在 `static init` 里被调用方能拿到一次执行，运行期再 `set` 配置同样不会被感知。

### 8.2 SM4 异常文案残留其它模块名

`sm4Key` / `sm4Iv` 不合法时抛出的 `IllegalArgumentException` 文案是 `"orm config item ${Config.sm4Key} ..."`，源自 f_orm 的实现，与本模块的配置项名无关，属措辞遗留。

### 8.3 跨模块文档不一致

`f_orm/README.md` §18.1 把 SM4 配置项写成 `orm_sm4Key` 等，但本模块实际读取的名字是不带模块前缀的 `sm4Key`（见 `fdemo/boot.sh` 中的 `--sm4Key=`）。以本文件为准。

### 8.4 其它实现细节

* `getAll` 使用 `String.replace('fountain_', '')` 去前缀，会替换字符串中的**全部**匹配片段，key 中间再次出现该子串时会被一并去掉；
* `SM4Conf.getBytes` 的三个分支都会返回 `Some`，其 `else` 分支（"没有配置项"时的异常文案）不可达，缺失配置最终在 key/iv 的长度校验处报错；
* `getAll` 的去前缀行为对 `ARGS` 与 `sensitiveMap` 一致，二者同名时以 `ARGS`（运行期配置）为准。
