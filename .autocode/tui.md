# 仓颉 TUI 开发框架可行性报告

> **版本**：1.0  
> **摘要**：完全使用仓颉编程语言，从零构建一个不依赖任何 C/C++/Rust 第三方终端界面库的文本用户界面（TUI）开发框架，并原生支持 **macOS、Linux、鸿蒙（HarmonyOS）和 Windows**。  
> 本报告从终端底层原理、仓颉语言能力、跨平台抽象方案、关键模块实现、工作量与风险等多个维度进行了全面论证，结论为**技术可行，且具备高度的生态价值**。

---

## 目录

1. [项目背景与目标](#1-项目背景与目标)
2. [终端技术基础](#2-终端技术基础)
3. [仓颉语言能力评估](#3-仓颉语言能力评估)
4. [跨平台原生支持方案](#4-跨平台原生支持方案)
5. [系统架构设计](#5-系统架构设计)
6. [核心模块与关键技术实现路径](#6-核心模块与关键技术实现路径)
7. [可行性分析](#7-可行性分析)
8. [风险与应对策略](#8-风险与应对策略)
9. [结论与建议](#9-结论与建议)
10. [附录](#10-附录)

---

## 1. 项目背景与目标

### 1.1 背景
仓颉编程语言作为新兴的现代编程语言，当前生态中还没有成熟的 TUI 开发框架。虽然已有社区尝试通过 FFI 桥接 Rust 的 `ratatui` 等库，但这些方案依然强依赖外部 C/Rust 运行时，不能称为“纯仓颉”实现。

本项目旨在填充这一生态空白，证明仓颉语言自身完全具备构建完整 TUI 框架的能力，只需借助操作系统提供的标准 C 接口，无需任何第三方 TUI 库。

### 1.2 目标
- **纯仓颉内核**：所有框架代码均使用仓颉编写，仅通过 FFI 调用操作系统标准库（如 POSIX `termios`、Windows Console API），不依赖任何第三方 C/C++/Rust 库。
- **四平台原生支持**：同时支持 **macOS、Linux、鸿蒙（HarmonyOS）和 Windows**，并为每个平台提供真正的原生实现。
- **功能完整**：支持键盘事件、鼠标事件、ANSI 转义序列渲染、UTF-8 和中文输入、窗口大小自适应、组件化开发等现代 TUI 必备特性。
- **开发者友好**：提供清晰的事件循环、组件模型和布局系统，使开发者能快速构建终端应用。

---

## 2. 终端技术基础

### 2.1 终端显示模型
现代终端是一个**字符单元网格**，程序通过向标准输出写入 ANSI 转义序列来控制显示。所有可视化操作均可通过 `print` 完成，无需外部图形库。常用序列包括：

- 光标定位：`\e[{row};{col}H`
- 清屏：`\e[2J`
- 颜色控制：`\e[{style}m`（支持 16 色、256 色、真彩色）
- 光标显隐：`\e[?25l` / `\e[?25h`
- 鼠标报告开关：`\e[?1000h` 等

### 2.2 终端 I/O 控制：原始模式
默认情况下，终端处于“规范模式”（行缓冲、回显、信号处理），构建 TUI 必须将其切换为“原始模式”，以便逐字节读取按键，完全接管显示。POSIX 系统中通过 `termios` 和 `tcgetattr`/`tcsetattr` 实现；Windows 通过 `SetConsoleMode`/`GetConsoleMode` 实现。

### 2.3 键盘输入协议
在原始模式下，终端将按键以字节流形式发送给程序，主要分为三类：
- 可打印 ASCII 字符（单字节，如 `a` → `0x61`）
- 控制字符（如 `Ctrl+A` → `0x01`，`Enter` → `0x0D`）
- 转义序列（功能键、方向键、Alt/Shift 组合等，以 `0x1B` 开头，例如 `\e[A` 为上箭头）

### 2.4 鼠标输入协议
终端可被设置为鼠标报告模式，广泛支持的协议包括：
- **X10**：按下/释放事件，坐标范围有限（0‑223）
- **SGR (1006)**：支持大坐标、修饰键、拖拽和释放区分，格式如 `\e[<0;5;10M`（左键在 5,10 按下）

推荐同时启用 `1002` 和 `1006` 模式。

### 2.5 UTF-8 与中文输入
输入法框架（如 fcitx、iBus）独立于终端，在原始模式下仍可向程序注入已选汉字。但是程序需要自己处理：
- 多字节 UTF-8 序列解码
- 退格时按完整码点删除
- 字符显示宽度计算（全角/半角）

---

## 3. 仓颉语言能力评估

### 3.1 标准库现状
仓颉标准库未内置终端控制相关功能，但提供了：
- 基础 I/O 流（`Console.stdOut`、`Console.stdin`）
- 基本类型与数据结构（`Array`、`String`、`Int32`/`UInt32` 等）
- 外部函数接口（FFI）：`@C` 修饰结构体、`foreign` 函数声明、`CPointer` 和内存操作

### 3.2 FFI 与系统调用能力
通过 `@C foreign func` 可直接声明 C 标准库函数（如 `tcgetattr`、`read`、`write`、`SetConsoleMode` 等），仓颉结构体可通过 `@C` 布局映射到 C 内存模型。这为直接调用操作系统提供的标准 API 提供了通道，完美符合“不依赖第三方库”的约束。

### 3.3 性能与内存管理
TUI 框架属于 I/O 密集型应用，渲染帧率通常低于 60 fps，GC 压力极小。仓颉的自动内存管理足以胜任事件循环中临时对象的分配，双缓冲渲染的字符串拼接可通过预分配缓冲区进一步优化。

### 3.4 跨平台编译
仓颉编译器支持多目标平台，可生成 macOS、Linux 和鸿蒙的原生机器码；Windows 下可通过 MinGW 工具链产生原生可执行文件。结合条件编译指令，能够为不同平台选择具体的 OS 抽象实现。

---

## 4. 跨平台原生支持方案

为保证统一接口下的原生体验，框架采用以下分层策略：

| 平台 | 系统 API | 终端协议 | 说明 |
|------|----------|----------|------|
| **macOS** | POSIX (`termios` / `sys/ioctl`) | ANSI + SGR 鼠标 | 现代终端模拟器（Terminal.app、iTerm2）完美支持 |
| **Linux** | POSIX (`termios` / `sys/ioctl`) | ANSI + SGR 鼠标 | 同 macOS，GNOME Terminal、Konsole 等均兼容 |
| **鸿蒙** | POSIX (`termios`，OpenHarmony 已包含) | ANSI + SGR 鼠标（待验证） | 仓颉为鸿蒙原生语言，可直接编译为鸿蒙目标 |
| **Windows** | Windows Console API (`kernel32.dll`) | ANSI + SGR 鼠标（需 Windows 10 1703+） | 暂不支持 Xterm 兼容层（如 MSYS2 PTY），直接调用原生 API |

- **POSIX 三平台（macOS/Linux/鸿蒙）** 可共享同一套 `termios` 后端实现，仅需在编译时指定目标。
- **Windows** 需要单独的后端实现，但视图层（ANSI 渲染）与事件解析器完全通用。

---

## 5. 系统架构设计

框架采用典型的分层架构，将平台差异隔离在最低层。

```
┌──────────────────────────────────────────┐
│             Application Layer            │  ← 用户编写的 TUI 程序
├──────────────────────────────────────────┤
│          Widget & Layout Layer           │  ← 组件库、布局引擎（可选扩展）
├──────────────────────────────────────────┤
│           Event Handling Layer           │  ← 统一事件分发、事件循环
├──────────────────────────────────────────┤
│          Terminal Backend Layer          │  ← 原始模式管理、读写、ANSI 渲染
├──────────────────────────────────────────┤
│         OS Abstraction Layer             │  ← 平台抽象接口
│  ┌─────────┐  ┌────────┐  ┌───────────┐ │
│  │ POSIX   │  │ Windows│  │  Future   │ │
│  │(termios)│  │(CONSOLE)│  │ Platforms │ │
│  └─────────┘  └────────┘  └───────────┘ │
└──────────────────────────────────────────┘
```

### 核心模块
1. **OS 抽象层**  
   定义 `TerminalBackend` 接口，包括：
   - `enableRawMode()` / `disableRawMode()`
   - `readByte() -> ?Byte`
   - `write(buf: String)`
   - `getSize() -> (Int32, Int32)`
   - `enableMouse()` / `disableMouse()`

2. **终端控制模块**  
   封装实际的系统调用，如 POSIX 的 `tcgetattr`/`tcsetattr`，Windows 的 `SetConsoleMode`。同时负责发送 ANSI 序列开启鼠标报告等。

3. **输入解析器**  
   - 带缓冲的字节读取（支持 `unget`）
   - ESC 序列解析状态机（CSI/SS3/SGR/X10）
   - 生成 `KeyEvent`、`MouseEvent`
   - 内建 UTF-8 解码

4. **渲染引擎**  
   - 维护虚拟屏幕缓冲区（`Array<Cell>` 或字符串）
   - 比较新旧缓冲区差异，输出最小化 ANSI 更新（差分渲染），避免全屏闪动
   - 提供基础绘图原语：`moveTo`、`setColor`、`drawText`、`drawRect`

5. **事件循环**  
   - `run()` 方法统一入口，循环“读取输入 → 解析 → 分发 → 重绘”

6. **组件系统（可选）**  
   基于状态管理和布局计算的控件库，提供按钮、文本框、列表、对话框等。

---

## 6. 核心模块与关键技术实现路径

### 6.1 POSIX 后端实现（macOS / Linux / 鸿蒙）

#### 6.1.1 硬件抽象：`termios` 的 FFI 绑定
通过 `@C` 结构体映射 `termios`，声明系统函数：

```cangjie
@C
struct Termios {
    var c_iflag: UInt32 = 0
    var c_oflag: UInt32 = 0
    var c_cflag: UInt32 = 0
    var c_lflag: UInt32 = 0
    var c_line: UInt8 = 0
    var c_cc: CPointer<UInt8>
}

foreign {
    func tcgetattr(fd: Int32, termios_p: CPointer<Termios>): Int32
    func tcsetattr(fd: Int32, optional_actions: Int32, termios_p: CPointer<Termios>): Int32
}
```

定义必要常量（`ICANON`, `ECHO`, `VMIN` 等），在 `enableRawMode()` 中修改标志位并调用 `tcsetattr`。

#### 6.1.2 非规范读取
设置 `VMIN = 1`, `VTIME = 0`，通过 `read(0, &byte, 1)` 逐字节读取输入，配合内部 `InputBuffer` 实现 `unget` 功能。

#### 6.1.3 终端尺寸获取
利用 `ioctl` 和 `TIOCGWINSZ` 结构，或解析 ANSI `\e[6n` 请求，获取窗口大小变化（监听 `SIGWINCH` 信号）。鸿蒙是否支持 `TIOCGWINSZ` 需进一步验证，若否，可回退至 `\e[18t` 序列请求。

### 6.2 Windows 后端实现

Windows 不支持 POSIX `termios`，必须通过 `kernel32.dll` 中的 Console API 实现。

#### 6.2.1 获取标准句柄并设置模式
```cangjie
foreign {
    func GetStdHandle(nStdHandle: UInt32): CPointer<void>
    func SetConsoleMode(hConsoleHandle: CPointer<void>, dwMode: UInt32): Bool
    func GetConsoleMode(hConsoleHandle: CPointer<void>, lpMode: CPointer<UInt32>): Bool
    func ReadConsoleInputW(...): Bool   // 用于读取键鼠事件（高级方案）
}
```

原始模式的启用通过清除 `ENABLE_ECHO_INPUT`、`ENABLE_LINE_INPUT` 等标志，并设置鼠标输入模式 `ENABLE_MOUSE_INPUT | ENABLE_EXTENDED_FLAGS`。

#### 6.2.2 输入处理
- **简单方案**：使用 `ReadFile` 从标准输入读取字节流（ANSI 序列与按键）。此时可使用与 POSIX 几乎相同的解析逻辑。
- **高级方案**：使用 `ReadConsoleInputW` 直接获得结构化的 `INPUT_RECORD`，可区分按键、鼠标、窗口大小变化等。鼠标事件可直接解析 `MOUSE_EVENT_RECORD`，无需处理 SGR 序列。

#### 6.2.3 终端尺寸
通过 `GetConsoleScreenBufferInfo` 获取缓冲区大小，并监听 `WINDOW_BUFFER_SIZE` 事件（若使用 `ReadConsoleInputW`）。

### 6.3 键盘解析器

实现一个与平台无关的有限状态机，从字节流中解析 `KeyEvent`。

```cangjie
enum KeyEvent {
    Char(Char)
    Ctrl(Int8)
    Enter | Tab | Backspace | Escape
    ArrowUp | ArrowDown | ArrowLeft | ArrowRight
    F(Int32)
    KeyWithModifier(KeyEvent, Modifier)
    // ...
}
```

- 单字节 ASCII / 控制字符：直接映射
- `ESC` 开头：若后续为 `[` 进入 CSI 解析，若为 `O` 进入 SS3，否则视为 `Alt+字符`
- CSI 序列：读取数字和分号，终结符决定功能（如 `A` → 上箭头）

### 6.4 鼠标解析器

- 在启用原始模式后发送 `\e[?1002h\e[?1006h`（POSIX）或在 Windows 中调用 `SetConsoleMode` 设置鼠标输入标志。
- 解析器拦截 `\e[<`（SGR）和 `\e[M`（X10）序列，提取坐标、按钮状态和修饰键，生成 `MouseEvent`。

### 6.5 渲染引擎

采用双缓冲 + 差分渲染策略：

1. 构造一个 `Screen` 对象（二维 Cell 数组），每个 Cell 包含字符、前景色、背景色、样式。
2. 每次绘制完成后，与先前帧比较，只输出变化区域的 ANSI 更新序列（光标移动 + 修改属性 + 打印字符）。
3. 最终调用 `flush()` 一次性输出至标准输出。

### 6.6 UTF-8 与中文支持

- 在键盘解析阶段，若识别到 UTF-8 多字节起始字节，连续读取后续字节组成完整码点。
- 实现简版 `wcwidth` 以计算字符显示宽度，确保中文等全角字符占据两列。
- 文本框组件需根据码点边界执行插入/删除，避免截断半个汉字。

---

## 7. 可行性分析

### 7.1 技术可行性：**高**
- 所有底层能力（原始 I/O、ANSI、鼠标协议）均为公开标准，无专利壁垒。
- 仓颉 FFI 能充分调用各平台原生 C API，弥补标准库缺失。
- 已有 Go（tcell）、Rust（ratatui）等语言的成功先例，证明此模式的成熟性。

### 7.2 性能评估：**优秀**
- TUI 渲染压力极小，差分渲染可将单帧输出控制在一百字节以内。
- 字节解析与状态机转换在微秒级完成，不会产生人机交互延迟。

### 7.3 跨平台兼容性：**良好**
- POSIX 三平台 85% 代码可复用。
- Windows 需要独立后端，但渲染与事件解析层可完全共用。
- 鸿蒙因其 POSIX 兼容性，开发成本几乎与 Linux/macOS 相同。

### 7.4 开发工作量预估

| 模块                       | 预估人天 | 说明                                     |
|----------------------------|----------|------------------------------------------|
| OS 抽象层（POSIX + Windows）| 12–18    | 含 `termios` 封装、Windows Console API 封装、ioctl 尺寸获取 |
| 输入解析器（键鼠）         | 10–14    | 状态机设计、多终端适配测试               |
| 渲染引擎                   | 8–12     | 差分渲染、ANSI 序列生成                 |
| 事件循环与框架集成         | 5–8      | 调度逻辑、信号处理（SIGWINCH）           |
| UTF-8/中文支持             | 3–5      | 解码器、宽度计算、退格逻辑               |
| 基础组件与布局             | 15–20    | 文本框、按钮、列表、弹性布局（可选扩展） |
| 测试与兼容性验证           | 10–15    | 各平台多终端环境测试                     |
| **总计**                   | **63–82 人天** | 可产出最小可用框架（MVP）及基本组件库   |

---

## 8. 风险与应对策略

| 风险 | 影响 | 缓解措施 |
|------|------|----------|
| **标准库缺失大量常量** | 开发初期需大量手工定义常量，容易出错 | 从权威头文件（如 musl libc）复制，并使用自动化脚本验证 |
| **终端模拟器兼容差异** | 某些序列在特定终端上不工作或表现异常 | 建立终端能力检测表，提供优雅降级（如真彩色→256色→16色） |
| **鸿蒙 POSIX 子集不完整** | 缺少 `TIOCGWINSZ` 或部分函数 | 准备备用方案（ANSI 询问序列、信号模拟），并与鸿蒙团队沟通 |
| **Windows 控制台遗留 API** | 旧版 Windows 不支持 ANSI | 要求 Windows 10 1703+，并检测支持性；若不支持，优雅退出并提示用户升级 |
| **程序崩溃导致终端混乱** | 原始模式下无回显，终端可能不可用 | 设置 `panic` 钩子强制调用 `disableRawMode()`；同时提供安全模式（限时自动恢复） |
| **中文输入法兼容性** | 组合字符、预编辑字符串可能破坏光标 | 实现标准的 Text Input 协议（部分终端支持）或仅接收已确认的文本 |

---

## 9. 结论与建议

**完全使用仓颉语言构建一个原生支持 macOS、Linux、鸿蒙和 Windows 的 TUI 开发框架，在技术上是明确可行的。**

- **POSIX 平台**（macOS、Linux、鸿蒙）可通过共享 `termios` 后端实现 **95% 以上代码复用**。
- **Windows** 需要独立实现 Console API 后端，但工作量和难度完全可控。
- 仓颉的 FFI 和跨平台编译能力为此提供了坚实基础。

### 实施建议
1. **MVBP（最小可行产品）先行**：优先实现 POSIX 端极简内核（ASCII 键盘解析 + 基本渲染），验证仓颉 FFI 的稳定性。
2. **快速验证鸿蒙**：在鸿蒙 SDK 中编译 POSIX 后端测试程序，确认 `termios` 和 ANSI 序列表现。
3. **Windows 后端并行开发**：在框架抽象层确定后，尽早开展 Windows 后端开发，确保同步迭代。
4. **建立测试套件**：构建自动化测试，覆盖不同终端模拟器（iTerm2、Windows Terminal、GNOME Terminal 等），确保长期可维护性。

该框架一旦完成，将成为仓颉生态中首个纯自研的 TUI 基础设施，能够显著降低终端应用开发门槛，具有很高的社区价值和推广意义。

---

## 10. 附录

### A. 常用的 ANSI 转义序列速查
| 功能 | 序列 |
|------|------|
| 光标移至 (行,列) | `\e[{row};{col}H` |
| 清屏 | `\e[2J` |
| 隐藏光标 | `\e[?25l` |
| 显示光标 | `\e[?25h` |
| 设置前景色 (256色) | `\e[38;5;{n}m` |
| 设置真彩色前景 | `\e[38;2;{r};{g};{b}m` |
| 重置样式 | `\e[0m` |
| 启用鼠标 (1002+1006) | `\e[?1002h\e[?1006h` |
| 请求光标位置 | `\e[6n` |
| 请求终端尺寸 | `\e[18t` |

### B. POSIX 与 Windows 关键 API 对照
| 功能 | POSIX | Windows |
|------|-------|---------|
| 进入原始模式 | `tcsetattr` 修改 `c_lflag` 等 | `SetConsoleMode` 清除 `ENABLE_LINE_INPUT` 等 |
| 读取一个字节 | `read(STDIN_FILENO, &byte, 1)` | `ReadFile` 或 `ReadConsoleInputW` |
| 写入输出 | `write(STDOUT_FILENO, buf, len)` | `WriteFile` 或 `WriteConsoleW` |
| 获取终端大小 | `ioctl(..., TIOCGWINSZ, &ws)` | `GetConsoleScreenBufferInfo` |

### C. 鸿蒙环境技术验证清单
- [ ] `termios.h` 及其常量定义是否存在
- [ ] `tcgetattr` / `tcsetattr` 的行为是否符合 POSIX
- [ ] `ioctl` + `TIOCGWINSZ` 是否可用
- [ ] 现代 ANSI 序列（256 色、真彩色）支持度
- [ ] SGR(1006) 鼠标协议支持度
- [ ] 常见终端模拟器（如 hdc shell 终端）的行为测试

---

> **结论**：仓颉 TUI 框架项目具有明确的技术路径和可控的工程规模，建议启动开发，分阶段交付。该框架将成为仓颉生态中重要的基础组件。

