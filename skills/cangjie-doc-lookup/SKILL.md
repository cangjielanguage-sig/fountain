---
name: cangjie-doc-lookup
description: 查阅仓颉（Cangjie）编程语言的官方本地文档，包括语言特性/语法文档、标准库（std）API 文档和扩展库（stdx）API 文档。当用户询问仓颉语言语法、关键字、编译器行为、标准库或扩展库中某个包/类型/函数的用法、签名、示例时使用本技能。文档为本地 Markdown 文件，可通过文档地图快速定位，或通过检索脚本/全文搜索查找相关内容。
---

# 仓颉文档查阅

## Overview

本技能让智能体高效查阅三份本地仓颉编程语言官方文档：语言特性文档（开发指南与工具链）、标准库（std）API 文档、扩展库（stdx）API 文档。文档均为 Markdown 格式；**路径固化在技能目录内的 `paths.json`**，技能提供文档地图与检索工具帮助快速定位。

## 执行前检查（每次用本技能先做，不要跳过）

```bash
python <skill-root>/scripts/skill_paths.py check     # exit 0=三个源都可用；exit 1=有不可用
```

- 全部 `[OK]` → 直接进入「检索流程」。
- 出现 `[缺少]` → **停下来，把下面四选一原样交给用户选**，不要替用户决定：

  1. 全硬盘搜索并把搜索到的路径固化到技能
  2. 从仓颉代码仓克隆完整的项目源码并将克隆的项目路径固化到技能
  3. 用户指定路径并把指定路径固化到技能
  4. 什么也不做

按用户的选择执行（**固化**= 写入技能目录内的 `paths.json`，下次检查直接通过）：

| 选择 | 执行命令 | 结果 |
| --- | --- | --- |
| 1 全硬盘搜索 | `python <skill-root>/scripts/find_docs.py`（`--root <目录>` 缩小范围，`--depth` / `--max-seconds` 控制代价） | 列出候选路径；**多于一个候选时把清单交给用户确认**，确认后 `skill_paths.py set <源> <路径>`；唯一候选可用 `--set` 直接固化 |
| 2 克隆源码仓 | `python <skill-root>/scripts/clone_docs.py`（默认克隆到 `~/.cangjie-doc-lookup`，`--dir` 可改；`--source lang\|std\|stdx` 只克隆其中一个；`--full` 保留完整历史） | 克隆 cangjie_docs / cangjie_runtime / cangjie_stdx 三个仓，并自动把对应文档根固化到 `paths.json` |
| 3 用户指定路径 | `python <skill-root>/scripts/skill_paths.py set <源> <路径>` | 自动规范化（给仓库根或上层目录也能认）并写回 `paths.json` |
| 4 什么也不做 | 不固化 | 明确告知用户「本技能当前没有可用文档源」；仍可读 `references/doc-map.md`（快照）与通用知识作答，但要说明结论可能过时 |

固化后**必须复验**（`check` 全绿再继续）；路径变过要重新生成文档地图：`python <skill-root>/scripts/build_index.py`。

## 文档源路径

三个源的固化值存放在 `<skill-root>/paths.json`（技能随附的默认值见下表）：

| 文档 | 源 key | 默认根目录 |
| ---- | ------ | ---------- |
| 语言特性文档 | `lang` | `D:\docs\work\cangjie\cangjie-doc\cangjie_docs` |
| 标准库（std） | `std` | `D:\docs\work\cangjie\projects\cangjie_runtime\std\doc\libs\std` |
| 扩展库（stdx） | `stdx` | `D:\docs\work\cangjie\projects\cangjie_stdx\doc\libs_stdx` |

查看 / 修改：`python <skill-root>/scripts/skill_paths.py show`、`... set <源> <路径>`。
`search_docs.py` / `build_index.py` 都读这份配置，没有各自硬编码的路径。

来源仓（四选一之 2 用）：

- 仓颉标准库文档仓 `https://gitcode.com/Cangjie/cangjie_docs.git` → 文档根就是克隆目录（`lang`）
- 仓颉标准库代码仓 `https://gitcode.com/Cangjie/cangjie_runtime.git` → 文档根 `<repo>/stdlib/doc/libs/std`（早期布局是 `<repo>/std/doc/libs/std`，脚本两种都认；`std`）
- stdx 文档与源码仓 `https://gitcode.com/Cangjie/cangjie_stdx.git` → 文档根 `<repo>/doc/libs_stdx`（`stdx`）

## 检索流程

（先完成上一节的「执行前检查」，`check` 全绿后再往下做。）

1. **确定文档类型**：
   - 语法/语言特性/编译构建/工具链问题 → 语言特性文档
   - `std.` 开头的包（如 `std.collection.ArrayList`）→ 标准库文档
   - `stdx.` 开头的包（如 `stdx.crypto`、`stdx.encoding.json`）→ 扩展库文档

2. **使用文档地图**：读取 `references/doc-map.md`，其中列出了三个文档源全部 Markdown 文件的路径与首行标题，可快速定位目标文档。该文件由 `scripts/build_index.py` 自动生成，文档更新后可重新运行刷新。

3. **全文检索**（可选）：运行 `python scripts/search_docs.py <关键词> [--source lang|std|stdx]` 在文档源中检索关键词，返回命中文件与行号；随后用 read_file 打开命中文件查看详细内容。也可以直接用全文搜索工具（search_content）在文档源根目录中检索。

4. **读取文档**：用 read_file 打开定位到的 Markdown 文件，读取完整内容回答用户问题。

## 文档结构说明

### 语言特性文档（cangjie_docs）

- `docs/dev-guide/source_zh_cn/`：开发指南（中文），按主题分子目录：basic_data_type（基础数据类型）、function（函数）、class_and_interface（类和接口）、generic（泛型）、collections（集合类型）、concurrency（并发）、enum_and_pattern_match（枚举与模式匹配）、error_handle（异常处理）、compile_and_build（编译和构建，含 cjc/cjpm/条件编译/交叉编译）、deploy_and_run（部署运行）、Macro（宏）、FFI（跨语言互操作）、reflect_and_annotation（反射与注解）、basic_programming_concepts（基础概念）、package（包管理）、Net（网络编程）、Basic_IO（基础 I/O）、multiplatform（跨平台）、struct（结构体）、extension（扩展）、Appendix（附录：关键字、运算符、编译选项、cjo 产物等）。
- `docs/dev-guide/source_en/`：同一开发指南的英文版。
- `docs/tools/source_zh_cn/`：工具链手册（cangjie-language-server、cmd-tools 命令行工具、library_evolution_spec 库演进规格）。
- `docs/central-repo/source_zh_cn/`：仓颉中心仓（包制品仓库）使用说明。

### 标准库文档（std）

按包（package）组织，每个包目录内包含：
- `*_package_overview.md`：包概览，含功能介绍与 API 列表索引
- `*_package_api/`：具体 API 文档（分为 classes/interfaces/enums/exceptions/functions/structs 等文件）
- `*_package_samples/`：使用示例代码

常用包：core（基础类型与对象）、collection（集合）、collection_concurrent（并发集合）、io（I/O 流）、net（网络）、fs（文件系统）、time（时间）、regex（正则）、math/math_numeric（数学）、convert（类型转换）、console（控制台）、env（环境）、process（进程）、sync（并发同步）、reflect（反射）、sort（排序）、unicode、random、objectpool（对象池）、overflow、binary、database_sql（数据库）、argopt（命令行解析）、ast（AST）、crypto.cipher/crypto.digest（加解密）、unittest/unittest_mock/unittest_prop_test 等。完整包列表见 `std/std_module_overview.md`。

### 扩展库文档（stdx）

同样按包组织。常用包：crypto（加解密，子包 common/crypto/digest/keys/kit/x509）、compress.zlib/compress.tar（压缩）、encoding.base64/hex/json/json_stream/url（编解码）、net.http/net.tls（网络协议）、log/logger（日志）、serialization（序列化）、actors（actor 模型）、aspect_cj（AOP）、syntax（语法解析）、plugin、fuzz、effect 等。完整包列表见 `libs_stdx/libs_overview.md`（含各包依赖关系与编译链接命令）。

## 使用示例

**示例 1：查标准库 API 用法**

用户问"如何在仓颉中使用 ArrayList"。先读 `references/doc-map.md` 定位到 `std/collection/collection_package_overview.md`，或用检索脚本搜索 `ArrayList`，再用 read_file 读取对应文档（overview 中有 API 索引，再进 `collection_package_api/` 或 `collection_package_samples/` 看签名与示例）。

**示例 2：查语言特性**

用户问"仓颉的泛型怎么定义"。定位到 `docs/dev-guide/source_zh_cn/generic/` 下的文档，用 read_file 读取。

**示例 3：查扩展库**

用户问"stdx 里如何做 JSON 解析"。检索 `encoding.json` 或读取 `libs_stdx/libs_overview.md` 定位到 `encoding/json/json_package_overview.md`。

## Resources

- `paths.json`：技能固化的三个文档源路径（「执行前检查」四选一的落点，由 `skill_paths.py` 读写）
- `scripts/skill_paths.py`：路径的读取 / 检查 / 固化（`show` / `check` / `set` / `roots`）
- `scripts/find_docs.py`：全硬盘搜索文档源（四选一之 1）
- `scripts/clone_docs.py`：克隆三个源码仓并固化路径（四选一之 2）
- `references/doc-map.md`：文档地图（自动生成），三份文档的全部文件路径与标题索引
- `scripts/build_index.py`：重新扫描文档源、刷新 doc-map.md
- `scripts/search_docs.py`：在文档源中按关键词检索，返回命中文件与行号
