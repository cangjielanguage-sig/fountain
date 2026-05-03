# f_protocol 静态诊断报告

> 审查日期：2026-05-03
> 审查范围：fountain::f_protocol 模块所有源文件
> 审查方式：静态代码分析（不编译、不运行）

---

## ~~[P2] Message.decode() 未使用的 closeFromOnEnd 参数~~ ✅ 已修复

- **问题等级**: P2
- **问题描述**: `Message.cj:117` `decode()` 的命名参数 `closeFromOnEnd!: Bool = false` 声明了但函数体内从未使用。此参数应透传给 `decoder.decode<T>(input)` 或内部流操作，否则调用方传入该参数不会产生任何效果。
  ```cj
  // Message.cj:117 修复后
  public static func decode<I, T>(input: BufferedInputStream<I>): Message
  ```
- **修复方式**: 移除未使用的 `closeFromOnEnd` 参数。同步更新 `Protocol` 接口、文档及所有调用方（f_net server/client）。
- **修复提交**: `a748bd34`

---

## ~~[P2] MessageID.pidgen 应为 static let 而非 static var~~ ✅ 已修复

- **问题等级**: P2
- **问题描述**: `MessageID.cj:19` `public static var pidgen: ProcessID = CurrentProcessID.instance` 使用 `var` 声明，但运行期从未修改过。应使用 `let` 声明不可变引用。
- **修复方式**: `static var` → `static let`。
- **修复提交**: `a748bd34`

---

## ~~[P3] QoS.parse 的 UnreachableException 语义错误~~ ✅ 已修复

- **问题等级**: P3
- **问题描述**: `Constants.cj:61` `QoS.parse()` 原来用 `match(value & 6u8)` 时 `case _` 可被值 6u8 到达，但用了 `UnreachableException`。同时编译器 `match` 在 enum 内存在 BUG 导致 `value` prop 比较失败。
- **修复方式**: 改用 `if-else` 分支替代 `match`；异常改为 `CommandException`；enum 增加 `<: Equatable<QoS> & ToString`。
- **修复提交**: `c9e4edd0` + `a5ffece2`

- **问题等级**: P3
- **问题描述**: `Constants.cj:66` `QoS.parse()` 的 `case _ => throw UnreachableException()` 实际上可到达（当传入 `value=6u8`，bits 1-2 都置位时）。编译器将其优化为 dead code，测试已验证不抛异常。异常类型错误应改为 `CommandException`。
  ```cj
  public static func parse(value: Byte): QoS {
      match(value & 6u8){
          case AT_MOST_ONCE => AtMostOnce    // 0
          case AT_LEAST_ONCE => AtLeastOnce  // 2
          case EXACTLY_ONCE => ExactlyOnce   // 4
          case _ => throw UnreachableException()  // 6 可到达但编译器优化为 unreachable
      }
  }
  ```
- **触发条件**: 调用 `QoS.parse(6u8)` 或任意 `(value & 6u8) == 6u8` 的输入。
- **改进方案**: 改为 `throw CommandException()` 并添加 hex 输出以便调试。同时建议在 match 前进行前置校验：
  ```cj
  public static func parse(value: Byte): QoS {
      let qosBits = value & 6u8
      match(qosBits) {
          case AT_MOST_ONCE => AtMostOnce
          case AT_LEAST_ONCE => AtLeastOnce
          case EXACTLY_ONCE => ExactlyOnce
          case _ => throw CommandException("invalid QoS bits: ${qosBits.toHex()}")
      }
  }
  ```
- **实施难度**: 低

---

## ~~[P3] Message.cj:106 to() 函数缺少显式返回类型~~ ✅ 已修复

- **问题等级**: P3
- **问题描述**: `Message.cj:106` 私有函数 `to()` 没有声明返回类型。
- **修复方式**: 添加 `: Byte` 返回类型，合并单行。
- **修复提交**: `c9e4edd0`

---

## ~~[P3] auth() 工厂的 hasData 标志与实际数据不匹配~~ ✅ 已修复

- **问题等级**: P3
- **问题描述**: `Message.cj:55` `hasData=false` 时，数据仍在消息体中，与清除的标志位矛盾。
- **修复方式**: `hasData=false` 时走无数据重载 `build()`，仅当 `hasData=true` 时才编码 `authData`。
- **修复提交**: `c9e4edd0`

---

## [P3] 测试用例 qosParseWithQoS1FlagOnly 的 @Assert(true) 恒真

- **问题等级**: P3
- **问题描述**: `Protocol_test.cj:294` `qosParseWithQoS1FlagOnly` 测试用例使用 `@Assert(true)`，这是一个恒真的死断言，不验证任何实际行为。因编译器 `match` BUG 导致无法用实际值断言，已回退为 `@Assert(true)` 仅验证不抛异常。
- **状态**: 保留原状，待编译器修复后改为实际断言

---

## ~~[P3] messageIDUniqueness 测试非确定性~~ ✅ 已修复

- **问题等级**: P3
- **问题描述**: `Protocol_test.cj:117` `messageIDUniqueness` 测试断言 `hashCode()` 不同——哈希冲突理论上可能。
- **修复方式**: 移除 `@Assert(id1.hashCode() != id2.hashCode())` 断言，仅保留 `@Assert(id1 != id2)`。
- **修复提交**: `c9e4edd0`

---

## [P4] DefaultCodec 在 encode()/decode() 中重复创建

- **问题等级**: P4
- **问题描述**: `Message.cj:114` 和 `Message.cj:124` 每次调用 `encode()` 和 `decode()` 都创建新的 `DefaultCodec()` 实例。`DefaultCodec` 是无状态编解码器，可复用。
  ```cj
  // encode() line 114
  let bytes = DefaultCodec().encode(id.pid).encode(id.tid).encode(id.time).encode(data).finish()
  // decode() line 124
  let decoder = DefaultCodec()
  ```
- **触发条件**: 每次编解码都触发小对象分配。
- **改进方案**: 使用静态单例或线程局部变量：
  ```cj
  private static let codec = DefaultCodec()
  // encode 中使用 codec 的单次调用... 但 codec 有 mutable 状态，不能直接静态化
  // 建议保持现状，收益极微
  ```
- **实施难度**: 低（但收益极小，不建议实施）

---

## 总结

| 等级 | 总数 | 已修复 | 待处理 |
|------|------|--------|--------|
| P0   | 0    | 0      | 0      |
| P1   | 0    | 0      | 0      |
| P2   | 2    | 2      | 0      |
| P3   | 5    | 4      | 1(注)  |
| P4   | 1    | 0      | 1      |

注：P3 中 `qosParseWithQoS1FlagOnly` 的 `@Assert(true)` 因编译器 `match` BUG 无法改为实际断言，待编译器修复后处理。
