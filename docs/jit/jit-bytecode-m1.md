# Fountain JIT · M1 字节码规格

> 版本 v0.4（评审稿） · 2026-09-16（v0.3：一致性修订 + 冻结决策 ③；v0.4：区间 / Decimal 算术 / 数值互转 / Duration·DateTime 算术 / 插值串 / 类型化局部变量（明确赋值 + 空安全）/ 句柄 Marshal 与逃逸（§8.1）/ 统一函数包装 call\<T\>（§8.2），激活窗口分配机制）
> 适用范围：M1 —— 纯计算 + 白名单不可变值分配（§9.12–13）+ 类型化局部变量（§11.7）、不使用宏、无 JIT 级 try-catch
> 平台范围：**字节码跨平台**（Windows / Linux / HarmonyOS / macOS）；**JIT 仅 Linux**，后端 **x86_64** 与 **aarch64**
> **冻结决策**：① 32 位宿主不支持（§9 附则 9） ② JIT 仅 Linux x86_64 / aarch64，字节码不得含"仅 JIT 可实现"指令（§9 附则 10） ③ 编译粒度为整单元（§9 附则 11）
> 目录：§0 总览 · §1 ctx · §2 错误码 · §3 帧布局 · §4 入口 ABI · §5 ISA · §6 helper · §7 伪指令 · §8 桥入口 · §9 附则 · §10 opcode 常量表 · §11 跨平台字节码 · §12 JIT 后端（x86_64 / AArch64） · §13 平台矩阵与差分测试

---

## §0 总览与不变式

**执行模型**：栈式虚拟机字节码是**跨平台唯一产物**，由解释器在所有平台执行；在 Linux x86_64 / aarch64 上另有 JIT 后端把它展开为机器码。机器码**本身不分配**、**不抛异常**、**不做栈展开**，且**永不落盘、永不跨机共享**。

**值分配（I8）**：白名单 helper 可在宿主侧分配**不可变值**（String/Decimal/DateTime/Duration/Range 的运算与转换结果、插值串）；机器码与解释器核心本身仍不分配。deopt 重放会重新分配**等值**对象——值不可变 ⇒ 可观察语义不变。

**八条硬不变式**（违反即编译期报错或加载期拒绝）：

| # | 不变式 |
|---|---|
| I1 | 一切 cell 是 64 位；`Int64` 原值、`Float64` 位模式、句柄是整数 ID（0 = null） |
| I2 | 机器码永不解释句柄内容、永不解引用对象指针 |
| I3 | 每个可失败点后必跟 `CHECK_ERR`；由汇编器自动插入 |
| I4 | 错误只经 ctx 错误槽传递；helper 绝不抛异常（内部 try-catch 转码） |
| I5 | 调用失败时 `rax` 内容未被定义；桥必须读错误槽后再决定是否使用返回值 |
| I6 | 字节码与平台、端序、字长、编译器 ABI 无关；机器码只存在于内存，不作为分发物 |
| I7 | 解释器语义是规范，JIT 是等价加速器：同一字节码 + 同一输入，解释器与两个 JIT 后端的结果、错误码、site 必须**逐位一致** |
| I8 | 分配只经由白名单 helper 产出**不可变值**；机器码与解释器核心永不分配；重放重复分配不改变可观察语义 |

**由此得到的三个简化**：

1. 分配仅产不可变值 ⇒ 已登记句柄槽**只读**，机器码永不持裸指针、无需写屏障。
2. 计算无副作用、分配结果不可变 ⇒ 可**自由 deopt / 重放**：失败就退回解释器重跑（重复分配等值对象），语义安全。
3. 无宏 ⇒ helper 分派用 `match`/token 表手写即可，类型集封闭（List/Map/String/Decimal/DateTime/Duration/Range）。

---

## §1 ctx 布局（64 B，16 B 对齐，桥分配）

```
off  size 字段      含义
0    8    errCode   0=OK  -1=DEOPT  -2=INTERRUPT  >0=错误码
8    8    site      当前字节码偏移；未设置=-1
16   8    hwBase    句柄窗口起点（本次调用）
24   8    hwCap     窗口容量（编译期确定）
32   8    hwTop     窗口已用数（helper 写）
40   8    fnId      函数 id（桥填，供错误上下文）
48   8    flags     bit0=strictFp  bit1=trace  bit2=hasLoop  ...
56   8    reserved  预留/对齐
```

**句柄槽（8 B，仅 helper 可解释，两种形态二选一）**：`objref`（8 B 原生指针，仅宿主 GC 解释）或 `idx:u32 + tag:u16 + gen:u16`（ID 形态，`tag` 用 §6 类型 token 编码）。机器码只见整数 ID，槽内由宿主 GC 作为强引用保持存活。

**句柄窗口语义**：`[hwBase, hwTop)` 本次调用可见。M1 中窗口**只增不减**；仅白名单**分配型 helper**（§6 H24–H41）可登记新槽，且每次调用至多登记 1 个——其运算结果（不可变值）。`hwTop == hwCap` 时宿主就地扩容句柄表（§9.6），不因容量失败；无分配单元 `hwCap=0`。

---

## §2 错误码表

```
 0   OK
-1   DEOPT        非异常：类型不符/资源不足 → 桥退回解释器重跑
-2   INTERRUPT    取消/超时 → 桥抛 InterruptedException

 1   ERR_DIV_ZERO
 2   ERR_MOD_ZERO
 3   ERR_OVERFLOW_I64        (含 INT_MIN/-1, INT_MIN 取负)
 4   ERR_IDX_OOB
 5   ERR_KEY_MISSING
 6   ERR_NULL_HANDLE         (对 null 句柄取用)
 7   ERR_BAD_CAST
 8   ERR_HANDLE_TYPE         (句柄类型不符：helper fetch 与 GUARD_TYPE 共用；7 仅用于 CAST 值转型)
 9   ERR_DEC_RANGE           (decimal128 溢出；DEC_TO_I64 越界)
10   ERR_DEC_DIV_ZERO        (Decimal ÷0，含 0÷0)
11   ERR_DT_RANGE            (DT±DUR 结果超出 DateTime 值域)
12   ERR_DUR_OVERFLOW        (Duration 算术溢出)
13   ERR_FP_INVALID          (NaN/Inf 转整型；F64→Decimal)
14   ERR_ARG_MISMATCH        (CALL_FUNC argc 不符；RANGE_NEW step=0；桥入口断言)
15   ERR_STACK_GUARD         (DEOPT 后解释器余量亦不足、无法重跑时由桥写入)
16   ERR_HANDLE_WINDOW_FULL  (宿主句柄表全局上限——资源耗尽)
17   ERR_EXPLICIT            (源语言 throw；具体码放 site 附加表)
18   ERR_NOT_IMPL            (汇编器遇到未实现特性时主动 bail)
19   ERR_CALL_CONTRACT       (call 的调用契约错误：参数长度/元素类型/返回 T 不符；桥层产生，site=-1，不经字节码执行)
99   ERR_HELPER_PANIC        (helper 内未识别异常兜底；任何内部异常最终都以此码浮现)
```

**错误码 → 桥侧异常类型映射**（`code → Exception`，桥静态表，无宏）：

| 范围 | 抛出类型 |
|---|---|
| 1–19 | `JitException(code, site, fnId, msg)` |
| 99 | `JitException`，msg 前缀 `internal helper failure`，并附 `cause` 原始描述字符串 |
| 0 / -1 / -2 | 不抛：OK 走值路径，DEOPT 走解释器，INTERRUPT 抛 `InterruptedException` |

---

## §3 帧布局

### §3.1 机器帧（固定大小，编译期算出）

```
frameSize = 32 + 8*nLocals + 8*maxStack + 8   // 再向上取整到 16 的倍数

高地址
┌─────────────────────────────┐
│ 调用方帧                     │
├─────────────────────────────┤
│ return address              │  rbp+8
│ saved rbp                   │  rbp+0   ← rbp
│ saved r15（调用方值）        │  rbp-8   ctx 存于 r15 寄存器
│ hwBase 镜像 (i64)           │  rbp-16  调试/安全点用
│ reserved (i64)              │  rbp-24
├─────────────────────────────┤
│ locals[0]  = arg0           │  rbp-32
│ locals[1]  = arg1           │  rbp-40
│ ...                         │
│ locals[nLocals-1]           │  rbp-32-8*(nLocals-1)
├─────────────────────────────┤
│ operand stack 顶 (sp)        │  ← rsp；push 后 [rsp] 即栈顶
│ operand stack ...           │
│ operand stack 底            │  rbp-32-8*nLocals-8*maxStack
└─────────────────────────────┘
低地址
```

- **参数即局部变量**：`locals[0..nargs-1]`，由 prologue 从 `args` 数组拷入；`nargs` 在编译期已知并写入 `LOADL` 范围校验。
- **寄存器名说明**：本节用 x86_64 记法（`rbp`/`rsp`/`r15`）。AArch64 对应 `x29`/`sp`/`x19`，且返回地址在 `x30` 需由 prologue 保存——完整映射见 §12.2、§12.3。帧布局本身**两后端共享**（`frameSize` 统一按 16 字节对齐）。
- **操作数栈向下增长**：`PUSH` = `sub rsp,8; mov [rsp],v`；`POP` = `mov v,[rsp]; add rsp,8`。
- **r15 全程持 ctx**（callee-saved，跨 helper 调用不失效）。**禁止把 ctx 放 rdx/rcx**（caller-saved）。
- 帧内 `hwBase` 镜像仅用于安全点比对，非必需。
- **内存卫生填充（不可观察）**：prologue 将全部非参数局部槽写 0（确定性初始化，不依赖宿主内存残留）。**该零值不是默认值、不可观察**：局部变量实行**明确赋值**（§7 校验 10）——非参数局部在其被读取的所有可达路径上必须已被显式写入，读未赋值局部 = 编译期拒绝；因此填充值永不出现在可观察语义中（差分一致性的保险，而非语义）。
- **空安全（局部）**：句柄型局部（LocalType 4–8）**恒为有效句柄（≠0），没有空值**；`PUSH_NULL` 不得作为句柄型局部的赋值源（§7 校验 10）。null 只存在于互操作边界（桥参数为 0 → helper 边界报 6）与栈上瞬态值，不进入局部变量。

### §3.2 cell 类型约定（栈/局部槽内都是 64 位）

| 逻辑类型 | 表示 | 说明 |
|---|---|---|
| `Int64` | 原值 | 补码整数 |
| `Float64` | IEEE754 位模式 | 浮点指令以 `movq` 读写，不经 FPU 转换栈 |
| `Bool` | 0/1 | |
| 引用类型（List/Map/String/Decimal/DateTime/Duration/Range） | 句柄 ID（正整数） | 0 = null；String/Decimal/DateTime/Duration/Range 为**不可变值**（分配型 helper 可产出），List/Map 可变（M1 只读） |
| `Unit` | 0 | 无返回值占位 |

**局部变量的静态类型**：每个局部槽的类型由 §11.7 局部类型表声明（v0.4 起），可声明的类型集为 `Int64 / Float64 / Bool / Unit / String / Decimal / DateTime / Duration / Range`；cell 表示不变（64 位），类型表是规范性元数据（详见 §11.7）。局部变量**空安全且无默认值**：必须显式赋值后才能读取（§7 校验 10），句柄型局部恒非空——与仓颉"非 Option 类型无 null"的语义一致。

### §3.3 常量表（拼装期构造，只读共享）

```
ConstTable
  [0..k-1]  句柄常量: (kind, 宿主对象)   ← PUSH_KH n 使用
  [k..]     元信息: 源位置、站点描述、函数名
```

字面量 `[1,2,3]` / `{k:v}` / `"abc"` / `Decimal(...)` / 区间 `a..b` / `a..=b`（可带 `: step`，§11.9）**全部在拼装期由宿主构造一次**，登记入常量表并由 ctx 外部持有强引用。语义：**字面值共享只读**；如需"每次求值新对象"，由桥在调用前显式深拷贝（`CallContext.literalCopy`，M2）。

---

## §4 入口 ABI（桥 → 机器码）

```
rdi = ctx 指针（桥分配，栈上或堆上均可，调用期间不得移动）
rsi = &args[0]（Int64 数组；nargs=0 时可为 null）
rdx = nargs（编译期已固定，运行时仅作断言）
ret: rax = cell（返回值或句柄）；errCode != 0 时 rax 未定义
```

**Prologue**（汇编器固定发射）：

```asm
    push  rbp
    mov   rbp, rsp
    mov   [rbp-8], r15               ; 保存调用方 r15（callee-saved）
    mov   r15, rdi                   ; ctx
    sub   rsp, frameSize
    mov   rax, [r15+16]
    mov   [rbp-16], rax              ; hwBase 镜像（x86 无 mem→mem，须经寄存器）
    mov   qword [r15+40], <fnId>     ; 错误归因（CALL_FUNC 链中最内层函数）
    ; nargs>0: for i in 0..nargs-1:  mov rax,[rsi+8i]; mov [rbp-32-8i],rax
    ; 编译期已知 nargs，直接按需发射，无循环
    ; 内存卫生填充：for i in nargs..nLocals-1:  mov qword [rbp-32-8i], 0
    ;   （不可观察：明确赋值分析保证先写后读，见 §7 校验 10 / §11.7）
.epilogue:
    mov   r15, [rbp-8]               ; 恢复调用方 r15
    mov   rsp, rbp
    pop   rbp
    ret
```

**Epilogue 是唯一返回路径**：所有 `RET/RET_VOID`、所有 `BAIL` 都以 `jmp .epilogue` 结束（`BAIL` 前置 `mov eax,0`）。

**桥的调用义务**：入口前 `errCode=0; site=-1; hwTop=hwBase`；返回后**先读 errCode**，非 0 时不得使用 rax。

**内部调用 `CALL_FUNC`**：复用同一 ctx 与句柄窗口（不新开窗口），参数从操作数栈按顺序拷入新帧 locals，仍遵循本节帧约定，只是不经桥。汇编期校验 `fid` 存在且 `argc` 与被调函数一致（不符 → 编译错误 / 运行期 `ERR_ARG_MISMATCH`）。被调函数 prologue 把自己的 `fnId` 写入 ctx；**返回后调用方立即重写自身 `fnId`**（一条 mov），保证后续错误归因正确。

---

## §5 M1 ISA 指令表（opcode 编号）

编码：`[op:u8][operands...]`，小端；`rel` 为相对**下一条指令**的有符号 32 位偏移。栈作用列 `... a b → c` 表示先弹 b 再弹 a。

### 0x00–0x0F 控制 / 杂项

| Hex | 名称 | 操作数 | 语义 | 失败码 |
|---|---|---|---|---|
| 00 | `NOP` | — | 无操作 | — |
| 01 | `TRAP` | u8 | 调试陷阱 | — |
| 02 | `BREAKPOINT` | — | 保留，发布版空操作 | — |
| 03 | `SET_SITE` | i32 | 写 `ctx.site`；伪指令展开目标 | — |
| 04 | `CHECK_ERR` | rel32 | `errCode != 0` → 跳 bail | — |
| 05 | `BAIL` | i8 k | 写错误槽=k，`eax=0`，跳 epilogue | — |
| 06 | `CHECK_ERR_NC` | — | 仅断言（发布版空操作），调试期校验 | — |
| 07 | `STACK_GUARD` | u16 need | 剩余栈 < need → `BAIL -1`（DEOPT） | DEOPT |
| 08–0F | 保留 | | | |

### 0x10–0x1F 常量 / 栈

| Hex | 名称 | 操作数 | 语义 | 失败码 |
|---|---|---|---|---|
| 10 | `PUSH_I8` | i8 | `→ sext(v)` | — |
| 11 | `PUSH_I32` | i32 | `→ sext(v)` | — |
| 12 | `PUSH_I64` | i64 | `→ v` | — |
| 13 | `PUSH_F64` | i64(bits) | `→ v`（位模式原样） | — |
| 14 | `PUSH_BOOL` | u8 | `→ 0/1` | — |
| 15 | `PUSH_NULL` | — | `→ 0`（不得直存句柄型局部，§7 校验 10） | — |
| 16 | `PUSH_KH` | u16 idx | 压常量句柄 | — |
| 17 | `DUP` | — | `a → a a` | — |
| 18 | `DUP2` | — | `a b → a b a b` | — |
| 19 | `POP` | — | `a →` | — |
| 1A | `POP2` | — | `a b →` | — |
| 1B | `SWAP` | — | `a b → b a` | — |
| 1C | `PICK` | u8 n | `… v → … v v`（n=0 等价 DUP） | — |
| 1D–1F | 保留 | | | |

### 0x20–0x2F 局部变量

| Hex | 名称 | 操作数 | 语义 | 失败码 |
|---|---|---|---|---|
| 20 | `LOADL` | u16 i | `→ locals[i]` | 越界=编译错误 |
| 21 | `STOREL` | u16 i | `v → locals[i]=v` | 越界=编译错误 |
| 22 | `LOADL0` | — | `→ locals[0]`（压缩形式，可选） | — |
| 23 | `LOADL1` | — | `→ locals[1]` | — |
| 24 | `LOADL2` | — | `→ locals[2]` | — |
| 25 | `LOADL3` | — | `→ locals[3]` | — |
| 26–2F | 保留 | | | |

### 0x30–0x3F 整型算术（IADD–IMOD 检查溢出 / 除零；IADD_WRAP 显式无检查）

| Hex | 名称 | 语义（`a b → r`） | 失败码 |
|---|---|---|---|
| 30 | `IADD` | a+b | 3 |
| 31 | `ISUB` | a-b | 3 |
| 32 | `IMUL` | a*b | 3 |
| 33 | `IDIV` | a/b（向零截断） | 1, 3（INT_MIN/-1） |
| 34 | `IMOD` | a%b | 2, 3 |
| 35 | `INEG` | -a | 3 |
| 36 | `IABS` | \|a\| | 3 |
| 37 | `IMIN` | min(a,b) | — |
| 38 | `IMAX` | max(a,b) | — |
| 39 | `IADD_WRAP` | a+b 无检查（显式选择） | — |
| 3A | `ICLZ` | 前导零计数 | — |
| 3B | `IPOPCNT` | 位中 1 的个数 | — |
| 3C–3F | 保留 | | |

### 0x40–0x4F 浮点运算

| Hex | 名称 | 语义（`a b → r`） | 失败码 |
|---|---|---|---|
| 40 | `FADD` | a+b（IEEE） | — |
| 41 | `FSUB` | a-b | — |
| 42 | `FMUL` | a*b | — |
| 43 | `FDIV` | a/b，IEEE（得 ±Inf/NaN，**不报错**） | — |
| 44 | `FDIV_CHK` | a/b，÷0 报错（strictFp） | 1 |
| 45 | `FNEG` | -a | — |
| 46 | `FABS` | \|a\| | — |
| 47 | `FMIN` | min（任一操作数为 NaN → canonical NaN，§11.3） | — |
| 48 | `FMAX` | max（同上） | — |
| 49 | `FSQRT` | √a（负数 → NaN） | — |
| 4A | `FFLOOR` | 向下取整（保留 NaN/±Inf） | — |
| 4B | `FCEIL` | 向上取整 | — |
| 4C | `FTRUNC` | 向零取整 | — |
| 4D | `FROUND` | 四舍六入五成双 | — |
| 4E–4F | 保留 | | |

### 0x50–0x6F 比较 / 逻辑 / 位运算

| Hex | 名称 | 语义（`a b → r`） | 备注 |
|---|---|---|---|
| 50 | `CMP_I` | -1/0/1 | 整型三路比较 |
| 51 | `CMP_F` | -1/0/1 | **NaN → 结果未定义**，汇编器禁止对其发射 |
| 52 | `EQ_I` | 0/1 | |
| 53 | `NE_I` | 0/1 | |
| 54 | `LT_I` | 0/1 | |
| 55 | `LE_I` | 0/1 | |
| 56 | `GT_I` | 0/1 | |
| 57 | `GE_I` | 0/1 | |
| 58 | `EQ_F` | 0/1 | NaN 比较恒 false |
| 59 | `NE_F` | 0/1 | NaN ≠ 任意 → true |
| 5A | `LT_F` | 0/1 | |
| 5B | `LE_F` | 0/1 | |
| 5C | `GT_F` | 0/1 | |
| 5D | `GE_F` | 0/1 | |
| 5E | `NOT_B` | `a → !a` | |
| 5F | `AND_B` | a&&b（0/1） | 无短路；短路用跳转 |
| 60 | `OR_B` | a\|\|b | |
| 61 | `XOR_B` | a^b（bool） | |
| 62 | `BAND_I` | a&b | |
| 63 | `BOR_I` | a\|b | |
| 64 | `BXOR_I` | a^b | |
| 65 | `BNOT_I` | ~a | |
| 66 | `SHL_I` | a<<b（b 取低 6 位） | 与硬件一致 |
| 67 | `SHR_I` | a>>b 算术 | |
| 68 | `USHR_I` | a>>>b 逻辑 | |
| 69 | `EQ_H` | 句柄同一性（== null 亦用此） | 不解引用 |
| 6A | `NE_H` | 句柄不同一 | |
| 6B | `CMP_STR` | 字符串序（helper H09） | 6 |
| 6C | `CMP_DEC` | Decimal 序（helper H11） | 6, 8 |
| 6D | `CMP_DT` | DateTime 序（helper H13） | 6, 11 |
| 6E | `CMP_DUR` | Duration 序（helper H15） | 6, 12 |
| 6F | 保留 | | |

### 0x70–0x7F 控制流与调用

| Hex | 名称 | 操作数 | 语义 | 失败码 |
|---|---|---|---|---|
| 70 | `JMP` | rel32 | 无条件跳 | — |
| 71 | `JZ` | rel32 | `c==0` 跳（弹 c） | — |
| 72 | `JNZ` | rel32 | `c!=0` 跳 | — |
| 73 | `SWITCH` | u16 n, i32[n] T, i32 D | v=弹栈；0 ≤ v < n → 跳 T[v]，否则跳 D（case 值恒为紧凑的 0..n-1，编码中无值表；稀疏 switch 由前端降级为比较链） | — |
| 74 | `LOOP_BACK` | rel32 | 回边：`STACK_GUARD` + 安全点 → 跳 | DEOPT / -2 |
| 75 | `CALL_HELPER` | u16 hid, u8 argc | 调 helper，压结果；**汇编器自动尾随 CHECK_ERR** | helper 码 |
| 76 | `CALL_HELPER_NC` | u16 hid, u8 argc | 同上但不做错误检查（仅永不失败的纯函数允许） | — |
| 77 | `CALL_HELPER_V` | u16 hid, u8 argc | 返回 Unit，不压栈 | helper 码 |
| 78 | `CALL_FUNC` | u16 fid, u8 argc | 内部 JIT 函数调用（共窗口） | 传播 + 14 |
| 79 | `CALL_HOST` | u16 fid, u8 argc | 经薄 @C 包装调宿主回调（**M1 汇编期报 `ERR_NOT_IMPL`**，M2 启用） | 传播 |
| 7A | `HW_OPEN` | u16 cap | 打开分配区块（M1 汇编期报 `ERR_NOT_IMPL`） | 16 |
| 7B | `HW_CLOSE` | — | 关闭区块 | — |
| 7C | `RET` | — | `t=[rsp]`；`rax=t`；跳 epilogue | — |
| 7D | `RET_VOID` | — | `rax=0`；跳 epilogue | — |
| 7E | `RET_NULL` | — | `rax=0`（引用返回位） | — |
| 7F | 保留 | | | |

### 0x80–0x8F 类型 / 转换 / 显式错误

| Hex | 名称 | 操作数 | 语义 | 失败码 |
|---|---|---|---|---|
| 80 | `CAST` | u16 tok, u8 mode | 值/句柄转型；mode 0=报错 1=deopt | 7 / DEOPT |
| 81 | `TO_I64` | u8 mode | F64→I64（NaN/越界按 mode） | 13 / DEOPT |
| 82 | `TO_F64` | — | I64→F64（可能丢精度，不报错） | — |
| 83 | `IS_TYPE` | u16 tok | 句柄类型判定 `→ 0/1`（null→false） | — |
| 84 | `GUARD_TYPE` | u16 tok, u8 mode | 类型不符按 mode 处理 | 8 / DEOPT |
| 85 | `THROW` | u8 code | 写错误槽=17，site 附加表记源语言码 | — |
| 86 | `ASSERT` | u8 code | 弹 bool，false → BAIL(code) | code |
| 87 | `ABORT` | u8 code | 无条件 BAIL(code) | code |
| 88 | `GUARD_NNZ` | u8 mode | 栈顶句柄为 0 时按 mode 处理 | 6 / DEOPT |
| 89 | `TYPE_OF` | — | 句柄 → 类型 token（调试用） | 6 |
| 8A–8F | 保留 | | | |

### 0x90–0x9F 容器 / 值提取 / 数值转换（走 helper）

| Hex | 名称 | 操作数 | 语义 | 失败码 |
|---|---|---|---|---|
| 90 | `LEN` | — | 句柄 → 元素数（List/Map/String 通用） | 6, 8 |
| 91 | `GET_IDX` | — | `h i → 元素` | 4, 6 |
| 92 | `GET_KEY` | — | `h k → 值`（缺键报错） | 5, 6 |
| 93 | `GET_KEY_OR` | — | `h k d → 值`（缺键取 d） | 6 |
| 94 | `HAS_KEY` | — | `h k → 0/1` | 6 |
| 95 | `STR_AT` | — | `h i → Rune(Int64)` | 4, 6 |
| 96 | `DT_FIELD` | u8 f | `h → 字段值`（f 见 §6 H14） | 6, 11 |
| 97 | `DUR_TICKS` | — | `h → 纳秒 Int64` | 6, 12 |
| 98 | `DEC_IS_INT` | — | `h → 0/1` | 6, 8 |
| 99 | `HANDLE_TAG` | — | 调试：取 tag | 6 |
| 9A | `RANGE_NEW` | — | `start end step isClosed → h`（H41；isClosed 对应仓颉 `..` / `..=`；step=0 或 isClosed∉{0,1} → 14；空区间规则见 §11.9） | 14, 16 |
| 9B | `RANGE_CONTAINS` | — | `h v → 0/1`（H42；语义见 §11.9） | 6, 8 |
| 9C | `TO_DEC` | u8 src | src=0：Int64→Decimal（精确，scale 0，H28）；src=1：Float64→Decimal（最短往返，H29） | 13, 16 |
| 9D | `DEC_TO_I64` | u8 mode | mode=0：向零截断、越界 → 9（H30）；mode=1：越界 → DEOPT | 9 / DEOPT |
| 9E | `DEC_TO_F64` | — | IEEE 最近偶数，溢出 → ±Inf 不报错（H31） | 6, 8 |
| 9F | 保留 | | | |

### 0xA0–0xAF 分配区（v0.4 起部分启用；语义 = "会分配"）

| Hex | 名称 | 操作数 | 语义 | 失败码 |
|---|---|---|---|---|
| A0 | `MAKE_LIST` | — | **禁用**（M2） | — |
| A1 | `LIST_APPEND` | — | 禁用（M2） | — |
| A2 | `MAKE_MAP` | — | 禁用（M2） | — |
| A3 | `MAP_PUT` | — | 禁用（M2） | — |
| A4 | `STR_CAT` | — | `h1 h2 → h` 字符串拼接（H32；插值串原语，不可变结果） | 6, 16 |
| A5 | `DEC_ADD` | — | `h1 h2 → h`（H24；decimal128 语义，§9.12/§11.9） | 9, 16 |
| A6 | `DEC_SUB` | — | `h1 h2 → h`（H25） | 9, 16 |
| A7 | `DEC_MUL` | — | `h1 h2 → h`（H26） | 9, 16 |
| A8 | `DEC_DIV` | — | `h1 h2 → h`（H27；÷0 → 10） | 9, 10, 16 |
| A9 | `DT_NEW` | — | 禁用（M2；M1 的 DateTime 来自常量/桥/DT±DUR） | — |
| AA | `DUR_NEW` | — | 禁用（M2） | — |
| AB–AF | 保留 | — | 禁用 | — |

### 0xB0–0xBF 时间运算 / 文本化（v0.4 新增，走 helper）

| Hex | 名称 | 操作数 | 语义 | 失败码 |
|---|---|---|---|---|
| B0 | `DT_ADD` | — | `dt dur → dt`（H34） | 11, 16 |
| B1 | `DT_SUB` | — | `dt dur → dt`（H35） | 11, 16 |
| B2 | `DUR_ADD` | — | `d1 d2 → d`（H36） | 12, 16 |
| B3 | `DUR_SUB` | — | `d1 d2 → d`（H37） | 12, 16 |
| B4 | `DUR_MUL` | — | `d i64 → d`（H38；Int64×Duration 由前端换序） | 12, 16 |
| B5 | `DUR_DIV` | — | `d i64 → d`（H39；i64=0 → 1） | 1, 12, 16 |
| B6 | `DUR_NEG` | — | `d → d`（H40） | 12, 16 |
| B7 | `TO_STR` | u8 t | 值 → 字符串（H33；t=静态类型标签，格式冻结于 §11.9） | 6, 8, 16 |
| B8–BF | 保留（M1） | — | 禁用 | — |

**0xC0–0xFF 预留 M2**，M1 发射即报错；预留给：`HW_OPEN` 区块内的批量分配、`CALL_HOST`、容器构造。

---

## §6 M1 @C helper 清单

**helper ABI**：`rdi=ctx`，`rsi=&args[0]`，`rdx=nargs`，`ret rax=cell`。args 从**操作数栈顶向下**排列（`args[0]` 是最深的那个）；nargs 由指令 `argc` 决定。**helper 内部必须把所有异常转成错误码，绝不抛出**。

| hid | 名称 | 输入 | 输出 | 失败码 |
|---|---|---|---|---|
| H01 | `hl_len` | h | i64 | 6 |
| H02 | `hl_get` | h, i | cell | 4, 6 |
| H03 | `hm_len` | h | i64 | 6 |
| H04 | `hm_get` | h, kh | cell | 5, 6 |
| H05 | `hm_get_or` | h, kh, d | cell | 6 |
| H06 | `hm_has` | h, kh | 0/1 | 6 |
| H07 | `hs_len` | h | i64 | 6 |
| H08 | `hs_at` | h, i | Rune | 4, 6 |
| H09 | `hs_cmp` | h1, h2 | -1/0/1 | 6 |
| H10 | `h_ref_eq` | h1, h2 | 0/1 | — |
| H11 | `hd_cmp` | h1, h2 | -1/0/1 | 6, 8 |
| H12 | `hd_is_int` | h | 0/1 | 6, 8 |
| H13 | `ht_cmp` | h1, h2 | -1/0/1 | 6, 11 |
| H14 | `ht_field` | h, f | i64 | 6, 11 |
| H15 | `hdur_cmp` | h1, h2 | -1/0/1 | 6, 12 |
| H16 | `hdur_ticks` | h | i64 | 6, 12 |
| H17 | `h_is_type` | h, tok | 0/1 | —（null → false） |
| H18 | `h_tag_of` | h | tok | 6 |
| H19 | `h_guard` | h, tok | h | 6, 8 |
| H20 | `h_nonnull` | h | h | 6 |
| H21 | `err_raise` | code | 0 | —（写槽 + site 后返回） |
| H22 | `interrupt_poll` | — | 0 | -2 |
| H23 | `hw_check` | cap | 0 | 16 |
| H24 | `dec_add` | h, h | h | 9, 16 |
| H25 | `dec_sub` | h, h | h | 9, 16 |
| H26 | `dec_mul` | h, h | h | 9, 16 |
| H27 | `dec_div` | h, h | h | 9, 10, 16 |
| H28 | `dec_from_i64` | i64 | h | 16 |
| H29 | `dec_from_f64` | f64 | h | 13, 16 |
| H30 | `dec_to_i64` | h | i64 | 9 |
| H31 | `dec_to_f64` | h | f64 | — |
| H32 | `str_cat` | h, h | h | 6, 16 |
| H33 | `to_str` | v（带标签 t） | h | 6, 8, 16 |
| H34 | `dt_add` | h, h | h | 11, 16 |
| H35 | `dt_sub` | h, h | h | 11, 16 |
| H36 | `dur_add` | h, h | h | 12, 16 |
| H37 | `dur_sub` | h, h | h | 12, 16 |
| H38 | `dur_mul` | h, i64 | h | 12, 16 |
| H39 | `dur_div` | h, i64 | h | 1, 12, 16 |
| H40 | `dur_neg` | h | h | 12, 16 |
| H41 | `range_new` | i64, i64, i64, u8(0/1) | h | 14, 16 |
| H42 | `range_contains` | h, i64 | 0/1 | — |

**分配型 helper（H24–H29、H32–H41）**：每次调用在窗口登记**恰好 1 个新槽**（其结果，不可变值），窗口满则宿主扩容（§9.6）；句柄表达全局上限 → 16。**H30/H31 返回原始值、H42 返回 0/1，均不登记新槽**；H01–H23 同样不登记。`to_str` 的标签 `t`：`0=I64 1=F64 2=Bool 3=String 4=Decimal 5=DateTime 6=Duration 7=Range`。

`ht_field` 的 f：`1=year 2=month 3=day 4=hour 5=minute 6=second 7=nanosecond 8=dayOfWeek 9=epochSec 10=epochMilli`

**类型 token（u16，M1 封闭集；加载器遇未知值拒绝）**：`0 保留，1=List 2=Map 3=String 4=Decimal 5=DateTime 6=Duration 7=Range`。`IS_TYPE/GUARD_TYPE/CAST/H17–H19` 与句柄槽 `tag` 均使用该编码。

**fetch 类失败码约定**：凡经 `HandleTable.fetch` 的 helper，句柄为 null → 6、类型不符 → 8；上表失败码列略写了这类公共项（`ERR_BAD_CAST`(7) 仅由 `CAST` 指令产生）。

**helper 实现模板（必须遵守）**：

```cangjie
@C
func hl_get(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    try {
        let h = args[0]; let i = args[1]
        let list = HandleTable.fetch<ArrayList<Int64>>(h)   // null/类型不符 → 抛
        if (i < 0 || i >= list.size) { ErrIdxOob.throw() }
        return list[i]
    } catch (e: Exception) {
        ctxWriteCode(ctx, codeOf(e))     // 映射到 §2 错误码；未知 → 99
        return 0
    }
}
```

**拼装期 API（非 JIT 调用路径）**：

| 名称 | 签名 | 用途 |
|---|---|---|
| `ConstRegistry.addList` | `(ArrayList<T>) -> hid` | 注册列表字面量常量 |
| `ConstRegistry.addMap` | `(HashMap<K,V>) -> hid` | 注册映射字面量常量 |
| `ConstRegistry.addStr` | `(String) -> hid` | 注册字符串常量 |
| `ConstRegistry.addValue` | `(Decimal/DateTime/Duration) -> hid` | 注册值常量 |
| `ConstRegistry.addRange` | `(start: Int64, end: Int64, step: Int64, isClosed: Bool) -> hid` | 注册区间常量（§11.5 kind 9；对应字面量 `s..e:step` / `s..=e:step`） |
| `ConstRegistry.freeze` | `() -> Unit` | 冻结常量表（之后只读） |

---

## §7 伪指令表（汇编器展开，不出现在最终码流）

| 伪指令 | 操作数 | 展开为 | 约束 |
|---|---|---|---|
| `SET_SITE` | i32 | `mov qword [r15+8], imm32` | 仅在可能失败指令前发射 |
| `CHECK_ERR` | — | `cmp qword [r15+0],0; jne <最近 bail>` | 由 `CALL_HELPER` 自动尾随 |
| `GUARD_HANDLE` | n | `call H20; CHECK_ERR` | 合成形式 |
| `LOOP_BACK` | rel | `STACK_GUARD` + `call H22` + `jmp` | 热循环回边 |
| `BAIL` | k | 独立基本块 `写槽; eax=0; jmp .epilogue` | 每函数至少一个 |
| `PUSH_KH_HINT` | idx | 仅编码期提示，无机器码 | 供调试器映射 |
| `CHECK_ERR_OFF` | — | 取消随后一条自动 CHECK_ERR | 仅 `CALL_HELPER_NC` 语义等价的场景 |
| `BAIL_SITE` | k, i32 | `SET_SITE i32` + `BAIL k` | 便于阅读的组合 |

**与 §5 真实 opcode 的关系**：`SET_SITE/CHECK_ERR/BAIL/LOOP_BACK` 在 `.fbc` 中是 §5 的真实 opcode（03/04/05/74，解释器同样执行它们）；本表的"展开"指机器码 lowering 阶段把这些 opcode 变为实际指令序列，其本身不占机器码字节。`GUARD_HANDLE/PUSH_KH_HINT/CHECK_ERR_OFF/BAIL_SITE` 则是汇编器源层语法糖，不进 `.fbc`。

**汇编期硬校验（报错即拒绝生成）**：

1. 每条 `CALL_HELPER` 后必存在可达 `CHECK_ERR`（除显式 `_NC`）。
2. `0xA0–A3`、`A9–AF`、`0xB8–BF` 与 `0xC0–0xFF` 出现即 `ERR_NOT_IMPL`。
3. 每个 sink（`RET/RET_VOID/BAIL`）前 `rsp` 深度必须回到帧基线（栈平衡校验）。
4. `PUSH_KH idx` 的 idx 必须 < 常量表长度且已 `freeze`。
5. `LOADL/STOREL i`：`i < nLocals`。
6. 存在 `LOOP_BACK` 的函数必须在所有 `CALL_HELPER` 之后保留错误检查（不允许把检查优化掉跨越回边）。
7. `CALL_FUNC` 的 `fid` 必须存在于同一 `.fbc` 函数目录（§11.7）且 `argc` 与被调函数 `nargs` 一致（不符 → 编译错误 / 运行期 `ERR_ARG_MISMATCH`）。
8. M2 专属指令（`CALL_HOST`、`HW_OPEN`、`HW_CLOSE`）在 M1 一律 `ERR_NOT_IMPL`；`HW_CLOSE` 必须与已打开的 `HW_OPEN` 区块配对（配对校验 M2 启用）。
9. 每个函数必须携带局部类型表（§11.7）：长度恰为 `nLocals`、每槽类型值合法；`STOREL` 的栈顶类型与目标槽声明类型一致由**前端保证**（M1 无字节码校验器，不做栈类型跟踪）。
10. **明确赋值与空安全**：非参数局部在被读取的所有可达路径上必须已被 `STOREL` 显式写入（汇编期数据流分析，违规 = 编译错误）；`PUSH_NULL` 不得作为句柄型局部（LocalType 4–8）的赋值源直存。零值填充不可观察（§3.1）。

---

## §8 桥的三个入口签名（Cangjie）

```cangjie
// ① 编译（拼装期一次性）：源码/IR → 可复用函数对象
//    编译粒度是整单元：unit 内全部函数一次处理（§9 附则 11）；
//    返回入口函数对象（fnId == entryFn），单元内其余函数随之就绪，
//    CALL_FUNC 经 §11.7 目录自动互连（支持相互递归）。
//    失败在此刻抛出，不涉及运行期错误槽。
public func compile(
    unit: SourceUnit,
    opts: CompileOptions
): JitFunction

// ②③ 以扩展成员形式声明（Cangjie 语法）
extend JitFunction {

    // ② 抛异常入口：语义等价于直接解释执行
    //    errCode>0  → throw JitException
    //    errCode=-2 → throw InterruptedException
    //    errCode=-1 → 内部退回解释器重跑（对调用方透明，可能补抛解释器的异常）
    public func invoke(
        ctx: CallContext
    ): JitValue

    // ③ 不抛入口：热路径 / 批量调用
    //    任何失败（含 DEOPT 后解释器异常）都收敛为 Err(JitException)
    public func tryInvoke(
        ctx: CallContext
    ): Result<JitValue, JitException>
}
```

**支撑类型**：

```cangjie
public class JitException <: Exception {
    public let code: Int64          // §2 错误码
    public let site: Int64          // 字节码偏移，-1 表示未知
    public let fnId: Int64
    public let sourcePos: ?SourcePos // 由 site 查表得到，可能为 None
    public let message: String       // 桥按 code + site 静态表组装
    public let cause: ?String        // code=99 时附 helper 原始描述
}

public struct CallContext {
    public var args: Array<Int64>        // 入参 cell
    public var literalCopy: Bool = false // M2：字面量深拷贝
    public var strictFp: Bool = false    // bit0 → ctx.flags
    public var deadline: ?DateTime       // 配合 interrupt_poll
}

public enum JitMode { Off | Auto | Force }

public class CompileOptions {
    public var jit: JitMode = JitMode.Auto
    public var cpuFeatures: UInt64 = 0        // M2：显式 ISA 开关
    public var diagnostics: DiagnosticsSink   // 降级/告警接收器（接口从略；§12.1/§13.2 T7 依赖其记录）
    public init(diagnostics: DiagnosticsSink) { self.diagnostics = diagnostics }
}

public struct SourceUnit {
    public let raw: Array<UInt8>     // 已加载 .fbc 的 code/const/site 三段
    public let entryFn: UInt32       // §11.6 容器头；函数目录见 §11.7
}

public enum JitValue {
    | Int(Int64) | Float(Float64) | Handle(Int64) | Unit  // Handle=句柄 ID（已按 §8.1 逃逸，经 HandleTable.fetch 取回对象）
}
```

**桥的三态收尾（`invoke` 内部固定流程）**：

```
1. ctx.errCode = 0; ctx.site = -1; ctx.hwTop = ctx.hwBase; ctx.fnId = f.id
2. rax = rawEntry(ctx, &args[0], nargs)
3. match ctx.errCode:
     0   → unbox(rax)                     // 正常；返回句柄先按 §8.1 逃逸（迁出窗口）
    -1   → interp.run(f, ctx)              // 解释器重跑，其抛出的异常原样上抛
    -2   → throw InterruptedException
    >0   → throw JitException(code, site, ...)
4. （tryInvoke）把第 3 步的所有 throw 收进 Result.Err
```

调用方感知示例：

```cangjie
try {
    let r = f.invoke(ctx)
} catch (e: JitException) {
    println("jit error code=${e.code} at site=${e.site}: ${e.message}")
}
```

**引擎选择（跨平台一致）**：`CompileOptions.jit` 取值 `Off / Auto / Force`。只有 Linux x86_64 / aarch64 上可能产生机器码；其他平台（Windows / macOS / HarmonyOS / 其他架构 Linux）一律**静默降级为解释器**，并在 `CompileOptions.diagnostics` 记一条说明——**绝不因此报错，也绝不改变语义**（见 §12.1、§13）。三个入口的签名与语义在任何平台完全相同。

### §8.1 句柄生命周期与桥 Marshal（v0.4）

对象实例 ↔ 句柄 ID 的转换是**桥独占职责**，机器码与解释器核心只处理整数 ID（I2/I8）。句柄进入字节码世界的三条路径与一个逃逸出口：

| 路径 | 时机 | 登记动作 | 强引用根 |
|---|---|---|---|
| A 常量 | 加载 `.fbc` 时 | 加载器实例化 const 段（kind 3–9）登记 ConstTable（§3.3） | ConstTable（freeze 只读） |
| B 参数 | invoke 前 | 桥 `pin` 宿主对象，ID 写入 `ctx.args[i]`（§8） | 宿主调用方 |
| C 窗口分配 | 执行期 | 分配型 helper（§6 H24–H41）追加槽并推进 `hwTop`（§9.6） | 窗口 `[hwBase, hwTop)` |
| D 逃逸 | unbox 时 | 桥把返回的句柄槽迁出窗口、提升为持久根 | HandleTable 逃逸区/宿主 |

**Marshal API 签名草案**（与 §6 `HandleTable.fetch` 同族，示意）：

```cangjie
public class HandleTable {
    // 路径 B：对象 → ID。同表内同对象复用同 ID；tag 按 §6 类型 token 写入
    public static func pin<T>(obj: T): Int64
    // 路径 D 的读回（宿主侧，返回 Option；与 §6 helper 边界的抛错式 fetch 相区分）
    public static func get<T>(id: Int64): ?T
    // 逃逸句柄显式释放（不调用则随逃逸区生命周期结束）
    public static func release(id: Int64): Unit
}
```

**逃逸规则（三态收尾第 3 步的强制部分）**：

1. 函数签名返回引用类型时，桥在 `unbox` 前把返回句柄对应槽**迁出窗口**：强引用登记入逃逸区，表项保留、ID 不变；随后窗口重置 `hwTop=hwBase` 不影响该槽（§9.6）。
2. 逃逸句柄存活至 `release(id)` 或宿主侧逃逸区销毁；期间表项**不得重用**（`gen` 不变，保证宿主持有的 ID 稳定有效）。
3. 逃逸区受句柄表同一全局上限约束（§9.6，默认 2^20 槽），超限 → `ERR_HANDLE_WINDOW_FULL(16)`。
4. **跨调用 ID 稳定性（冻结语义）**：同一次调用内 ID 稳定（`EQ_H` 可靠）；**跨调用仅常量句柄（路径 A）保证同 ID**——路径 C/D 的结果因重放或重复分配**不保证同 ID**（值不可变 ⇒ 等值）。宿主不得缓存/比较跨调用句柄 ID，应以值比较（`get` 后比较或字节码内比较）为准。
5. Marshal 与逃逸操作由宿主侧同步保护（§9.7）；对机器码与解释器核心完全不可见。

**保活矩阵**：

| 句柄来源 | 强引用根 | 存活期 | 失效方式 |
|---|---|---|---|
| A 常量（kind 3–9 实例化） | ConstTable | 整个单元生命周期 | 单元卸载 |
| B 参数（`pin`） | 宿主调用方 | `pin` 至调用结束 | 宿主释放对象 |
| C 窗口分配（helper 结果） | `[hwBase, hwTop)` | 单次调用 | 返回/重放前重置 `hwTop` |
| D 逃逸（返回值） | 逃逸区/宿主 | `unbox` → `release` | 显式 `release` 或逃逸区销毁 |

### §8.2 统一函数包装：`JitFunction.call<T>`（v0.4）

**定位**：编译器内部的函数包装机制——把字节码与 JIT 产物统一封装为普通仓颉函数，作为 `JitFunction` 的实例成员对外暴露：

```cangjie
extend JitFunction {
    public func call<T>(args: Array<Any>): T
}
```

所有句柄转换（§8.1 `pin`/逃逸）与类型转换（`Any` ↔ cell ↔ 仓颉值）均在编译器与 `call` 内部完成，对宿主代码完全透明；底层是机器码还是解释器不可感知（I7）。

**编译器生成的适配器（核心机制）**：`compile()` 按整单元签名信息为每个函数生成两个内部转换器，并在 `call<T>` 被**单态化**时按 `(签名, T)` 组合生成、缓存最终适配器——T 在编译期实例化点已知，因此解包末端的 downcast 是编译期生成的强类型代码，**不依赖运行期反射**：

```
argMarshalers : Array<(Any) -> Int64>   // 第 i 个 Any 元素 → 第 i 个 cell（含 §8.1 pin）
retUnboxer    : (Int64) -> Any          // 返回 cell → 具体仓颉值（句柄型先走 §8.1 路径 D 逃逸）
```

**`call` 固定六步**：

1. `args.size != nargs` → `JitException(19)`。
2. 逐参 Marshal（§8.2.1 表）；任一元素类型不符 → 19。
3. 组装 `CallContext`，进入三态收尾（§8）执行——**执行期异常原样转换抛出**（§8.2.3），不吞不改。
4. `retUnboxer` 解包返回 cell（句柄型先逃逸）。
5. T 与签名返回类型一致性：同一编译单元内在调用点**静态校验**（编译期报错）；跨模块/动态绑定场景由适配器注册表**运行期校验** → 不符 → 19。
6. 返回 `T`。

- **CallContext 派生字段**：`call` 使用默认 `CallContext`（`strictFp=false`、`deadline=None`、`literalCopy=false`）；需要自定义时改用 `invoke/tryInvoke`。
- **适配器注册表**（第 5 步）：以 `(单元指纹, fnId, T 的编译期类型标识)` 为键，单态化时写入；动态绑定查无此键 → `JitException(19)`。

**§8.2.1 参数 Marshal 表（`Any` → cell）**：

| 签名参数类型 | 接受的 `Any` 实际类型 | 转换 | 失败 |
|---|---|---|---|
| `Int64` | `Int64` | 原值 | 19 |
| `Float64` | `Float64` | IEEE 位模式 | 19 |
| `Bool` | `Bool` | 0/1 | 19 |
| `String/Decimal/DateTime/Duration/Range/List/Map` | 对应引用类型 | `HandleTable.pin`（§8.1 路径 B） | 19 |

- **不做数值宽化与混合提升**（§11.9 提升规则是前端编译期职责，`call` 不重做）；不接受 `Option`/null（句柄传 null → M1 不支持）。
- `pin` 失败抛 `JitException`：句柄表全局上限 → 16；不接受的对象类型（无类型 token，如宿主自定义类）→ 19。

**§8.2.2 返回解包表（cell → `T`）**：

| 签名返回类型 | 解包 | `T` 校验 |
|---|---|---|
| `Int64` / `Float64` / `Bool` / `Unit` | 原值 / 位模式 / 0↔false / 忽略 | `T` == 该类型 |
| `String/Decimal/DateTime/Duration/Range/List/Map` | 逃逸（§8.1 路径 D）→ `get` → 对象引用 | `T` == 该类型 |

- 执行期已失败（`errCode > 0`）→ 不解包，直接按三态收尾抛出（rax 未定义，I5）。

**§8.2.3 异常转换清单（`call` 捕获一切执行异常）**：

| 来源 | 转换结果 |
|---|---|
| 三态收尾 `errCode` 1–18 / 99 | `JitException`（§2 映射，原码原 site） |
| `errCode` = -2 | `InterruptedException` |
| `errCode` = -1 | 内部解释器重放，宿主不可见 |
| Marshal / T 校验失败 | `JitException(19)`（`site=-1`，`sourcePos=None`） |
| helper 内部异常 | 已在 helper 边界转码（§6/§9.5），最终以 1–18/99 浮现 |

- `call` **绝不让非 `JitException`/非 `InterruptedException` 的底层异常逃逸**——桥内兜底转换为 99（§9.5），这是"捕获编译产物执行过程中的所有异常"的规范定义。
- 19 不属于字节码执行错误码（不经错误槽），由 T15 覆盖；T6 仍只覆盖执行期错误码。

---

## §9 附则（实现者必读）

1. **NaN 语义**：`CMP_F` 遇 NaN 结果未定义，汇编器**禁止**对可能含 NaN 的值发射 `CMP_F`，只能走 `EQ_F/NE_F/LT_F/...` 系（IEEE 无序 → false，`NE_F` → true）。
2. **移位**：`SHL_I/SHR_I/USHR_I` 的 b 参数取低 6 位（与 x86 `shl/sar/shr` 一致）；`b<0` 不报错，按位截断。若源语言语义不同，由前端插入 `ASSERT`。
3. **溢出检查成本**：`IADD/ISUB/IMUL` 用 `jo <bail_overflow>`，一个可预测分支；`IDIV` 需前置 `test` 与 `INT_MIN/-1` 判定（约 4 条指令）。
4. **site 精度**：只在**可能失败**的指令前写 site；纯算术指令不写（保持热路径 3–4 条指令）。错误报告中 site 精度为"最近一个可能失败点"。
5. **helper 写码规则**：多层嵌套 helper 时，内层已写码则外层**只在自身捕获到新异常时覆盖**；`catch` 顺序必须是 `catch (e: Exception)` 兜底，末尾必须能吞掉一切并写 99。
6. **窗口容量（可扩容）**：`hwCap` 为编译期初始估计（无分配循环时为精确上界；含分配循环时取静态估计值，超出由扩容兜底；无分配单元 = 0）。**新槽一律追加到句柄表表尾**（`hwBase/hwTop` 仅为本次调用的记账区间，用于 GC 根集合与重放清理）；表达全局上限（默认 2^20 槽，可配置）→ `ERR_HANDLE_WINDOW_FULL(16)`。deopt 重放前桥重置 `hwTop=hwBase`，窗口内未逃逸的槽由宿主 GC 回收；**逃逸槽（§8.1）占用的表项不参与任何后续分配重用**。正常返回的句柄在窗口重置**前**按 §8.1 逃逸规则迁移。
7. **并发**：ctx 随调用栈分配，各调用的句柄窗口 `[hwBase, hwTop)` 互不重叠，句柄表的槽追加由宿主侧同步保护，故 `JitFunction` 可在多线程并发调用（前提：常量表 `freeze` 后不可变）。
8. **不变量回归**：每个 M1 失败点（除零 / 越界 / 缺键 / 类型不符 / helper panic）都必须有对应测试用例，断言 `JitException.code` 与 `site` 两字段正确。
9. **32 位宿主不支持（冻结决策）**：`cell` 恒 64 位、`ctx` 恒 64 字节是整套设计的硬前提，因此 M1 **不为任何 32 位宿主（Windows x86 / Linux i686 / armv7 / …）提供支持路径**——不构建 32 位产物、不做指针压缩、不做 32 位兼容层、不引入"宽 cell"分支。表现为**构建期/装载期失败**而非运行期降级：桥不产出 32 位库；宿主若手工加载，装载向导必须以明确错误拒绝，不得尝试解释执行。
10. **JIT 仅 Linux（冻结决策）**：机器码只在 **Linux x86_64 / aarch64** 上产生；其余平台即使 `jit = Force` 也**静默降级为解释器**（只记 `diagnostics`，不报错、不改语义、不改返回类型）。由此推出硬约束：**字节码中不得出现任何"仅 JIT 可实现"的指令**（`.fbc` 的 `flags.bit1` 恒 0）。当某项优化只有 JIT 做得到时，唯一允许的表现是"解释器跑得慢一些"，绝不允许表现为"该函数只有 JIT 能跑"或"非 Linux 上语义不同"。

11. **编译粒度为整单元（冻结决策）**：`compile()` 一次性处理 `SourceUnit` 内**全部函数**；不存在"单函数增量编译"。`CALL_FUNC` 只允许指向**同一 `.fbc` 单元内**的函数，目标经 §11.7 函数目录解析——相互递归因此天然支持，不依赖编译顺序。把粒度改为增量/跨单元编译属 M2 议题，且不得破坏本条与 §11.7 的一致性。
12. **Decimal = decimal128（IEEE 754-2008，冻结）**：34 位有效数字、emin=-6143、emax=6144、ROUND_HALF_EVEN。加减 scale=max(sa,sb)、乘 scale=sa+sb（超 34 位有效即舍入）、除法"精确优先（≤34 位），否则舍入到 34 位有效"。溢出 → 9；÷0（含 0÷0）→ 10。比较恒精确（`CMP_DEC` 不变）。
13. **插值串是前端糖（冻结）**：`"a${x}b"` → 各片段 `TO_STR`（静态类型标签）+ `STR_CAT` 左结合链；片段类型不在 §6 标签集 → 编译错误。分配型指令在 deopt 重放时会**重新分配等值对象**（I8），允许；T10 覆盖。

> 变更上述冻结决策（例如新增 macOS JIT、支持 32 位宿主、或改为增量编译）属于**范围变更**：需同步更新受影响章节（§8 / §11 / §12 / §13.1）并重跑 §13.2 全量测试，且不得违反 I6 / I7。

---

## §10 附录：opcode 常量表

### §10.1 命名与编码约定

- 常量名规则：`OP_<助记符>`（大写下划线），例如 `OP_PUSH_I8`、`OP_CALL_HELPER`。
- 指令编码：`[op:u8][operands…]` 小端；`rel` 为相对**下一条指令**的有符号 32 位偏移。
- 保留区（RSVD）在 M1 中发射即 `ERR_NOT_IMPL`；禁用区（FORBID：0xA0–A3、A9–AF，M2 启用）同样发射即报错，语义是"会分配但不在 M1 白名单内"。
- 实现侧应构建 `OPCODE_TABLE: Array<OpInfo>` 并以 opcode 为下标索引，供反汇编、汇编期校验、调试器共用。

### §10.2 操作数编码种类（OperandFormat）

| 记法 | 长度 | 含义 |
|---|---|---|
| `-` | 0 | 无操作数 |
| `u8` / `i8` | 1 | 无符号 / 有符号 8 位 |
| `u16` | 2 | 无符号 16 位（局部索引、常量索引、helper id、类型 token） |
| `i32` | 4 | 有符号 32 位（site 值、立即数） |
| `rel32` | 4 | 相对偏移（跳转目标） |
| `i64` | 8 | 64 位立即数（整数值或 Float64 位模式） |
| `u16 u8` | 3 | 双操作数（如 helper id + argc） |
| `u16 i32* i32` | 6+4n | `SWITCH`：n 个 case 偏移 + 默认偏移（操作数字节 = 2 + 4n + 4） |

### §10.3 opcode 常量表（Cangjie 骨架，可直接作为实现起点）

```cangjie
// 类别
public const CAT_MISC:   UInt8 = 0   // 控制/杂项
public const CAT_CONST:  UInt8 = 1   // 常量/栈
public const CAT_LOCAL:  UInt8 = 2   // 局部变量
public const CAT_I64:    UInt8 = 3   // 整型算术
public const CAT_F64:    UInt8 = 4   // 浮点算术
public const CAT_CMP:    UInt8 = 5   // 比较/逻辑/位
public const CAT_CTRL:   UInt8 = 6   // 控制流
public const CAT_CALL:   UInt8 = 7   // 调用
public const CAT_TYPE:   UInt8 = 8   // 类型/转换/错误
public const CAT_BOX:    UInt8 = 9   // 容器/值运算/转换（helper 路由，含分配型）
public const CAT_FORBID: UInt8 = 10  // 禁用（会分配）
public const CAT_RSVD:   UInt8 = 11  // 保留

public struct OpInfo {
    public let code: UInt8
    public let name: String
    public let fmt: String        // 操作数编码，见 §10.2
    public let len: Int64         // 固定长度；可变长度记 0（SWITCH 指令总长 = 1+6+4n）
    public let cat: UInt8
    public const init(code: UInt8, name: String, fmt: String, len: Int64, cat: UInt8) { ... }
}

public let OPCODE_TABLE: Array<OpInfo> = [
  // ---- 0x00–0x0F 控制/杂项 ----
  OpInfo(0x00, "OP_NOP",          "-",   1, CAT_MISC),
  OpInfo(0x01, "OP_TRAP",         "u8",  2, CAT_MISC),
  OpInfo(0x02, "OP_BREAKPOINT",   "-",   1, CAT_MISC),
  OpInfo(0x03, "OP_SET_SITE",     "i32", 5, CAT_MISC),
  OpInfo(0x04, "OP_CHECK_ERR",    "rel32", 5, CAT_MISC),
  OpInfo(0x05, "OP_BAIL",         "i8",  2, CAT_MISC),
  OpInfo(0x06, "OP_CHECK_ERR_NC", "-",   1, CAT_MISC),
  OpInfo(0x07, "OP_STACK_GUARD",  "u16", 3, CAT_MISC),
  // ---- 0x10–0x1F 常量/栈 ----
  OpInfo(0x10, "OP_PUSH_I8",  "i8",  2, CAT_CONST),
  OpInfo(0x11, "OP_PUSH_I32", "i32", 5, CAT_CONST),
  OpInfo(0x12, "OP_PUSH_I64", "i64", 9, CAT_CONST),
  OpInfo(0x13, "OP_PUSH_F64", "i64", 9, CAT_CONST),
  OpInfo(0x14, "OP_PUSH_BOOL","u8",  2, CAT_CONST),
  OpInfo(0x15, "OP_PUSH_NULL","-",   1, CAT_CONST),
  OpInfo(0x16, "OP_PUSH_KH",  "u16", 3, CAT_CONST),
  OpInfo(0x17, "OP_DUP",      "-",   1, CAT_CONST),
  OpInfo(0x18, "OP_DUP2",     "-",   1, CAT_CONST),
  OpInfo(0x19, "OP_POP",      "-",   1, CAT_CONST),
  OpInfo(0x1A, "OP_POP2",     "-",   1, CAT_CONST),
  OpInfo(0x1B, "OP_SWAP",     "-",   1, CAT_CONST),
  OpInfo(0x1C, "OP_PICK",     "u8",  2, CAT_CONST),
  // ---- 0x20–0x2F 局部变量 ----
  OpInfo(0x20, "OP_LOADL",  "u16", 3, CAT_LOCAL),
  OpInfo(0x21, "OP_STOREL", "u16", 3, CAT_LOCAL),
  OpInfo(0x22, "OP_LOADL0", "-",   1, CAT_LOCAL),
  OpInfo(0x23, "OP_LOADL1", "-",   1, CAT_LOCAL),
  OpInfo(0x24, "OP_LOADL2", "-",   1, CAT_LOCAL),
  OpInfo(0x25, "OP_LOADL3", "-",   1, CAT_LOCAL),
  // ---- 0x30–0x3F 整型算术 ----
  OpInfo(0x30, "OP_IADD",      "-", 1, CAT_I64),
  OpInfo(0x31, "OP_ISUB",      "-", 1, CAT_I64),
  OpInfo(0x32, "OP_IMUL",      "-", 1, CAT_I64),
  OpInfo(0x33, "OP_IDIV",      "-", 1, CAT_I64),
  OpInfo(0x34, "OP_IMOD",      "-", 1, CAT_I64),
  OpInfo(0x35, "OP_INEG",      "-", 1, CAT_I64),
  OpInfo(0x36, "OP_IABS",      "-", 1, CAT_I64),
  OpInfo(0x37, "OP_IMIN",      "-", 1, CAT_I64),
  OpInfo(0x38, "OP_IMAX",      "-", 1, CAT_I64),
  OpInfo(0x39, "OP_IADD_WRAP", "-", 1, CAT_I64),
  OpInfo(0x3A, "OP_ICLZ",      "-", 1, CAT_I64),
  OpInfo(0x3B, "OP_IPOPCNT",   "-", 1, CAT_I64),
  // ---- 0x40–0x4F 浮点运算 ----
  OpInfo(0x40, "OP_FADD",     "-", 1, CAT_F64),
  OpInfo(0x41, "OP_FSUB",     "-", 1, CAT_F64),
  OpInfo(0x42, "OP_FMUL",     "-", 1, CAT_F64),
  OpInfo(0x43, "OP_FDIV",     "-", 1, CAT_F64),
  OpInfo(0x44, "OP_FDIV_CHK", "-", 1, CAT_F64),
  OpInfo(0x45, "OP_FNEG",     "-", 1, CAT_F64),
  OpInfo(0x46, "OP_FABS",     "-", 1, CAT_F64),
  OpInfo(0x47, "OP_FMIN",     "-", 1, CAT_F64),
  OpInfo(0x48, "OP_FMAX",     "-", 1, CAT_F64),
  OpInfo(0x49, "OP_FSQRT",    "-", 1, CAT_F64),
  OpInfo(0x4A, "OP_FFLOOR",   "-", 1, CAT_F64),
  OpInfo(0x4B, "OP_FCEIL",    "-", 1, CAT_F64),
  OpInfo(0x4C, "OP_FTRUNC",   "-", 1, CAT_F64),
  OpInfo(0x4D, "OP_FROUND",   "-", 1, CAT_F64),
  // ---- 0x50–0x6F 比较/逻辑/位 ----
  OpInfo(0x50, "OP_CMP_I",  "-", 1, CAT_CMP),
  OpInfo(0x51, "OP_CMP_F",  "-", 1, CAT_CMP),
  OpInfo(0x52, "OP_EQ_I",   "-", 1, CAT_CMP),
  OpInfo(0x53, "OP_NE_I",   "-", 1, CAT_CMP),
  OpInfo(0x54, "OP_LT_I",   "-", 1, CAT_CMP),
  OpInfo(0x55, "OP_LE_I",   "-", 1, CAT_CMP),
  OpInfo(0x56, "OP_GT_I",   "-", 1, CAT_CMP),
  OpInfo(0x57, "OP_GE_I",   "-", 1, CAT_CMP),
  OpInfo(0x58, "OP_EQ_F",   "-", 1, CAT_CMP),
  OpInfo(0x59, "OP_NE_F",   "-", 1, CAT_CMP),
  OpInfo(0x5A, "OP_LT_F",   "-", 1, CAT_CMP),
  OpInfo(0x5B, "OP_LE_F",   "-", 1, CAT_CMP),
  OpInfo(0x5C, "OP_GT_F",   "-", 1, CAT_CMP),
  OpInfo(0x5D, "OP_GE_F",   "-", 1, CAT_CMP),
  OpInfo(0x5E, "OP_NOT_B",  "-", 1, CAT_CMP),
  OpInfo(0x5F, "OP_AND_B",  "-", 1, CAT_CMP),
  OpInfo(0x60, "OP_OR_B",   "-", 1, CAT_CMP),
  OpInfo(0x61, "OP_XOR_B",  "-", 1, CAT_CMP),
  OpInfo(0x62, "OP_BAND_I", "-", 1, CAT_CMP),
  OpInfo(0x63, "OP_BOR_I",  "-", 1, CAT_CMP),
  OpInfo(0x64, "OP_BXOR_I", "-", 1, CAT_CMP),
  OpInfo(0x65, "OP_BNOT_I", "-", 1, CAT_CMP),
  OpInfo(0x66, "OP_SHL_I",  "-", 1, CAT_CMP),
  OpInfo(0x67, "OP_SHR_I",  "-", 1, CAT_CMP),
  OpInfo(0x68, "OP_USHR_I", "-", 1, CAT_CMP),
  OpInfo(0x69, "OP_EQ_H",   "-", 1, CAT_CMP),
  OpInfo(0x6A, "OP_NE_H",   "-", 1, CAT_CMP),
  OpInfo(0x6B, "OP_CMP_STR", "-", 1, CAT_CMP),
  OpInfo(0x6C, "OP_CMP_DEC", "-", 1, CAT_CMP),
  OpInfo(0x6D, "OP_CMP_DT",  "-", 1, CAT_CMP),
  OpInfo(0x6E, "OP_CMP_DUR", "-", 1, CAT_CMP),
  // ---- 0x70–0x7F 控制流与调用 ----
  OpInfo(0x70, "OP_JMP",           "rel32", 5,    CAT_CTRL),
  OpInfo(0x71, "OP_JZ",            "rel32", 5,    CAT_CTRL),
  OpInfo(0x72, "OP_JNZ",           "rel32", 5,    CAT_CTRL),
  OpInfo(0x73, "OP_SWITCH",        "u16 i32* i32", 0, CAT_CTRL),
  OpInfo(0x74, "OP_LOOP_BACK",     "rel32", 5,    CAT_CTRL),
  OpInfo(0x75, "OP_CALL_HELPER",   "u16 u8", 4,   CAT_CALL),
  OpInfo(0x76, "OP_CALL_HELPER_NC","u16 u8", 4,   CAT_CALL),
  OpInfo(0x77, "OP_CALL_HELPER_V", "u16 u8", 4,   CAT_CALL),
  OpInfo(0x78, "OP_CALL_FUNC",     "u16 u8", 4,   CAT_CALL),
  OpInfo(0x79, "OP_CALL_HOST",     "u16 u8", 4,   CAT_CALL),
  OpInfo(0x7A, "OP_HW_OPEN",       "u16", 3,      CAT_CALL),
  OpInfo(0x7B, "OP_HW_CLOSE",      "-", 1,        CAT_CALL),
  OpInfo(0x7C, "OP_RET",           "-", 1,        CAT_CALL),
  OpInfo(0x7D, "OP_RET_VOID",      "-", 1,        CAT_CALL),
  OpInfo(0x7E, "OP_RET_NULL",      "-", 1,        CAT_CALL),
  // ---- 0x80–0x8F 类型/转换/错误 ----
  OpInfo(0x80, "OP_CAST",       "u16 u8", 4, CAT_TYPE),
  OpInfo(0x81, "OP_TO_I64",     "u8", 2,     CAT_TYPE),
  OpInfo(0x82, "OP_TO_F64",     "-", 1,      CAT_TYPE),
  OpInfo(0x83, "OP_IS_TYPE",    "u16", 3,    CAT_TYPE),
  OpInfo(0x84, "OP_GUARD_TYPE", "u16 u8", 4, CAT_TYPE),
  OpInfo(0x85, "OP_THROW",      "u8", 2,     CAT_TYPE),
  OpInfo(0x86, "OP_ASSERT",     "u8", 2,     CAT_TYPE),
  OpInfo(0x87, "OP_ABORT",      "u8", 2,     CAT_TYPE),
  OpInfo(0x88, "OP_GUARD_NNZ",  "u8", 2,     CAT_TYPE),
  OpInfo(0x89, "OP_TYPE_OF",    "-", 1,      CAT_TYPE),
  // ---- 0x90–0x9F 容器/值提取/数值转换 ----
  OpInfo(0x90, "OP_LEN",         "-", 1,    CAT_BOX),
  OpInfo(0x91, "OP_GET_IDX",     "-", 1,    CAT_BOX),
  OpInfo(0x92, "OP_GET_KEY",     "-", 1,    CAT_BOX),
  OpInfo(0x93, "OP_GET_KEY_OR",  "-", 1,    CAT_BOX),
  OpInfo(0x94, "OP_HAS_KEY",     "-", 1,    CAT_BOX),
  OpInfo(0x95, "OP_STR_AT",      "-", 1,    CAT_BOX),
  OpInfo(0x96, "OP_DT_FIELD",    "u8", 2,   CAT_BOX),
  OpInfo(0x97, "OP_DUR_TICKS",   "-", 1,    CAT_BOX),
  OpInfo(0x98, "OP_DEC_IS_INT",  "-", 1,    CAT_BOX),
  OpInfo(0x99, "OP_HANDLE_TAG",  "-", 1,    CAT_BOX),
  OpInfo(0x9A, "OP_RANGE_NEW",   "-", 1,    CAT_BOX),
  OpInfo(0x9B, "OP_RANGE_CONTAINS","-", 1,  CAT_BOX),
  OpInfo(0x9C, "OP_TO_DEC",      "u8", 2,   CAT_BOX),
  OpInfo(0x9D, "OP_DEC_TO_I64",  "u8", 2,   CAT_BOX),
  OpInfo(0x9E, "OP_DEC_TO_F64",  "-", 1,    CAT_BOX),
  // ---- 0xA0–0xAF 分配区（A0–A3 / A9–AA 禁用；A4–A8 自 v0.4 启用）----
  OpInfo(0xA0, "OP_MAKE_LIST",   "-", 1, CAT_FORBID),
  OpInfo(0xA1, "OP_LIST_APPEND", "-", 1, CAT_FORBID),
  OpInfo(0xA2, "OP_MAKE_MAP",    "-", 1, CAT_FORBID),
  OpInfo(0xA3, "OP_MAP_PUT",     "-", 1, CAT_FORBID),
  OpInfo(0xA4, "OP_STR_CAT",     "-", 1, CAT_BOX),
  OpInfo(0xA5, "OP_DEC_ADD",     "-", 1, CAT_BOX),
  OpInfo(0xA6, "OP_DEC_SUB",     "-", 1, CAT_BOX),
  OpInfo(0xA7, "OP_DEC_MUL",     "-", 1, CAT_BOX),
  OpInfo(0xA8, "OP_DEC_DIV",     "-", 1, CAT_BOX),
  OpInfo(0xA9, "OP_DT_NEW",      "-", 1, CAT_FORBID),
  OpInfo(0xAA, "OP_DUR_NEW",     "-", 1, CAT_FORBID),
  // ---- 0xB0–0xB7 时间运算/文本化（v0.4）----
  OpInfo(0xB0, "OP_DT_ADD",      "-", 1, CAT_BOX),
  OpInfo(0xB1, "OP_DT_SUB",      "-", 1, CAT_BOX),
  OpInfo(0xB2, "OP_DUR_ADD",     "-", 1, CAT_BOX),
  OpInfo(0xB3, "OP_DUR_SUB",     "-", 1, CAT_BOX),
  OpInfo(0xB4, "OP_DUR_MUL",     "-", 1, CAT_BOX),
  OpInfo(0xB5, "OP_DUR_DIV",     "-", 1, CAT_BOX),
  OpInfo(0xB6, "OP_DUR_NEG",     "-", 1, CAT_BOX),
  OpInfo(0xB7, "OP_TO_STR",      "u8", 2, CAT_BOX),
  // ---- 0xB8–0xBF / 0xC0–0xFF 保留 ----
  OpInfo(0xFF, "OP_RSVD",        "-", 1, CAT_RSVD),
]
```

**表构建时的一致性校验（建议放在 `OpcodeTable.build()` 的调试断言里）**：

1. 数组长度 == 256，且 `table[i].code == i`（未显式列出的槽以 `OP_RSVD` 填充）。
2. `len != 0` 时，`len == 1 + Σ operandSize(fmt)`。
3. `CAT_FORBID` 与 `CAT_RSVD` 类别的项，以及 M2 专属的 `OP_CALL_HOST/OP_HW_OPEN/OP_HW_CLOSE`，汇编器 `emit` 一律拒绝并报 `ERR_NOT_IMPL`。
4. `CAT_CALL` 中 `OP_CALL_HELPER` 之后必须能查到 `OP_CHECK_ERR`（见 §7 校验 1）。

---

## §11 跨平台字节码规格（Windows / Linux / HarmonyOS / macOS）

字节码是**唯一分发产物**：一份 `.fbc` 在四个平台上必须以相同结果、相同错误码运行。JIT 只是 Linux 上的加速器，因此**任何平台差异都不允许进入字节码层**。

### §11.1 三条移植性原则

| # | 原则 |
|---|---|
| P1 | 字节码是规范（normative），解释器与 JIT 都必须符合它；机器码不是分发物 |
| P2 | 字节码内不含任何宿主信息：无指针、无路径、无 OS 调用号、无寄存器/ABI、无宿主类型宽度 |
| P3 | 结果逐位可复现：整数（checked）、浮点（NaN 规范化）、文本（UTF-8 码点序）、Decimal（精确十进制）、时间（仅 UTC） |

### §11.2 编码与端序

- 字节码是**字节串，固定小端（LE）**：多字节操作数按 LE 写出/读出，**必须显式解码**；禁止 `memcpy`、指针强转、`memcpy` 式的结构体覆盖来解读字节码。这样同一份字节码在 BE 主机上也能被解释器正确执行（JIT 仅面向 LE 目标）。
- cell = 8 字节、8 字节对齐；`Float64` = IEEE754 binary64；`Int64` = 补码，溢出已检查，**不依赖机器 wrap 行为**。
- 指令自身无对齐要求；`SWITCH` 的偏移数组按指令起点 4 字节相对编码，解码仍逐字节读取。
- §10.3 的 `len` 是**平台无关**的字节长度，任何平台都算得相同。

### §11.3 浮点：NaN 规范化（跨平台一致的关键）

| 规则 | 内容 |
|---|---|
| 产生 | 一切产生 NaN 的运算（0/0、Inf-Inf、`FSQRT(负数)`、`FMIN/FMAX` 遇 NaN）一律产出 **canonical NaN = `0x7FF8_0000_0000_0000`** |
| 传播 | 输入 NaN 的 payload 不参与任何可观察语义；拼装期 `PUSH_F64` 常量必须已规范化（加载器校验，非 canonical → 拒绝） |
| 比较 | `EQ_F/NE_F/LT_F/LE_F/GT_F/GE_F` 严格按 IEEE 无序规则 → 与 payload 无关，可复现 |
| `CMP_F` | 遇 NaN 结果未定义，**汇编器禁止发射**（§9.1） |
| 超越函数 | `sin/cos/exp/log/pow` 等 **M1 不提供**；M2 若提供，必须软件实现或显式标记"平台相关"并在差分测试中豁免（不允许静默差异） |
| 有符号零 | `0.0` 与 `-0.0` 只影响 `FDIV` 结果符号，按 IEEE 保留，不做规范化 |

### §11.4 文本与时间

- 字符串 = **UTF-8（无 BOM）**；`hs_len` 返回 UTF-8 字节数；`STR_AT(i)` 的 `i` 按 **Unicode 码点**计数（越界 → `ERR_IDX_OOB`）。
- 非法 UTF-8 / 孤立代理项：拼装期拒绝；运行期不得产生。
- `CMP_STR` 只做**码点序比较**（等价于 UTF-8 字节序），不做 locale case-fold / 词典序 / 规范化，避免平台差异。
- 时间**仅 UTC**：`DT_FIELD` 的 `hour/dayOfWeek/...` 一律按 UTC 计算；本地时区只在桥侧宿主 API 处理，字节码层不可见。
- Decimal 表示固定为 `(sign: u8, scale: Int32, coefficient: 十进制数字串)`；比较为**精确十进制比较**，不得经过浮点中间值，也不得依赖平台十进制库的格式化行为。

### §11.5 常量表序列化（与句柄解耦）

```
ConstTable { version: u16, count: u32, entries: [Entry] }
Entry = (kind: u8, payload)
  kind 1 = Int64         payload: i64
  kind 2 = Float64       payload: 8B（必须为 canonical 位模式，加载器校验）
  kind 3 = String        payload: u32 字节长 + UTF-8 字节
  kind 4 = List          payload: u32 元素数 + u32[常量表索引]
  kind 5 = Map           payload: u32 键值对数 + u32[键索引, 值索引]
  kind 6 = Decimal       payload: u8 sign + i32 scale + u32 长度 + 系数字节串（ASCII '0'–'9'，与 §11.4 表示一致）
  kind 7 = DateTime      payload: i64 = epochNanos（UTC）
  kind 8 = Duration      payload: i64 = nanos
  kind 9 = Range         payload: i64 start + i64 end + i64 step + u8 isClosed（1=左闭右闭 `..=`）
```

- 序列化中**只有值，没有句柄 ID**：句柄 ID 是**加载时分配**的运行时索引，跨进程/跨平台都不稳定，禁止写入字节码。
- 常量表必须是 **DAG**（允许共享子结构，禁止环）；加载器做环检测。
- 每份 `.fbc` 附 `constFingerprint: u64`（FNV-1a）与 `crc32`，仅用于缓存键与诊断，**不参与语义**。

### §11.6 容器头 `.fbc`

```
off  size 字段        说明
0    4    magic       "FBC1"
4    2    verMajor    1
6    2    verMinor    1（v0.4 起新增 opcode；加载器接受 ≤ 自身版本的 verMinor）
8    4    flags       bit0=UTF-8 语义(恒 1)  bit1=需要 JIT(必须为 0)  bit2=使用值运算/分配类指令（helper 路由：A4–A8 / 0x9A–0x9E / 0xB0–0xB7 时置 1）
12   4    hdrSize     恒 32（v1；为向后兼容预留）
16   4    codeLen
20   4    constLen
24   4    siteLen     站点表（偏移 → 源位置）长度
28   4    entryFn     入口函数 id
32   4    crc32       code + const + site
36   ...  code / const / site 三段依次存放
```

- `flags.bit1`（需要 JIT）**必须恒为 0**（冻结决策，§9 附则 10）：字节码不得要求 JIT 存在。某优化只有 JIT 能做时，唯一允许的表现是"解释器跑得慢"。`flags.bit2`（值运算/分配类指令）自 v0.4 启用：置 1 时加载器按需预扩句柄表；置 0 的单元出现分配型指令 → 加载期拒绝（与汇编器校验双保险）。
- 未知 `flags` 位或更高 `verMajor` → 加载期拒绝（桥抛 `JitException(code=18, ERR_NOT_IMPL 语义)`）。
- 站点表（site table）是**平台无关的偏移到源位置映射**，三引擎的错误报告都从这里取源位置。

### §11.7 代码段与函数目录（`CALL_FUNC` 依赖）

code 段头部是**函数目录**，其后是各函数体依次紧排：

```
FuncDir   { count: u32, funcs: [FuncEntry] }
FuncEntry = { fnId: u32, codeOff: u32, codeLen: u32, localTypesOff: u32,
              nargs: u16, nLocals: u16, maxStack: u16, flags: u16 }
```

- `codeOff/codeLen/localTypesOff` 相对 code 段起点；`frameSize` 由 §3.1 公式在加载期算出（平台无关）。

**局部类型表（v0.4 起，每个函数一份，`localTypesOff` 指向，共 `nLocals` 字节）**：

```
LocalType (u8，每槽 1 字节):
  0=Int64   1=Float64  2=Bool     3=Unit
  4=String  5=Decimal  6=DateTime 7=Duration 8=Range
  9–255 保留（加载器拒绝）
```

- 值型（0–3）槽存原始 cell；句柄型（4–8）槽存句柄 ID（0=null），且与 §6 类型 token 一一对应：String↔3、Decimal↔4、DateTime↔5、Duration↔6、Range↔7（供 `IS_TYPE/GUARD_TYPE/H19` 使用）。
- 类型表覆盖**全部 nLocals 槽**，含参数槽 `locals[0..nargs-1]`（其类型应与函数签名一致——前端责任）。
- **明确赋值与空安全（v0.4 修订）**：局部**没有默认值**——非参数局部必须先 `STOREL` 后读取（汇编期数据流校验，§7 校验 10；读未赋值 = 编译错误）；**没有空值**——句柄型局部（4–8）恒为有效句柄（≠0），`PUSH_NULL` 不得直存（§3.1 空安全）。参数槽 `locals[0..nargs-1]` 由调用方赋值，天然满足；参数句柄为 0（桥边界互操作值）时在 helper 边界报 6。内存卫生填充（§3.1）不可观察。
- **规范地位**：M1 中类型表是规范性元数据——加载器校验其结构（`localTypesOff` 落在 code 段内、恰 `nLocals` 字节、类型值合法、纳入 `crc32`）；**运行期不做栈类型跟踪**（无字节码校验器，M2 议题）。句柄型局部装入错误类型的句柄时，在 helper fetch 边界暴露为 6/8（§6 fetch 约定）。
- **可声明的局部类型集**：`Int64 / Float64 / Bool / Unit / String / Decimal / DateTime / Duration / Range`；**List/Map 不可声明为局部**（M1 容器只读且仅常量，M2 开放）。
- `CALL_FUNC fid` 经目录解析目标（支持相互递归，不依赖编译顺序）；`fid` 不存在或 `argc != nargs` → 编译错误 / 运行期 `ERR_ARG_MISMATCH`。
- 编译粒度是**整单元**（§9 附则 11）：单元内函数一次编译、目录与类型表整体生成；不存在单函数增量编译。
- 容器头 `entryFn` 必须命中目录中某个 `fnId`，否则加载期拒绝。
- 目录、局部类型表与函数体一并纳入 `crc32` 覆盖范围。

### §11.8 跨平台禁止清单

| 禁止 | 原因 |
|---|---|
| 字节码内出现主机地址 / 宿主句柄 / 文件路径 | 换平台即失效 |
| 依赖宿主 `Long`/`Double` 宽度（非 64 位） | cell 恒 64 位；**32 位宿主不支持**（冻结决策，§9 附则 9） |
| 依赖 wrap 溢出、移位越界、NaN payload、有符号零打印 | 已由 §11.2/§11.3/§11.9 固定或禁入 |
| `CALL_HOST`（M2）引用未在各平台注册的回调 | 各平台注册集不同 → 加载期校验为 `ERR_NOT_IMPL` |
| 机器码持久化 / 跨机共享 / 写入 `.fbc` | 后端与 ABI 相关 |
| 字节码中出现"仅 JIT 可实现"的指令 | 违反 I6 / P1；`flags.bit1` 恒 0（冻结决策，§9 附则 10） |
| 按平台分叉行为（错误码不同、某平台被拒） | 冻结决策：JIT 仅 Linux，其余平台解释执行且**语义、可用性完全相同**（§9 附则 10） |
| TO_STR / 插值 / 数值转换依赖平台 locale 或宿主格式化库 | 违反 P3；全部格式已由 §11.9 冻结，实现必须内嵌同一算法 |

### §11.9 数值互转与文本化格式（v0.4，全部冻结）

**互转矩阵**（"默认转换"由前端自动插入以下显式指令实现；字节码层无隐式行为，I6）：

| 转换 | 指令 | 规则 |
|---|---|---|
| I64→F64 | `TO_F64` | IEEE 最近偶数 |
| F64→I64 | `TO_I64` | mode 定报错/DEOPT；NaN/越界 → 13 |
| I64→DEC | `TO_DEC` src=0 | 精确，scale=0 |
| F64→DEC | `TO_DEC` src=1 | **最短往返**十进制表示（Ryu 算法族）；NaN/±Inf → 13 |
| DEC→I64 | `DEC_TO_I64` | 向零截断；越界 → 9 |
| DEC→F64 | `DEC_TO_F64` | IEEE 最近偶数；溢出 → ±Inf（不报错） |

> F64→DEC→F64 复合可能不还原原位型（最短往返 ≠ 精确二进制值）；这是冻结语义，不是缺陷。前端对 F64→DEC 的"默认转换"应谨慎（建议仅显式使用）。

**混合类型四则与比较（提升规则，前端实现"默认"行为；字节码层仍只有显式指令，I6）**：

提升格（窄 → 宽）：`Int64 → Float64`（`TO_F64`）、`Int64 → Decimal`（`TO_DEC` src=0）、`Float64 → Decimal`（`TO_DEC` src=1，最短往返）。宽度序：**Decimal > Float64 > Int64**。

| 混合操作 | 前端降低为 | 结果/比较域 |
|---|---|---|
| `I64 op F64`（含反序） | 窄侧 `TO_F64` + F64 运算/比较 | F64 |
| `I64 op DEC`（含反序） | 窄侧 `TO_DEC`(src=0) + DEC 运算/比较 | DEC |
| `F64 op DEC`（含反序） | F64 侧 `TO_DEC`(src=1) + DEC 运算/比较 | DEC |

- `op` 覆盖 `+ − × ÷` 与全部比较（`EQ/NE/LT/LE/GT/GE`；DEC 域经 `CMP_DEC`）。
- 精度语义（冻结）：`I64→F64` 在 |v| ≥ 2^53 时按 IEEE 最近偶数舍入，比较结果由此唯一定义；`F64→DEC` 按最短往返（故 `0.1f64 == Decimal("0.1")` 为真）。除零沿用目标域规则（DEC → 10；F64 → ±Inf 不报错）。

**量纲约定**：`(Duration, Duration)` 只定义 `DUR_ADD/DUR_SUB` 与 `CMP_DUR`；`×/÷` 只对 `(Duration, Int64)` 定义（`DUR_MUL/DUR_DIV`）。`(DateTime, Duration)` 只定义 `DT_ADD/DT_SUB`（负 Duration 即减）；`DateTime − DateTime → Duration` 属 M2。

**TO_STR 格式（逐字节冻结，跨平台一致；实现内嵌同一算法，禁止依赖平台 printf/locale）**：

| 值 | 格式 |
|---|---|
| Bool | `true` / `false` |
| Int64 | 十进制（负号 `-`） |
| Float64 | 最短往返表示；整数值附 `.0`（如 `1.0`）；`0.0`→`0.0`、`-0.0`→`-0.0`；`NaN` / `Infinity` / `-Infinity`；极大/极小按算法默认规则切科学计数 |
| Decimal | 恒 plain 记法：`-` + 系数 + 按 scale 插小数点（scale 大于系数位数 → `0.0…` 前补零；负 scale → 整数尾补零）；不用科学计数 |
| DateTime | `YYYY-MM-DDTHH:MM:SS.nnnnnnnnnZ`（UTC，恒 9 位纳秒；值域 0001-01-01T00:00:00Z … 9999-12-31T23:59:59.999999999Z，即 errCode 11 的判定域） |
| Duration | `[-]PT{h}H{m}M{s}.{nnnnnnnnn}S`（负值整体前置 `-`；h/m/s 为绝对值、三段恒输出；恒 9 位小数） |
| Range | `{start}..{end}` 或 `{start}..={end}`（按 isClosed）；`step ≠ 1` 时附加 ` : {step}`（空格风格与仓颉字面量一致） |
| String | 原样（插值语义，不加引号） |

**区间语义（严格对齐仓颉 `Range<T>`，M1 仅 `Range<Int64>`）**：

- 字面量两形式（与仓颉一致）：`start..end : step`（左闭右开）、`start..=end : step`（左闭右闭）；省略 `: step` 时 step=1；**step ≠ 0**（=0 → 14；常量 step=0 由前端编译期拒绝）。
- 区间由四元组 `(start, end, step, isClosed)` 定义；**空区间合法**（不报错）：
  - `..`：`step>0 且 start ≥ end` → 空；`step<0 且 start ≤ end` → 空
  - `..=`：`step>0 且 start > end` → 空；`step<0 且 start < end` → 空
- step 可为负（`10..0 : -2` 遍历 10, 8, 6, 4, 2），方向由 step 符号决定。
- `RANGE_CONTAINS(h, v)`：按上述语义判定（`..=` 含 end；空区间恒 false）。
- 开端点区间（构造器 `hasStart/hasEnd=false` 形态）M1 不支持：字节码中的区间恒有双端点。
- 迭代 / 切片 / 按区间索引属 M2。

---

## §12 JIT 后端规格（Linux · x86_64 / AArch64）

### §12.1 适用范围与架构基线

| 平台 | 引擎 |
|---|---|
| Linux x86_64 | 解释器 + JIT（后端 **B1**） |
| Linux aarch64 | 解释器 + JIT（后端 **B2**） |
| Linux 其他架构（riscv64 / loongarch64 / …） | 仅解释器 |
| Windows / macOS / HarmonyOS（任意架构） | 仅解释器（接口与语义完全一致；`jit = Force` 亦静默降级） |
| 任何 32 位宿主（Windows x86 / Linux i686 / armv7 / …） | **不支持**（**冻结决策**：cell 64 位、ctx 64 字节是硬前提；构建期/装载期明确拒绝，见 §9 附则 9） |

- 平台范围是**冻结决策**：JIT 后端只随 Linux 构建产出；非 Linux 平台不编译机器码路径，也不得因缺少 JIT 而报错或降级语义（§9 附则 10）。
- 基线 ISA：x86_64 用 **SSE2**（x86-64 ABI 已保证存在）；aarch64 用 **NEON/ASIMD**（A64 基线）。JIT **不发射** AVX/AVX2/AVX512/SVE，不做运行时特性探测分支；需要时由 `CompileOptions.cpuFeatures` 显式开启（M2）。
- 引擎选择（三平台语义一致，只看能否拿到机器码）：

```cangjie
let engine = match (opts.jit) {
    case Off   => Engine.Interp
    case Force | Auto =>
        if (Platform.isLinux && (Platform.arch == X86_64 || Platform.arch == Aarch64)) {
            Engine.Jit        // Auto 另以字节码指纹为缓存键
        } else {
            diag("jit unavailable on ${Platform.os}/${Platform.arch}; fallback to interp")
            Engine.Interp
        }
}
```

### §12.2 后端抽象与 ABI 映射（两后端必须等价）

| 抽象名 | x86_64（SysV） | AArch64（AAPCS64） | 角色 |
|---|---|---|---|
| `CTX` | `r15` | `x19` | **callee-saved**，全程持 ctx；helper 调用不失效 |
| `FP` | `rbp` | `x29` | 帧基址 |
| `SP` | `rsp` | `sp` | 操作数栈 + 局部槽 |
| `RETV` | `rax` | `x0` | 返回值 cell |
| `TMP` | `r10`、`r11` | `x9`、`x10` | 立即数/中间结果（caller-saved，跨 helper 调用不可存活） |
| helper 入参 | `rdi=ctx, rsi=&args, rdx=n` | `x0=ctx, x1=&args, x2=n` | 见 §6 helper ABI 的**抽象签名**：`(ctx, &args, nargs)` |
| helper 返回 | `rax` | `x0` | cell |
| 返回地址 | 由 `call` 压栈 | `x30`(lr) | aarch64 必须由 prologue 保存 `x29/x30` |

- 两平台栈均要求 **16 字节对齐**，故 §3.1 的 `frameSize` 统一按 16 取整，两后端共用同一计算式。
- `CTX` 必须落在 callee-saved 寄存器：helper 调用会打烂 caller-saved（x86 的 `rdx/rcx`、aarch64 的 `x0–x17`；`x18` 为平台保留寄存器，同样不可依赖）。

### §12.3 入口 / 出口序列

```asm
; x86_64
    endbr64                     ; CET/IBT 若启用（未启用时为无害指令）
    push  rbp
    mov   rbp, rsp
    mov   [rbp-8], r15          ; 保存调用方 r15（callee-saved，与 §3.1/§4 一致）
    mov   r15, rdi              ; CTX
    sub   rsp, FRAME
    ...
    mov   r15, [rbp-8]          ; 恢复调用方 r15
    mov   rsp, rbp
    pop   rbp
    ret
```

```asm
; aarch64
    bti   c                     ; BTI 若启用（未启用时为无害指令）
    stp   x29, x30, [sp, #-16]!
    mov   x29, sp
    str   x19, [x29, #-8]       ; 保存调用方 x19（callee-saved，帧位形与 x86 相同）
    mov   x19, x0               ; CTX
    sub   sp, sp, #FRAME
    ...
    ldr   x19, [x29, #-8]       ; 恢复调用方 x19
    mov   sp, x29
    ldp   x29, x30, [sp], #16
    ret
```

- `endbr64` / `bti c` 策略为"**可用即发射**"：在未启用 CET/BTI 的内核上分别是 `NOP` 与无害指令，两后端代码路径统一。
- 入口第一参数位置不同（`rdi` vs `x0`），因此**桥必须为每个后端各生成一个 5 行的 thunk**，thunk 之后是同一份"把 args 拷进 locals"的序言模式（§4 prologue 的逐条展开）。
- 出口唯一（`.epilogue`）：`RET / RET_VOID / BAIL` 全部 `jmp .epilogue`，`BAIL` 前置 `eax/x0 = 0`（哑值）。

### §12.4 关键指令降低对照（语义必须逐位一致）

| 字节码 | x86_64 | AArch64 |
|---|---|---|
| `IADD`(checked) | `add rax,[rsp+8]; jo .bail3` | `adds x9,x9,x10; b.vs .bail3`（`adds` 置 V） |
| `ISUB`(checked) | `sub` + `jo` | `subs` + `b.vs` |
| `IMUL`(checked) | `imul`（置 OF）+ `jo` | `mul` **不置 V**：用 `smulh x11,x9,x10; cmp x11, x9, asr #63; b.ne .bail3` |
| `IDIV`(checked) | `test r10,r10; jz .bail1`；再判 `INT64_MIN / -1` → `.bail3`；然后 `cqo; idiv r10`（商 rax） | `cbz x10,.bail1`；`movz x11,#0x8000,lsl #48`(INT64_MIN)、`mov x12,#-1`（`movn`）比较后 `b.eq .bail3`；`sdiv x11,x9,x10` |
| `IMOD` | 除零判定与 IDIV 同；除数为 -1 → 直接得 0（硬件 `idiv` 对 `INT_MIN/-1` 会 `#DE`，而数学上余数恒 0，**不报溢出**）；否则 `cqo; idiv` 取 `rdx` | `sdiv` 不陷入，`msub` 天然正确（含 `INT_MIN/-1` → 0） |
| `PUSH_I8/PUSH_I32` | `movsx` 后压栈 | `sxtb` / `sxtw` 后压栈 |
| `PUSH_F64` | `movabs rax, imm64`（或从常量池 `movsd`） | `movz/movk` 四次拼装（或文字池 `ldr x9, =imm64`） |
| 浮点算术 | `movq xmm0, rax; addsd/subsd/mulsd/divsd` | `fmov d0, x9; fadd/fsub/fmul/fdiv` |
| `SHL_I/SHR_I/USHR_I` | `shl/sar/shr cl`（x86 自动掩码 63） | `lsl/asr/lsr x9, x9, x10`（aarch64 自动取低 6 位）——语义天然一致 |
| `CMP_I` | `cmp` + `setg/setl` 组合出 -1/0/1 | `cmp x9,x10; cset x11,lt; cset x12,gt; sub x11,x12` |
| `EQ_H` / `PUSH_NULL` | 整数 `cmp`（句柄即整数） | 同左 |
| `JZ/JNZ` | `test rax,rax; je/jne` | `cbz/cbnz x9, target` |
| `CALL_HELPER` | 参数经 `rsp` 布局后 `call` | 同样以 `sp` 布局、`bl` |
| `CHECK_ERR` | `cmp qword [r15+0],0; jne .bail` | `ldr x11,[x19]; cbnz x11, .bail` |

**分支可达范围差异（必须处理）**：

| 后端 | 条件分支范围 | 无条件分支范围 | 处理 |
|---|---|---|---|
| x86_64 | `jcc rel32` ≈ ±2 GB | `jmp rel32` ≈ ±2 GB | 通常无需 trampoline |
| aarch64 | `b.cond` ≈ **±1 MB** | `b` ≈ ±128 MB | 越界时插入跳板（trampoline）或跳板表 |

由于 aarch64 条件分支范围小，汇编器/后端需做**两遍布局**：先按短分支编码，越界则升级为"取反条件 + 无条件 `b`"跳板。此逻辑必须在两个后端共享的布局阶段实现，而非各自硬编码。

**分配/值运算指令的 lowering**：`A4–A8`、`0x9A–0x9E`、`0xB0–0xB7` 全部与 `CALL_HELPER` 同一模式——`call <helper>` + 自动 `CHECK_ERR`。其中分配型（A4–A8、0x9A、0x9C、0xB0–0xB7）在宿主 helper 内分配并登记窗口槽（结果 = 新句柄 ID）；0x9B/0x9D/0x9E 返回原始值、不登记。两类机器码均无新增模式，I8 自动满足。`hwCap` 估计在编译期完成（§9.6），JIT 与解释器共用同一窗口机制。

### §12.5 代码内存、缓存与生命周期

- 内存：`mmap(PROT_READ|PROT_WRITE)` → 写入 → `mprotect(PROT_READ|PROT_EXEC)`，**W^X**，绝不使用 RWX。页大小取 `sysconf(_SC_PAGESIZE)`（4 KB / 16 KB / 64 KB 都必须正确）。
- aarch64：写入代码后必须清 I-cache（`__builtin___clear_cache` 或 `dc cvau / dsb ish / ic ivau / dsb ish / isb` 序列）；x86_64 由硬件保证一致性，但同一抽象接口调用。
- 不使用可执行栈；不修改既有代码页后重入（M1 不做跳转补丁，跳板只在编译期布局阶段解决）。
- 生命周期：`JitFunction` 释放时 `munmap`；编译缓存以 `(arch, cpuFeatures, bytecodeFingerprint)` 为键，**仅驻内存**，进程退出即丢弃。
- 失败处理：`mmap/mprotect` 失败 → `Engine.Interp` 降级（不是错误，不写错误槽）。

### §12.6 并发与去优化

- `JitFunction` 编译完成即**不可变**，可跨线程共享；编译自身用每函数一次的状态机（`NotCompiled → Compiling → Ready`，CAS 或自旋锁），重复请求等待或直接解释执行。
- DEOPT：`errCode = -1` → 桥回解释器重跑（§8 第 3 步）。因为机器码不分配（分配仅在宿主 helper 内，结果只是句柄 ID，I8），机器码**不需要栈映射（stack map）**，也就无需帧重建——这是最大的简化。重放会重新执行分配型 helper、产出等值的不可变新对象，语义不变（§9.13、T10）。
- 安全点：仅 `LOOP_BACK` 回边（`interrupt_poll`），保证超时可中断；不做异步抢占。

### §12.7 后端合规判据（可测定义）

对同一 `.fbc` 与同一输入，以下三者必须**逐位相等**（结果值 / NaN 位模式 / `errCode` / `site`）：

```
interp(args)  ==  jit_x86_64(args)  ==  jit_aarch64(args)
```

任何不一致一律视为 JIT 缺陷；唯一豁免是 §11.3 中显式标记为"平台相关"且默认不启用的特性（M1 无此类特性）。

---

## §13 平台矩阵与差分测试

### §13.1 能力矩阵

| 维度 | Windows x64 | Linux x86_64 | Linux aarch64 | Linux 其他 64 位 | macOS arm64 | HarmonyOS arm64 |
|---|---|---|---|---|---|---|
| 解释器 | 必须 | 必须 | 必须 | 必须 | 必须 | 必须 |
| JIT | — | B1 | B2 | — | — | — |
| 加载 `.fbc` | 是 | 是 | 是 | 是 | 是 | 是 |
| 常量表 | 同一份 | 同一份 | 同一份 | 同一份 | 同一份 | 同一份 |
| `jit = Off/Auto/Force` | 三值均为解释器 | Auto/Force 生效 | Auto/Force 生效 | 三值均为解释器 | 三值均为解释器 | 三值均为解释器 |
| 错误码 / site | 同一套 | 同一套 | 同一套 | 同一套 | 同一套 | 同一套 |

### §13.2 测试项

| # | 测试项 | 判据 |
|---|---|---|
| T1 | **黄金字节码**：一份 `.fbc` 在所有平台加载执行 | 结果哈希与错误码完全一致 |
| T2 | **差分（核心）**：Linux 上 `interp` vs `jit_x86_64` vs `jit_aarch64` | 结果、`errCode`、`site` 三者全等 |
| T3 | **端序**：显式解码单测（构造非对齐/跨页边界的操作数） | 不依赖主机端序与对齐 |
| T4 | **页大小**：4 KB / 16 KB / 64 KB 页内核（或容器）各跑一遍 | 代码缓存分配、`munmap`、I-cache 清理正确（与 §12.5 一致） |
| T5 | **CET/BTI**：启用 IBT/BTI 的内核上运行 JIT | 入口 `endbr64` / `bti c` 正确，无控制保护异常 |
| T6 | **错误一致性**：§2 全部**执行期**错误码（0–18、99）逐条触发（19 为桥层契约错误，由 T15 覆盖） | 三引擎 `code` 与 `site` 相同；无未映射错误码漏出 |
| T7 | **降级一致性**：Windows/macOS/HarmonyOS 上 `jit = Force` | 不报错、结果与 Linux 解释器一致、diagnostics 有记录 |
| T8 | **NaN 与文本**：跨平台浮点边界 + 多语言字符串（含 4 字节码点） | 与 §11.3/§11.4 规则逐条相符 |
| T9 | **冻结决策回归**：装载 `flags.bit1=1` 的 `.fbc`；32 位构建/装载；非 Linux 上 `jit = Force` | 前两者明确拒绝（§9.9 / §11.6）；后者静默降级且结果与 Linux 解释器一致（§9.10） |
| T10 | **分配与重放**：含 `STR_CAT/DEC_*/DUR_*` 的函数触发 DEOPT 重放；循环内分配超过初始 `hwCap` | 重放结果值相等、`errCode/site` 一致；窗口扩容正确，16 仅在全局上限出现 |
| T11 | **TO_STR 黄金值**：§11.9 全类型格式 ×（±0 / NaN / Inf / 极端 Decimal / 4 字节码点插值 / 负 Duration） | 三引擎输出逐字节一致，与黄金文件全等 |
| T12 | **混合类型差分**：§11.9 提升矩阵全组合（3 类型对称对 × 四则与比较 × 提升方向，含 2^53 边界、`0.1` 类浮点、除零、空区间判定） | 三引擎结果与错误码逐位一致，与提升规则推导值全等 |
| T13 | **类型化局部变量与明确赋值**：全部 9 种 LocalType 的显式赋值/读取；读未赋值局部 → **汇编期拒绝**（非运行期错误）；`PUSH_NULL` 直存句柄型局部 → 拒绝；句柄型局部在后续 helper 调用（可能触发 GC）后仍有效；类型表破坏性用例（长度错/非法值）被加载器拒绝 | 明确赋值/空安全在汇编期强制；零值填充**不可观察**（无任何用例可读到 0/null）；存活语义逐位一致；非法类型表拒绝且纳入 crc32 |
| T14 | **句柄 Marshal 与逃逸**：invoke 返回 `STR_CAT/DEC_ADD` 结果 → 窗口重置后 `get` 有效；`release` 后 `get` → None 且表项不重用（gen 校验）；DEOPT 重放产物值相等；逃逸区超配额 → 16；跨调用 ID 稳定性（常量稳定、分配型不保证） | 逃逸/释放/重放语义符合 §8.1 矩阵；pin/get/release 在并发下无竞态 |
| T15 | **统一包装 call\<T\>**：§8.2.1/§8.2.2 全类型组合（含错误入参：长度不符、元素类型不符、T 与返回类型不符 → 19）；call 与 invoke 对同一执行错误的 `code/site` 一致；三引擎差异对 call 不可见；异常转换清单逐条验证 | 全部契约错误 → 19 且 `site=-1`；执行错误与 invoke 逐位一致；无非 JitException/非 InterruptedException 异常逃逸 |

### §13.3 版本演进约束

1. 新增 opcode 只允许使用 §5 保留区段，并同步升 `verMinor`；语义变更升 `verMajor`。
2. 新增 JIT 后端（如 riscv64）只能是"新增一个 lowering 表 + 一个 ABI 映射行"，不得修改 §11 字节码语义。
3. 任何"解释器能跑、JIT 跑不了"的指令都不得进入字节码（`flags.bit1` 恒 0）。
4. **冻结决策不得被平台适配绕过**：M1 只支持 64 位宿主，且 JIT 仅在 Linux x86_64 / aarch64 生效（§9 附则 9–10）。任何"给某平台开特例"的补丁，只要它改变语义、改变可用性（在非 Linux 上抛错而 Linux 不抛）或要求 JIT 必须存在，一律拒绝；确需变更时按 §9 附则的变更流程走**范围变更**并重跑 §13.2。
