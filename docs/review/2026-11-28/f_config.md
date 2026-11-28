# f_config 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_config`（4 个源文件，另有 2 个 `.md`）
- **基线**：工作区快照（sts/1.3.x 工作区，未对照远端分支；`git blame` 显示 `Config.cj` / `EmbedSensitive.cj` 涉及行全部来自 `4be871f2f`、`a91d1d01dd`、`e411582af5`（2026-10-02），`Config_test.cj` 来自 `2b3da0c3f`（配置支持删除键），故全部记为存量）
- **审查重点**：配置加载正确性、死代码、重复逻辑（与 `f_cmd` 的 argv 解析）、并发安全、存量 BUG、README 覆盖率
- **报告版本**：v1

## 发现

> 编号索引：#1 refresher 回调永不触发 ／ #2 `CTR` 被 iv 校验判为非法 ／ #3 `@EmbedSensitive` 标识符写法不可编译 ／ #4 两套 argv 解析且规则漂移 ／ #5 GCM 固定 nonce 复用 ／ #6 `remove` / `getDylibPattern` 未进 README ／ #7 `getAll` 去前缀与键冲突 ／ #8 `getBytes` 的 `else` 不可达 ／ #9 `bufferSize` 无上界 ／ #10 空 `format` 两处语义不同 ／ #11 `registerSensitive` 持有入参数组 ／ #12 测试只覆盖 `set`/`remove` ／ #13 README 注解示例疑不可编译。

### [严重][存量] #1 refresher 前缀匹配恒不成立，`Config.set` / `Config.remove` 写入后永不触发刷新回调

- **位置**：登记 `f_config/src/Config.cj:102`；`set` 收集前缀 `f_config/src/Config.cj:116`–`120`、分发 `f_config/src/Config.cj:122`–`127`；`remove` 同源 `f_config/src/Config.cj:139`–`149`
- **来源**：存量（`git blame -L 102,127 -- f_config/src/Config.cj` → `4be871f2f`，2026-10-02）
- **判据**：review-checklist §11（契约与实现不符、静默失效）+ §3（接口承诺行为但从不执行）+ §1（`REFRESHER` 只写不读，等价死配置）
- **证据**：静态确定 —— `refresher` 以 `'${prefix}_'`（带尾随下划线，如 `logger_`）为键；`set` 收集的是「配置项名第一个 `_` 之前」的片段，且仓颉 `a..b` 为左闭右开，故 `k` 恒为 `logger`（不含 `_`）。`k.startsWith(prefix)` 即 `'logger'.startsWith('logger_')` 恒 `false`；第二个条件 `'fountain_logger_'` 含 `_`，`k` 内不存在 `_`，同样恒 `false`。`remove` 用同一算法（`key[0..prefixEnd]`）复制了同一处错误，因此两个写入口都不触发回调。
- **描述**：`f_log/src/base/LoggerConfig.cj:39`（`LoggerFactory.refresh`）与 `f_orm/src/wrap/ORMConfig.cj:83` 登记的回调在运行期永远不会被再次调用：`Config.set` 改了日志级别 / ORM 连接项后，各模块缓存的解析结果保持旧值，属静默失效——调用方只会看到"配置改了没生效"，且没有任何日志。`REFRESHER` 由此成为只写不读的容器。README §8.1（`README.md:379`–`394`、`README_en.md:397`–`416`）已把该缺陷记录为已知问题，但仍是对外 API 承诺（`README.md:123`）未兑现。
- **建议**：`REFRESHER` 存裸前缀（`REFRESHER[prefix] = fn`）并按 `k == prefix` 比较；或保留带下划线的键、把收集式改成 `name[0..=x]`。`set` / `remove` 共用同一个 `dispatch(prefixes: HashSet<String>)` 私有函数，删掉两份重复实现。补用例：登记 `logger` → `set(['logger_level', v])` → 回调计数 = 1；一次 `set` 改两项同前缀配置 → 计数仍为 1。修复时注意重入：回调内再调 `Config.set` 会递归触发，需要重入标记或"待派发队列"。

### [一般][存量] #2 `sm4Operation=CTR` 在 iv 校验里落入 `case _`，抛"CTR 不是合法 OperationMode"

- **位置**：`f_config/src/Config.cj:357`–`361`（iv getter 的 `match`）；对照 `f_config/src/Config.cj:283`–`289`（`getSM4` 明确接受 `CTR`）；文档承诺 `f_config/README.md:274`、`f_config/README_en.md:288`
- **来源**：存量（`git blame -L 354,367` → `4be871f2f`）
- **判据**：review-checklist §11（逻辑错误 / 契约与实现不符）+ §13（文档承诺与实现相反）
- **证据**：静态确定 —— `match` 只有 `'CBC' | 'OFB' | 'CFB'`（16 字节）与 `'GCM'`（12 字节）两组分支，`CTR` 无分支命中，落到 `case _ => throw IllegalArgumentException("${operation} is not a legal sm4 OperationMode…")`。`iv` 作为 `SM4(..., iv: iv, ...)` 的实参先求值（`Config.cj:290`–`294`），因此 `getSM4()` 对 `CTR` 必定抛异常，走不到构造。
- **描述**：README 的 SM4 配置表把 `CTR` 与 `CBC`/`CFB`/`GCM`/`OFB` 并列为合法取值，`getSM4` 的 operation 分支也接受 `CTR`，但 iv 校验没有 `CTR` 分支：凡是配置 `sm4Operation=CTR` 的应用，第一次读取任何敏感配置（`getString` → `sensitive2Str` → `getSM4`）就抛 `IllegalArgumentException`，且文案反过来声称该模式非法——与真实原因（iv 长度未校验）完全不符。CTR 的 IV 是 16 字节计数器初值，语义上应与 CBC/OFB/CFB 同级（只有 GCM 是 12 字节 nonce）。
- **建议**：把 `CTR` 并入 16 字节分支：`case 'CBC' | 'OFB' | 'CFB' | 'CTR' where bytes.size != 16 => throw …`、`case 'CBC' | 'OFB' | 'CFB' | 'CTR' => bytes`；顺手把 "is suggested" 改成 "must be"（当前是硬校验，不是建议）。补一条 `getSM4` 参数化用例覆盖 5 种模式。

### [一般][存量] #3 `@EmbedSensitive` 只支持字符串字面量参数，README 的标识符写法展开成引用未定义变量

- **位置**：`f_config/src/macros/EmbedSensitive.cj:24`–`38`（尤其 `:30`、`:34` 的 `$k`）；契约源 `f_config/README.md:314`–`320` 与展开示意 `f_config/README.md:325`–`334`、`f_config/README_en.md:329`–`350`
- **来源**：存量（`git blame -L 24,35` → `a91d1d01dd`，2026-10-02；`tokens` 循环骨架 → `e411582af5`）
- **判据**：review-checklist §13（示例不能用 / 展开结果与文档不符）+ §14.1（承诺了但没实现）
- **证据**：静态确定 —— `quote` 插值 `Token` 时按原 token 拼入（`Tokens_types_and_quote_expressions.md:96`–`125`：插值 `String` 才生成字符串字面量，插值 `Token`/`Tokens` 原样拼入；`Tokens.toString()` 输出源码片段）。仓内旁证：`f_jit/src/macros/JitBind.cj:157` 必须显式 `Token(TokenKind.STRING_LITERAL, nameTok.value)` 才能把名字变成字面量。`k.value` 不含引号（`f_data/src/path/ObjectEqFilter.cj:70` 有同样结论的注释），所以 `Config.getString(k.value)` 查得到值，但 `$k` 拼出的是裸标识符。
- **描述**：README §6 的主示例 `@EmbedSensitive(paySecretKey pushToken)` 走 `TokenKind.IDENTIFIER` 分支，展开结果是 `Config.registerSensitive(paySecretKey, [...])`——`paySecretKey` 是未定义变量，编译直接失败；而 README:325-334 的展开示意写的是 `registerSensitive('paySecretKey', …)`，与实现不符。实际能用的只有字符串字面量形式（`f_orm` 通过 `$(ORMConfig.connectionUrl)` 生成 `"orm_connectionUrl"`，`f_orm/src/ProtectedMacros/EmbedSensitive.cj:42`）。即宏对外承诺两种入参，只实现了一种，且文档示例正好是坏的那一种。
- **建议**：把名字显式转成字面量再插值——`let keyLit = Token(TokenKind.STRING_LITERAL, k.value)`，`quote(Config.registerSensitive($keyLit, $cipher))`（与 `JitBind.cj:157` 一致）；`IDENTIFIER` 与三种字符串字面量都归一成 `k.value`。README 要么改成字符串字面量示例，要么修好后补一条"标识符与 `'x'` 等价"的用例。

### [一般][存量] #4 同一份 `argv` 有两套解析（`f_config` 与 `f_cmd`）且规则漂移，另有空键 / 负值边界

- **位置**：`f_config/src/Config.cj:66`–`97` 与 `f_cmd/src/CmdArgs.cj:31`–`57`；边界 `f_config/src/Config.cj:77`、`:82`
- **来源**：存量（`git blame -L 62,98 -- f_config/src/Config.cj` → `4be871f2f`；`f_cmd` 侧同批提交，`f_cmd` 报告 #5 已从另一侧记录同一问题）
- **判据**：review-checklist §2（近似重复 → 行为漂移）+ §11（边界）
- **证据**：静态确定 —— 两边共用同一组字面量与调用（`'--'`、`'-'`、`indexOf('=')`、`trimAscii`、`env.getCommandLine()[1..]`、`i + 1 < args.size`），但分支动作不同：① `--flag`：`f_config` 记 `'true'`（`:78`），`f_cmd` 记空列表（`CmdArgs.cj:47`–`49`）；② `-k v`：`f_config` 键为 `k`（去掉横线，`:82`）且只吃紧随一个值，`f_cmd` 键为 `-k`（保留横线，`CmdArgs.cj:51`）并把后续位置参数全部收集；③ 重复键：`f_config` 后者覆盖（`ARGS[key] = val`），`f_cmd` 追加成多值；④ 无归属位置参数：`f_config` 忽略（无 `else` 分支），`f_cmd` 抛 `NoneValueException`。
- **描述**：同一条命令行在两个模块得到不同键名与不同值形态，排障时互相误导（例如 `-logLevel debug` 在 `Config` 里是键 `logLevel`，在 `CmdArgs` 里是键 `-logLevel`）。另有两处未记录边界：`--`（长度恰为 2）与单独的 `-` 会写入空键 `ARGS['']`（`:77`、`:82` 切片得空串）；`-port -1` 无法表达负值（`val.startsWith('-')` 判定为下一个开关），README:46 说明了"以 `-` 开头不作为值"，但没说明负数的后果。
- **建议**：把 tokenizer（把 `--k` / `--k=v` / `-k` / `-k v` 切成 `(name, value?)`）抽到 `f_util`，两侧只决定"如何去横线、是否多值、多值怎么合并"；空键显式跳过；README 补一行"负数值请用 `--k=-1`"。

### [一般][存量] #5 GCM 模式下所有内嵌敏感值共用同一个 IV（nonce 复用）

- **位置**：`f_config/src/macros/EmbedSensitive.cj:27`–`31`（对每个值复用同一个 `sm4` 实例加密）；IV 来源 `f_config/src/Config.cj:354`–`367`（单一配置项 `sm4Iv`）
- **来源**：存量（`git blame -L 27,31` → `a91d1d01dd`）
- **判据**：review-checklist §10（安全性 / 密码学误用）+ §11（契约）
- **证据**：静态确定 —— 宏循环内 `Config.getSM4()` 每次按同一 `iv` 构造，`sm4.encrypt(vbytes)` 对所有敏感值使用同一 nonce；`SM4Conf.iv` 只在 GCM 分支校验长度（12 字节），没有唯一性要求。
- **描述**：GCM 要求"同一密钥下 nonce 唯一"。当前实现对 N 个敏感值用同一 nonce 加密：攻击者拿到产物即可得到任意两个明文块的异或关系，并可伪造带合法 tag 的密文（GCM 认证失效）；CBC/CFB/OFB 下固定 IV 则让相同前缀的密文相等，泄露"两个密钥是否相同/同前缀"。默认模式是 CBC（影响较小），但 README §5.1 把 GCM 列为可选，未提示该限制。注意：README:302 只声明"该机制不能替代密钥管理服务"，与本条不是同一件事。
- **建议**：每个值生成随机 IV，把 `iv || cipher` 一起嵌进字节数组，解密时按模式切分（GCM 12 字节、其余 16 字节）；或至少在 README §5.1 与 `sm4Iv` 行写明"GCM 下所有内嵌值共享同一 nonce，禁止多值使用"。

### [一般][存量] #6 `Config.remove` / `Config.getDylibPattern` / `dylibPattern` 是公开 API，但两份 README 完全没有条目

- **位置**：缺失面 `f_config/README.md:112`–`196`（API 段）、`f_config/README.md:79`–`81`（§2.5 进程内写入）；未文档化符号 `f_config/src/Config.cj:136`（`remove`）、`:304`（`getDylibPattern`）、`:58`（`dylibPattern`）
- **来源**：存量（`remove` 见 `git blame -L 136,150` → `2b3da0c3f`；`getDylibPattern` → `90f62c03b`）
- **判据**：review-checklist §14.2（公开 API 未文档化）
- **证据**：静态确定 —— `grep -n "remove\|getDylibPattern\|dylibPattern"` 在两份 README 只命中 "is removed" 这类无关措辞，无函数/常量条目；`Config.remove` 在 `fmq/src/config/MQConfig_test.cj:49`、`fprobe/src/config/Settings_test.cj:30`、`f_llm/src/store/StoreSettings_test.cj:27`、`f_mcp/src/server/McpConfig_test.cj:35`、`f_jsonrpc/src/server/JsonRpcServer_test.cj:431` 等大量用例中被调用；`getDylibPattern` 是 fboot 启动参数入口（`f_app/src/App.cj:494`）。
- **描述**：`remove` 的语义（真正删除 vs 写空串、是否同时清 `sensitiveMap`、是否应触发刷新）只写在源码注释里，README 的 §3.1 行为表与 §2.5 都只讲 `set`；`--dylibPattern` 是 fboot 必填项（`f_app/src/App.cj:496` 报错文案），但读者从 f_config README 无法得知该配置项由本模块读取。按文档用不起 `remove`，也不会知道 `getDylibPattern` 存在。
- **建议**：API 段补三个符号；§3.1 补一行 `remove`（含"删除后回到 `None`、与 `set(key, '')` 的区别、`sensitiveMap` 一并删除"）；§2.5 提到 fboot 用 `--dylibPattern=<regex>` / `fountain_dylibPattern` 传入。

### [轻微][存量] #7 `getAll` 去前缀用 `replace` 全量替换，且 `x` 与 `fountain_x` 同时存在时输出键冲突、取值非确定

- **位置**：`f_config/src/Config.cj:161`、`:164`（`k.replace('fountain_', '')`）；同名冲突 `f_config/src/Config.cj:160`–`168`
- **来源**：存量（`git blame -L 155,170` → `4be871f2f`）
- **判据**：review-checklist §11（边界 / 非确定输出）
- **证据**：静态确定 —— `String.replace(pattern, replacement)` 替换全部匹配，`'a_fountain_b'` → `'a_b'`；`ARGS` 与 `sensitiveMap` 两轮循环写入同一个 `map`，`x` 与 `fountain_x` 去前缀后都是 `x`，`ARGS` 轮内两者互相覆盖、`sensitiveMap` 轮只在 `value.isNone()` 时写，因此最终值取决于 `ConcurrentHashMap` 迭代顺序（同一次运行稳定、跨运行/跨版本不保证）。
- **描述**：键名中间再次出现 `fountain_` 会被误删（README §8.3 已记录一半）；更实质的是双前缀同名时的取值不确定，`getString` 此时恒定取裸键 `x`，与 `getAll` 的返回可能不一致。
- **建议**：改成 `if (k.startsWith('fountain_')) { k[9..] } else { k }`（只剥一次、只在头部）；冲突时显式定优先级（裸键 > `fountain_` 键），并在 `getAll` 里跳过已存在的键而不是覆盖。

### [轻微][存量] #8 `SM4Conf.getBytes` 没有 `None` 返回路径，`key` / `iv` 的 `else` 分支（含两条专用错误文案）是不可达死代码

- **位置**：`f_config/src/Config.cj:349`–`351`（key 的 else）、`:363`–`365`（iv 的 else）；对照 `f_config/src/Config.cj:322`–`330`（`getBytes`）
- **来源**：存量（`git blame -L 341,367` → `4be871f2f`）
- **判据**：review-checklist §1（恒假分支 / 不可达语句）+ §11（错误文案与真实原因不符）
- **证据**：静态确定 —— `getBytes` 三个分支分别返回 `Some(bytes)`、`Some(fromHexString(v))`、`Some([])`（缺省返回裸 `[]` 被隐式包成 `Some`），不存在 `None` 路径，故 `if (let Some(bytes) <- getBytes(...))` 的 `else` 永不执行。
- **描述**：两条文案（"not a legal hex string or is not be specified…"）永远不可能出现；真实缺 `sm4Key` 时走 `bytes.size == 0` 直接返回空数组（`getSM4` 随后判空返回 `None`，行为正确），缺 `sm4Iv` 时报的是 `"size 16 of orm config item sm4Iv is suggested…"`——原因说成"长度不符"，实际是"没配置"，排障会被带偏（`orm` 字样残留见 README §8.2）。
- **建议**：`getBytes` 缺省分支返回 `None`（或删掉两个 `else`，把"缺配置"判断前移到 `key`/`iv` 入口并给准确文案）；文案统一改成 `${Config.sm4Iv} is required when sm4Key is set`。

### [轻微][存量] #9 `bufferSize` 没有上界校验，`x` 接近 `Int64` 上限时 `s <<= 1` 溢出

- **位置**：`f_config/src/Config.cj:259`–`267`（`var s = 1; while (s < x) { s <<= 1 }`）
- **来源**：存量（`git blame -L 250,271` → `4be871f2f`）
- **判据**：review-checklist §11（边界）
- **证据**：待确认 —— 文档（`basic_data_type/basic_operators.md:5`）写明"算术操作符的结果会被检测并禁止值溢出"，默认溢出策略抛异常；`<<` 的结果溢出是否同样抛 `ArithmeticException`（而非回绕）需实测。无论哪种，都不满足 README:223 承诺的"向上取整到 2 的幂，否则 `default`"。
- **描述**：`x > 2^62` 时循环把 `s` 推到 `2^63`：抛异常则配置读取直接失败并冒泡到调用方；回绕则 `s` 变负/归零，`while (s < x)` 可能永不结束。触发条件是配置值 ≈ 9.2e18，属"异常配置"，但函数没有任何上界拒绝路径。
- **建议**：`while (s < x && s > 0)`，循环后 `if (s <= 0) { return default }`；或先 `if (x > (1 << 62)) { return default }`。补表驱动用例：`0`、负数、`1`、`1024`、`1000`、`2^62 + 1`。

### [轻微][存量] #10 「空 `format` 走默认解析」在两处实现不一致：`Config.getDateTime` 与 `DateTimeConfConverter`

- **位置**：`f_config/src/DateTimeConfConverter.cj:24`（`Config.getString(conf) ?? default` 直接传两参 `parse`）与 `f_config/src/Config.cj:225`–`231`（`parseDateTime`：`format.isEmpty()` → 单参 `DateTime.parse`）
- **来源**：存量（`git blame -L 21,25` → `4be871f2f`）
- **判据**：review-checklist §2（近似重复、其中一个少了边界判断）+ §11（行为漂移）
- **证据**：静态确定（两处对空 `format` 的分支不同）+ 待确认（`DateTime.parse(s, "")` 是否被判为 `format` 非法；std 文档只写"当 format 格式不正确时抛 `IllegalArgumentException`"）
- **描述**：配置项**不存在**时 `DateTimeConfConverter` 用 `'yyyy-MM-dd HH:mm:ss'`；配置项**存在但为空串**（`dateFormat=` / `Config.set(['dateFormat',''])`）时把 `''` 当格式传给两参 `parse`，抛 `IllegalArgumentException`，再被 `f_data` 的 `doConvert` 按 flag 吞成 `None`（`DEFAULT_DATA_FLAG` 含 `IGNORE_FIELD_NOT_CONVERTABLE`）。同一个空格式在 `Config.getDateTime(key, format: '')` 里却表示"自动解析"，两处语义相反。
- **建议**：把 `parseDateTime` 提成 `internal`（或私有工具）供两边复用；`DateTimeConfConverter` 改成 `let fmt = Config.getString(conf); if (fmt.isEmpty()) { default }`，再走同一 helper。

### [轻微][存量] #11 `registerSensitive` 直接持有调用方数组引用，注册值可被后续修改

- **位置**：`f_config/src/Config.cj:296`–`298`
- **来源**：存量（`git blame -L 296,298` → `4be871f2f`）
- **判据**：review-checklist §11（契约 / 封装）+ §10（值语义）
- **证据**：静态确定 —— `sensitiveMap[key] = value` 存入的是同一个 `Array<Byte>` 实例，`Array` 是引用类型，函数内无 `clone()`。
- **描述**：公开 API 承诺"注册敏感配置项"，调用方若复用/改写缓冲区，会让已注册的"内嵌常量"随之外变（`getAll`、`getString` 解出的值随之变化）。当前唯一调用方是宏生成的 `[...]` 字面量（每次新建），所以现状未爆发，属契约缺口。
- **建议**：存 `value.clone()`；或注释与 README 明确"调用方不得在注册后修改传入数组"。

### [轻微][存量] #12 测试只覆盖 `set` → `remove` 两条路径，配置加载主路径 0 用例

- **位置**：`f_config/src/Config_test.cj:21`–`36`（全部用例）
- **来源**：存量（`git blame -L 21,36` → `2b3da0c3f`）
- **判据**：review-checklist §14（功能完备性）+ §10（可测试性）
- **证据**：静态确定 —— 全文件两个 `@TestCase`：`set` 后 `remove` 回到 `None`、`remove` 缺失键为空操作。
- **描述**：本轮重点全部无用例：命令行四种写法与覆盖顺序、`fountain_` 前缀回退（`getString`/`getAll` 四条查找顺序）、`getAll(prefix)` 过滤、`bufferSize` 六种分支、`getSM4` 五种模式与非法参数、`@EmbedSensitive` 展开、`refresher` 触发。这正是 #1/#2/#8 长期未暴露的原因；`static init` 读全局 `env`，没有可注入入口，也是难测的根因。
- **建议**：把 `static init` 的循环体抽成 `internal func parseArgs(args: Array<String>)`（`static init` 只负责 `getVariables` + `getCommandLine` 调用），即可对四种写法、重复键、空键、负值直接写用例；`bufferSize` / `getSM4` 用表驱动。

### [轻微][存量] #13 README §7 的注解示例 `@DateTimeConfConverter[myDateFormat]` 参数未加引号，疑似不可编译

- **位置**：`f_config/README.md:369`–`373`、`f_config/README_en.md:387`–`391`
- **来源**：存量（`git blame -L 365,373 -- f_config/README.md` → `4be871f2f` 系列文档提交）
- **判据**：review-checklist §13（示例不能用）
- **证据**：待确认 —— 注解实参须为常量表达式，`myDateFormat` 是裸标识符而非 `String` 常量；仓内真实注解一律用字符串字面量（`f_llm/src/llm/LLMResp.cj:25` `@FieldAlias['finish_reason']`、`fprobe/src/report/ChartSpec.cj:57` `@FieldAlias['type']`）。缺一次 `cjpm build` 验证。
- **描述**：示例意在说明"配置项名作为注解参数"，但按现有写法用户复制即编译失败；`DateTimeConfConverter` 仓内零使用点（`grep @DateTimeConfConverter` 只命中两份 README），说明该示例从未被编译验证。
- **建议**：改成 `@DateTimeConfConverter['myDateFormat']`（中英同步）；若确实支持裸标识符，需在 §7 说明依据。附带建议 §7 补一句"配置项存在但为空串 → 视为默认格式"（见 #10）。

## 优化可行性方案

> 不是缺陷，是"还能更好"。本模块为启动期读取 + 低频读取，收益受调用次数限制；两条均无基线。

### [CPU] 每次读取敏感配置都重建一次 `SM4`（6 次查找 + hex 解析 + 密码器初始化）

- **现状**：`getString` 命中 `sensitiveMap` 时走 `sensitive2Str`（`Config.cj:174`–`182`）→ `getSM4()`（`:272`–`295`）→ 每次新建 `SM4Conf` 并读 `operation`/`padding`/`key`/`iv`/`aad`/`tagSize` 六项（`Config.cj:299`–`303`、`331`–`377`），其中 `getBytes` 还会对 hex 串重新解码；`getAll()` 对每个敏感项各做一次。对象生命周期仅一次调用，不缓存。
- **方案**：加一层 `private static var cachedSM4: ?(String, SM4)`，指纹由六个参数值拼成（或用一个 `sm4Epoch` 计数器，在 `set`/`remove` 命中 `sm4*` 前缀时自增）；命中则复用实例，敏感明文也可按 `(key, epoch)` 缓存解密结果。
- **预期**：单次敏感读取省掉一次 `SM4` 构造与 6 次 map 查找 + 至多 4 次 hex 解码；占比取决于读取频次（`getAll` 一次读 N 项时最明显），端到端收益未测。
- **代价**：引入失效语义（SM4 参数变更必须重建，否则用旧密钥解新密文）；`SM4` 是否可复用/线程安全需先核对 `stdx.crypto` 文档；缓存本身是新的无界面（需按 key 数量设上限）。
- **验证**：`cjpm bench -O2`，对照 1e5 次 `Config.getString(<内嵌敏感键>)` 与 1e4 次 `getAll()`（env 200 项 + 敏感 10 项），取中位数与离散度；`cjprof record` 看 `SM4` 构造自耗时占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `getStringArray` 把 `split` 结果整份复制成第二个数组

- **现状**：`Config.cj:210`–`217` 先 `x.split(delim, removeEmpty: true)` 得到 `Array<String>`，再 `Array<String>(arr.size) { i => arr[i].trimAscii() }` 生成第二个等长数组；两份数组同时存活到函数返回，`trimAscii` 再产生 N 个新串（原串仍被 `arr` 持有到作用域结束）。
- **方案**：`let parts = x.split(delim, removeEmpty: true)` 后原地替换元素（`parts[i] = parts[i].trimAscii()`，若 `Array` 元素可写）或改为一次 `collectArray` 映射；`getValues` 已有同样的二次分配（`:218`–`221`）可一并处理。
- **预期**：每次调用少一份 N 元素指针数组（8N 字节 + 头）与一次扩容；N 为配置值里的字段数（典型 < 20），绝对量级很小。
- **代价**：若 `split` 返回的 `Array` 不可写则只能选 `collectArray`（仍省不了 N 个新串，只能省一份数组）；行为不变（顺序、去空、trim 语义保持一致）。
- **验证**：`cjpm bench -O2` 对照 1e5 次 `getStringArray`（N = 20），比较 `getAllocatedHeapSize()` 与中位耗时。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 没有性能测试数据支撑的猜测。**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 敏感配置解密时的 `SM4` 构造是可测的 CPU 热点（尤其 `getAll` 一次解 N 项） | `f_config/src/Config.cj:174`、`:272` | `SM4` 构造自耗时占比、单次耗时 | `cjprof record` 跑 1e5 次 `getString(敏感键)` 与 1e4 次 `getAll()`，看 `SM4` 构造 / `fromHexString` 的 self time |
| 2 | `getStringArray` / `getValues` 的二次数组分配在批量解析下可测 | `f_config/src/Config.cj:212`、`:220` | 分配字节数、单次耗时 | `cjpm bench -O2` 对照改造版，1e5 次调用、N = 20，取中位数与离散度 |
| 3 | `Config.set` 前缀分发在修复 #1 后是否成为写路径热点（`#REFRESHER × #keys` 的 `startsWith`） | `f_config/src/Config.cj:122` | 单次 `set` 的耗时与回调次数 | 加计数埋点 + 分段计时，跑 `set` 1e5 次（前缀 50 个、键 200 个） |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_config/README.md` | .md | ✅ | 404 行全文读完；§8.1–8.3 的"已知问题"与实现一致（复核成立），另命中 #6（`remove`/`getDylibPattern` 缺段）、#13（:369 示例）、#5（:274 的 CTR 承诺）、#4（:46 负值未说明） |
| 2 | `f_config/README_en.md` | .md | ✅ | 429 行全文读完；与中文版逐节同步（8.1–8.3、API 段、示例均在），无独立缺陷，#6/#13 同步存在 |
| 3 | `f_config/src/Config.cj` | .cj | ✅ | 378 行全文读完；#1、#2、#4–#9、#11 位置；`static init` 四种命令行写法、四条查找顺序、`bufferSize` 六分支逐行核对 |
| 4 | `f_config/src/Config_test.cj` | .cj | ✅ | 37 行全文读完；#12 位置（只有 2 个用例） |
| 5 | `f_config/src/DateTimeConfConverter.cj` | .cj | ✅ | 26 行全文读完；#10、#13 位置；`convert` 是 `AbstractDateTimeConverter` 的抽象实现（`f_data/src/base/DataConverter.cj:25`–`37`），不算死代码 |
| 6 | `f_config/src/macros/EmbedSensitive.cj` | .cj | ✅ | 55 行全文读完；#3、#5 位置；SM4 参数内嵌条件（`tokens.size > 0`）与 README §6 规则 3 一致 |

合计：`.cj` 4 个 / `.md` 2 个 / 共 6 个，全部读完。

范围外提示（不计入统计）：`f_config/src/config_test.cj.macrocall` 是构建期宏展开产物，未被 git 跟踪（`git ls-files` 无此项），`cjpm.toml` 的 `exclude` 也未包含 `*.macrocall`；`cjpm.toml` 不在本模块文件清单内，未审（其 `${CANGJIE_STDX_DYNAMIC_PATH}` 与 README §1 的说法一致）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 8 | #2、#3、#4、#5、#7、#9、#10、#11（与 §1/§2/§11 有重叠，按主判据归口）；命名与可读性未见实质问题，`Config.remove` 的文档注释与实现一致 |
| §1 死代码 | 1 | 逐个符号核过：`prefix`/`ARGS`/`REFRESHER`/`sensitiveMap`/`sensitive2Str`/`parseDateTime` 均被读写；`SM4Conf` 及其 6 个 `protected` prop、`getString`/`getBytes` 全部有调用者（含宏包内使用，`Config.sm4conf` 从 `fountain::f_config.macros` 访问属 `protected` 的模块内可见）；`public` 声明对外可达，按硬原则一不判；无 `return`/`throw` 后同层语句；import 全部使用。唯一命中 #8（`getBytes` 恒 `Some` 导致 `key`/`iv` 的 `else` 不可达） |
| §2 重复逻辑 | 2 | 同文件内 `Config` 的 24 个函数体与 `SM4Conf` 的 8 个访问器两两比对：`getValue`/`getData`、`getValues`/`getDatas`、`getDuration(s)` 是"类型约束不同"的薄封装，属刻意的 API 分层不计；`SM4Conf.getString` 与 `Config.getString` 近似但差异是"避免解密自身参数"，属必要差异。跨文件按字面量 `'--'`/`'='`/`trimAscii`/`getCommandLine()[1..]` 与 `DateTime.parse(s, format)` 搜索，命中 #4、#10 |
| §3 空实现 | 0 | 无 `TODO`/`FIXME`/空函数体/空 `catch`（`grep -n "TODO\|FIXME\|UnsupportedException\|catch"` 在 `src/` 零命中）；`getAll()` 是 `getAll('')` 的转发，`getValue`/`getData` 是委托，均非空实现 |
| §4 栈溢出 | 0 | 无递归调用（`Config` 全部线性函数；`SM4Conf` 的 prop 链 `iv → operation → getString` 无自引用、无环），仅有的两处循环是 `bufferSize` 的 `while`（≤ 63 次）与 `static init` 的 `while (i < args.size)`（受 argv 长度约束） |
| §5 OOM | 0 | 唯一全量物化是 `getAll()`，规模 = 进程环境变量数 + 内嵌敏感项数（非不可信输入、无按报文长度预分配）；`getStringArray` 按配置值长度分配（配置可信）；`ARGS`/`sensitiveMap` 只在 `set`/`registerSensitive` 时增长，属显式写入而非请求驱动累积 |
| §6.1 热点瓶颈 | 0 | 本轮无 `cjprof` / `cjpm bench` 数据，`SM4` 构造与 `getStringArray` 双分配已降级为待验证假设 #1/#2，不作缺陷、不进统计 |
| §6.2 大粒度锁 | 0 | 模块内无 `synchronized` / `Mutex` / 锁对象，仅用 `ConcurrentHashMap` |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 线程池 / 队列；`refresher` 回调在调用线程同步执行，不涉及等待 |
| §6.4 低效算法 | 0 | 无嵌套循环（`set` 的 `#REFRESHER × #前缀` 双循环仅在写配置时、规模 ≤ 数十）、热点无 `contains`/`indexOf`、无 `remove(at: 0)`、无循环内正则/拼接；`bufferSize` 的 `while` 是对数级 |
| §7 降堆内存方案 | 1 | `getStringArray`/`getValues` 少一份数组拷贝（标 `无基线（待验证）`） |
| §8 降 CPU 方案 | 1 | 缓存 `SM4` 实例与解密结果（标 `无基线（待验证）`） |
| §9 local mode 可行性 | 0 | 不适用：`docs/LocalMode.md:478` 已定"f_config 启动期加载；不做"，`docs/LocalMode-O2-Plan.md:127` 把 f_config 列入"跨调用持有"；实现上所有返回值（`Map`/`Array`/`String`）都逃逸到调用方，状态存放于全局静态 `ConcurrentHashMap`，函数内无可整块释放的大临时对象，且无改前/改后峰值内存数据 |
| §11 现有代码的 BUG（存量） | 6 | #1（refresher 静默失效）、#2（CTR 必抛）、#7（`getAll` 键冲突/全量 replace）、#8（不可达分支 + 文案误导）、#9（`bufferSize` 溢出）、#11（数组别名）；另核对了 `static init` 的四种写法与空 argv、`getString` 四条查找路径、`getStringArray` 空配置、`parseDateTime` 空格式、`getSM4` 的 `key` 空/长度 0/`iv` 长度分支，除上述外未发现缺陷 |
| §12 并发安全与锁粒度 | 0 | 已列共享点与同步手段：`ARGS`/`REFRESHER`/`sensitiveMap` 三个进程级静态容器均为 `ConcurrentHashMap`（单键读写原子）；`getString` 的 4 次顺序查找非原子，但语义是"最后一次写入生效"，不产生非法状态；`set`/`remove` 在无锁下同步调用回调，回调内不再取锁，无死锁面；`sensitiveMap` 里存的是 `Array<Byte>`，`sensitive2Str` 只读不改，无数据竞争。修复 #1 时需重新评估重入（回调内 `set`），已在建议中提示 |
| §14 功能完备性与 README 覆盖 | 3 | #6（`remove`/`getDylibPattern`/`dylibPattern` 无条目）、#3（`@EmbedSensitive` 标识符承诺未实现）、#12（测试覆盖缺口）；反向核对：README §1–§8 的 API 段、行为表、`bufferSize` 表、SM4 配置表、宏规则 1–5 与源码逐条比对，除 #5（CTR）/#13（示例）外均一致，`${CANGJIE_STDX_DYNAMIC_PATH}` 说法与 `cjpm.toml:31` 相符 |
| 文件覆盖（§13 等） | 6/6 | 6 个文件全部读完；两份 README 逐节对照（中英同步，无单边缺节）；§13 一致性命中并入 #2、#3、#6、#13 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 5 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

## 总评

代码量很小（4 个源文件、约 500 行），但**配置刷新链路是断的**：`refresher` 登记键带尾随下划线、`set`/`remove` 收集的前缀不带，两个写入口都永不触发回调，`f_log`、`f_orm` 登记的刷新函数形同不存在（README §8.1 已把它写成"已知问题"，所以是"被接受的技术债"而非新发现，但仍是本轮唯一的阻塞项——它让"运行期改配置"这条能力静默失效）。

`SM4` 这条链路的正确性次之：`CTR` 模式在 iv 校验里被漏掉，配了就必抛且文案反着说"模式非法"；GCM 下所有内嵌值共用一个 nonce，属密码学误用，建议在文档与实现两处同时收紧。`@EmbedSensitive` 的标识符写法与 README 示例不一致（展开成未定义变量），是"文档承诺两种入参、只实现一种"的典型。

`f_cmd` 的 argv 解析重复是**行为漂移**而非单纯重复：键名是否去横线、重复键覆盖还是追加、位置参数忽略还是抛异常，两侧全不同，同一进程两套结论，建议抽公共 tokenizer 而不是合并语义。

其余为边界与文档：`getAll` 的去前缀实现与键冲突、`SM4Conf` 的两条不可达错误文案、`bufferSize` 缺上界、空 `format` 在两处语义相反、`registerSensitive` 持引用、README 漏掉 `remove`/`getDylibPattern`、测试只覆盖 `set`/`remove`。性能与内存方面没有任何测量数据，`SM4` 构造与数组双分配只是"待验证"，不建议排期。

存量缺陷共 13 条（严重 1 / 一般 5 / 轻微 7），默认只报不修，是否纳入修复待用户决定。
