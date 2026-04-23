# Gene: code2gene
## 从代码库提取API策略基因

**触发词**: code2gene, 提取基因, 生成GENE, API基因, 代码转基因

---

## 适用条件 (When)

触发本基因的场景：
- 用户指定一个代码路径，要求生成该模块的API使用GENE
- 需要为某模块/库/包创建可供编程智能体直接使用的策略基因
- 智能体需要快速了解如何调用某模块的API、添加依赖、导入包
- 代码库较大需要按模块拆分多个GENE

---

## 核心原则 (What)

### 元原则：代码即基因源

1. **控制 > 文档**：GENE不是API文档的复制，而是紧凑的调用控制信号
2. **信号密度**：只保留智能体实际编码时需要的决策信号（导入路径、依赖声明、构造方式、调用模式）
3. **可操作性**：读取GENE后可立即写出正确代码，无需再查阅源码
4. **紧凑性**：单GENE ≤ 250 tokens，API过多时按模块拆分多个GENE

### 提取原则

| 原则 | 说明 |
|------|------|
| 依赖先行 | 优先提取：包声明、依赖配置、导入路径——这些是使用的先决条件 |
| 构造即入口 | 提取核心类型的构造方式，而非所有方法列表 |
| 模式优于枚举 | 提取2-3个典型调用模式，而非逐个枚举所有API |
| 陷阱即警告 | 从代码中发现的特殊约束提炼为紧凑警告 |
| 语言特化 | 仓颉等非主流语言需标注语言特有语法和API差异 |

---

## 执行流程 (How)

### Step 1: 扫描代码库

```
输入: <path>/<folder>
操作:
  - 读取目录结构，识别模块/包边界
  - 识别语言类型（Java/Kotlin/Python/Rust/仓颉/...）
  - 标记：[包声明] [导入] [公开API] [依赖配置] [构造函数] [关键方法] [语言特有约束]
输出: 按模块分组的代码摘要
```

### Step 2: 提取策略信号

对每个模块提取以下信号（按优先级）：

**P0 - 必须提取（阻断性）**：
- 依赖声明（cjpm.toml / pom.xml / Cargo.toml / requirements.txt / go.mod）
- 包声明与导入路径
- 核心类型的构造方式（init/构造函数签名）
- 语言特有约束（如仓颉的FFI语法、Resource接口等）

**P1 - 应当提取（高价值）**：
- 典型调用模式（2-3个最常见的使用范式）
- 类型间关系（继承/实现/组合）
- 必需的配置或初始化步骤

**P2 - 选择性提取（辅助）**：
- 容易出错的陷阱或边界条件
- 性能相关的调用约定
- 并发/线程安全约束

### Step 3: 编码为GENE

按以下格式编码每个模块的GENE：

```markdown
gene_api_<module_name>:
  tags: [<language>, <module_name>, <domain>, api-usage]
  principles:
    - 依赖: <依赖声明方式 + 包导入路径>
    - 构造: <核心类型构造签名，含默认值和命名参数>
    - 调用: <2-3个典型调用模式，伪代码级>
    - 约束: <语言特有或模块特有的必须遵守的约束>
  boundaries:
    valid: <本GENE覆盖的API范围>
    invalid: <本GENE不覆盖的内容，需查阅其他资源>
```

### Step 4: 拆分策略

当单模块API过多时，按以下策略拆分：

| 拆分维度 | 示例 |
|----------|------|
| 按功能子模块 | `gene_api_io_uring_submit` / `gene_api_io_uring_wait` |
| 按类型层次 | `gene_api_skiplist_node` / `gene_api_skiplist_map` |
| 按使用场景 | `gene_api_stream_read` / `gene_api_stream_write` |
| 按依赖层级 | `gene_api_core_types` / `gene_api_high_level_ops` |

拆分后的GENE之间通过tags建立关联，智能体可通过标签链式召回。

### Step 5: 保存

```
保存路径: ./.autocode/skills/gene/<folder>_<sub_module>/SKILL.md
示例: ./.autocode/skills/gene/std_sync_mutex/SKILL.md
      ./.autocode/skills/gene/std_sync_atomic/SKILL.md
```

---

## 语言特化规则

### 仓颉语言特化

当目标代码为仓颉(.cj)时，额外提取：

| 提取项 | 说明 |
|--------|------|
| 包声明 | `package org_name::module.sub` 格式 |
| 组织名 | cjpm.toml 中的 organization，包声明需带组织前缀 |
| 导入路径 | `import org_name::module.sub.*` 或 `import std.xxx.*` |
| 依赖声明 | cjpm.toml 的 `[dependencies]` 节点格式 |
| 可见性 | 成员默认 `internal`，需标注 `public`/`open` 才可跨包访问 |
| FFI语法 | `foreign func` 声明、CPointer转换、无U后缀等约束 |
| 资源接口 | try-with-resource 要求 `Resource` 接口 |
| 并发原语 | `spawn`/`Future`/`synchronized(mutex){}`/`AtomicXXX` |
| 泛型约束 | `where T <: SuperType`，不支持协变逆变 |

### 主流语言特化

| 语言 | 关键提取项 |
|------|-----------|
| Java/Kotlin | Maven/Gradle依赖、包声明、接口实现关系 |
| Python | pip依赖、import路径、装饰器用法 |
| Rust | Cargo依赖、use路径、trait bound |
| Go | go.mod依赖、import路径、接口实现 |
| C/C++ | 头文件包含、CMake/Makefile配置、链接库 |

---

## 输出质量检查

- [ ] 读取GENE后能直接写出正确的导入和依赖声明？
- [ ] 读取GENE后能正确构造核心类型实例？
- [ ] 调用模式是否覆盖了80%的常见用法？
- [ ] 语言特有约束是否全部标注？
- [ ] 单GENE是否 ≤ 250 tokens？
- [ ] 拆分后的GENE标签是否可链式召回？

---

## 使用示例

**用户输入**：
> 对 /path/to/std_sync 生成GENE

**执行过程**：
1. 扫描 std_sync 目录，发现 mutex.cj, atomic.cj, counter.cj 等文件
2. 识别为仓颉语言，提取包声明 `std.sync`
3. 按功能拆分为 mutex / atomic / counter 子模块
4. 为每个子模块生成GENE，保存至 ~/.autocode/skills/std_sync/mutex/SKILL.md 等

**生成示例**：

```markdown
gene_api_cangjie_std_sync_mutex:
  tags: [cangjie, std.sync, mutex, concurrency, lock]
  principles:
    - 依赖: cjpm.toml无额外依赖; import std.sync.Mutex; import std.sync.synchronized
    - 构造: Mutex() 无参构造; 无需手动初始化
    - 调用: synchronized(mutex){ 临界区 } 优先; mutex.lock()/unlock()禁止使用（异常不安全）
    - 约束: 必须用synchronized(mutex){}而非lock/unlock对; 仓颉无ReentrantLock
  boundaries:
    valid: 互斥锁、临界区保护、简单的线程同步
    invalid: 读写锁(用RWMutex)、条件变量(用Condition)、原子操作(用AtomicXXX)
```
