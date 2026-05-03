# f_protocol 静态诊断报告

> 审查日期：2026-05-03
> 审查范围：fountain::f_protocol 模块所有源文件
> 审查方式：静态代码分析（不编译、不运行）

---

## [P2] Message.decode() 未使用的 closeFromOnEnd 参数

- **问题等级**: P2
- **问题描述**: `Message.cj:117` `decode()` 的命名参数 `closeFromOnEnd!: Bool = false` 声明了但函数体内从未使用。此参数应透传给 `decoder.decode<T>(input)` 或内部流操作，否则调用方传入该参数不会产生任何效果。
  ```cj
  // Message.cj:117 当前声明
  public static func decode<I, T>(input: BufferedInputStream<I>, closeFromOnEnd!: Bool = false): Message
      where I <: InputStream, T <: DataFields<T> {
      ...
      let data = decoder.decode<T>(input)  // 未使用 closeFromOnEnd
      ...
  }
  ```
- **触发条件**: 调用方传入 `closeFromOnEnd: true` 时，期望流在解码完成后被关闭，但实际上不会被关闭。
- **改进方案**: 将 `closeFromOnEnd` 传递给内部流操作，或移除该参数（若不需要）。编译器已报 `unused variable` 警告。
  ```cj
  // 方案A：移除未使用参数（若不在协议中暴露）
  public static func decode<I, T>(input: BufferedInputStream<I>): Message
  // 方案B：透传（若需要关闭流功能）
  public static func decode<I, T>(input: BufferedInputStream<I>, closeFromOnEnd!: Bool = false): Message {
      ...
      if (closeFromOnEnd) { input.close() }
      ...
  }
  ```
- **实施难度**: 低

---

## [P2] MessageID.pidgen 应为 static let 而非 static var

- **问题等级**: P2
- **问题描述**: `MessageID.cj:19` `public static var pidgen: ProcessID = CurrentProcessID.instance` 使用 `var` 声明，但运行期从未修改过。应使用 `let` 声明不可变引用。
  ```cj
  public static var pidgen: ProcessID = CurrentProcessID.instance
  ```
- **触发条件**: 始终存在，编译期即可发现。
- **改进方案**: 改为 `static let`：
  ```cj
  public static let pidgen: ProcessID = CurrentProcessID.instance
  ```
- **实施难度**: 低

---

## [P3] QoS.parse 的 UnreachableException 语义错误

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

## [P3] Message.cj:106 to() 函数缺少显式返回类型

- **问题等级**: P3
- **问题描述**: `Message.cj:106` 私有函数 `to()` 没有声明返回类型。虽然编译器可推断为 `Byte`，但显式声明提高可读性和类型安全。
  ```cj
  private static func to(bool: Bool, byte: Byte){
      if(bool){
          byte
      }else{
          0u8
      }
  }
  ```
- **触发条件**: 始终存在。
- **改进方案**: 添加返回类型：
  ```cj
  private static func to(bool: Bool, byte: Byte): Byte {
      if(bool) { byte } else { 0u8 }
  }
  ```
- **实施难度**: 低

---

## [P3] auth() 工厂的 hasData 标志与实际数据不匹配

- **问题等级**: P3
- **问题描述**: `Message.cj:55` `auth()` 工厂方法接受 `hasData` 和 `ack` flag，但**数据始终被编码在消息体中**。如果调用方传入 `hasData: false`，命令字节的 HASDATA bit 被清除，但数据仍在消息体中。接收端若根据 HASDATA 标志决定是否解析数据，会导致协议解析错误。
  ```cj
  public static func auth<T>(hasData!: Bool, ack!: Bool, authData!: T): EncodedMessage
      where T <: DataFields<T> {
      build<T>(AUTH(to(hasData, HASDATA) | to(ack, ACK)), authData)
      // ^^^ 即使 hasData=false, authData 仍被编码
  }
  ```
- **触发条件**: 调用 `Message.auth(hasData: false, ack: true, authData: someData)` 时。
- **改进方案**: 方案一：移除 `hasData` 参数，始终设置 HASDATA。方案二：当 `hasData=false` 时不传数据，但改变接口语义。建议采用方案一：
  ```cj
  public static func auth<T>(ack!: Bool, authData!: T): EncodedMessage
      where T <: DataFields<T> {
      build<T>(AUTH(HASDATA | to(ack, ACK)), authData)
  }
  ```
- **实施难度**: 中（需确认所有调用方）

---

## [P3] 测试用例 qosParseWithQoS1FlagOnly 的 @Assert(true) 恒真

- **问题等级**: P3
- **问题描述**: `Protocol_test.cj:294` `qosParseWithQoS1FlagOnly` 测试用例使用 `@Assert(true)`，这是一个恒真的死断言，不验证任何实际行为。
  ```cj
  @TestCase
  public func qosParseWithQoS1FlagOnly(): Unit {
      let qos = QoS.parse(4u8)
      @Assert(true) // 不抛异常即为通过 —— 应改为实际断言
  }
  ```
- **触发条件**: 运行此测试时永远通过，即使 QoS.parse(4u8) 行为异常也不报错。
- **改进方案**: 改为验证解析结果的 value：
  ```cj
  @TestCase
  public func qosParseWithQoS1FlagOnly(): Unit {
      let qos = QoS.parse(4u8)
      @Assert(qos.value == 4u8)
  }
  ```
- **实施难度**: 低

---

## [P3] messageIDUniqueness 测试非确定性

- **问题等级**: P3
- **问题描述**: `Protocol_test.cj:117-122` `messageIDUniqueness` 测试假设同一线程先后创建的 `MessageID()` 永远不同。但如果两次调用在同一纳秒完成，时间戳相同、PID相同、线程ID相同，则 `MessageID` 可能相等。虽然 `DateTime.now()` 精度高，但无理论保证。
  ```cj
  @Assert(id1 != id2)
  @Assert(id1.hashCode() != id2.hashCode())
  ```
- **触发条件**: 极端条件（极短间隔内创建两个 MessageID）。
- **改进方案**: 在 MessageID 内部增加序列号（AtomicInt64）以确保唯一性，或修改测试为确定性比较（如提供显式参数）。
- **实施难度**: 中

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

| 等级 | 数量 | 建议处理 |
|------|------|----------|
| P0   | 0    | - |
| P1   | 0    | - |
| P2   | 2    | 建议优先修复 |
| P3   | 5    | 建议迭代修复 |
| P4   | 1    | 可忽略 |
