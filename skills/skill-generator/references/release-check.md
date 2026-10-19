# 收口检查参考

技能写完之后、分发之前的那一段工作，叫「收口」。这份文档是收口引擎的完整说明：什么时候用、每一步查什么、失败了怎么改。

引擎是纯标准库 Python（>= 3.8），跨 macOS / Windows / Linux 可用，无外部依赖。

## 一、两条使用路径

| 路径 | 做法 | 适合 |
| --- | --- | --- |
| 独立引擎 | 用本技能的 `scripts/release_engine.py` 检查任意技能目录 | 手上技能多，希望统一质量门禁 |
| 轻量脚本 | 把 `assets/release_check.py` 复制进目标技能的 `scripts/` | 目标技能要能自给自足、离网可用 |

轻量脚本把配置写死在文件顶部的配置区，只跑版本 / 语法 / 安全 / 兼容性 / 打包五项。

## 二、五阶段十二步

```
第一阶段 静态检查
  1 版本号一致性     2 文件完整性     3 代码语法
  4 安全检查         5 合理性检查
  ── 检查点 A：全部通过才继续 ──

第二阶段 兼容性验证
  6 跨平台兼容（操作系统 / 平台 / 依赖最小化）
  ── 检查点 B：全部通过才继续 ──

第三阶段 动态验证
  7 功能冒烟测试
  ── 检查点 C：全部通过才继续 ──

第四阶段 打包与外部验证
  8 全新打包（禁止增量更新）
  9 同事审查模拟（换外部视角重看一遍）
  10 TRACE 五维评测
  ── 检查点 D：全部通过才可分发 ──

第五阶段 收尾归档
  11 记忆更新      12 资产索引同步
```

第五阶段是流程性的，不由脚本执行：把这次收口发现的问题写进项目记忆，把新技能登记进资产索引。

## 三、八个检查模块

引擎按 `--step` 调用模块，每个模块暴露 `run(skill_path, config) -> dict`，返回 `status` 为 `PASS` / `FAIL` / `SKIP` / `ERROR`。

### 1. version_check — 版本号一致性

读 `version_file` 拿到版本串，用 `pattern` 生成期望串（`{VERSION}` 会被替换），再要求 `files_to_check` 里每个文件都含这个期望串。

失败典型：改了 SKILL.md 忘了改 CHANGELOG，或者版本号是 `1.0.0` 但文件里写的是 `v1.0.0` 而 `pattern` 期望另一种形状。

### 2. syntax_check — 代码语法

对 `glob` 匹配到的每个 Python 文件跑 `py_compile`。没有任何匹配文件直接判 FAIL，防止写完配置却漏了脚本目录。

### 3. security_check — 安全检查

逐条跑 `checks` 里的规则，每条形如 `pattern` + `glob` + `expected_count`。内置四条：

| 规则 | 做法 |
| --- | --- |
| `bare_except` | 裸 `except:` 出现次数须为 0 |
| `hardcoded_secret` | 硬编码密钥出现次数须为 0，`exclude_empty` 放行空字符串占位 |
| `eval_exec` | `eval` / `exec` 词出现次数须为 0 |
| `rm_rf` | 递归强删命令出现次数须为 0 |

模块会跳过注释行、docstring 行，以及含「in content」「in line」的行——那类行是检查代码自身在描述规则，不是违规。

### 4. compatibility_check — 兼容性

三组判据：

- **os_compat 规则组**。除 `pattern` / `glob` / `expected_count` 外还支持 `must_have`（该行必须出现某子串，例如 `open(` 必须带 `encoding=`）与 `allow_list`（命中即放行，例如命令行里出现 `python3`）。
- **platform_compat**。`ascii_filenames` 要求文件名全 ASCII；`skill_md_in_root` 要求 `SKILL.md` 在技能根目录；`no_nested_root` 禁止多套一层同名根目录。
- **dependency_check**。`core_zero_deps` 指定核心脚本，其导入必须落在 `allowed_imports` 白名单内，保证核心功能零外部依赖；`optional_deps_try_wrap` 要求可选依赖的导入被 try 包裹。

### 5. smoke_test — 冒烟测试

按 `tests` 逐条在技能目录下执行 `command`（shell 执行，超时 30 秒），要求输出含 `expect_contains`，且返回码等于 `expect_returncode`（默认 0）。

用例应当包含边界输入，不能只测顺路的情况。

### 6. zip_pack — 打包

先删掉同名旧包再全新打包（禁止增量更新，否则会残留上一次的文件），排除规则由 `exclude_patterns` 给出。打包后回读 zip 校验：`SKILL.md` 是否在根、文件名是否全 ASCII、包体大小。

打包器视角差异：`scripts/zip_pack.py` 把内容平铺到 zip 根；技能另有 `scripts/package_skill.py`，会保留技能目录名一层。以目标平台的要求为准。

### 7. colleague_sim — 同事审查模拟

把自己当成第一次拿到包的外部同事：解压 zip 到临时目录，再查三件事。

- **zip_extract**：能否正常解压、解出多少文件。
- **file_purity**：包内文件是否含配置里列出的禁用词。禁用词清单只存放在配置文件的 `forbidden_keywords`，本文档不复述，避免自身被判定为污染。
- **secret_scan**：包内是否出现硬编码密钥。`intent_boundary` 是给带意图路由的技能预留的扩展位，没有路由脚本的技能设 `false` 即可。

找不到 zip 时直接判 FAIL，提示先跑打包步骤——这是依赖顺序问题，不是内容问题。

### 8. trace_eval — TRACE 五维评测

按 SkillHub 的 TRACE 体系自评，每维 0–5 分，取算术平均。

| 维度 | 关注 | 检查项 |
| --- | --- | --- |
| Trust 信任 | 不外流数据、不留密钥、历史干净 | 无数据回流痕迹、无密钥、变更记录不含数据回流条目 |
| Reliability 可靠 | 核心零依赖、有错误处理、能优雅降级 | 核心脚本导入白名单内、无裸 except、有 try/except 兜底 |
| Adaptability 适应 | 换机器换平台可用 | 多安装方式、跨平台扫描通过、文件名 ASCII、路径动态推导 |
| Convention 规范 | 版本与文档同步、流程可复现 | 版本号同步、SKILL.md 与 INSTALL.md 齐备、走完发布流程 |
| Effectiveness 有效 | 目标对得上、能力说清了 | SKILL.md 完整、意图路由可识别、知识资产存在 |

平均分 >= 4.5 判 PASS，4.8 以上记「卓越」。低于 4.5 会列出扣分项，改完重跑。

## 四、分步执行与报告

```bash
# 全部十二步
python3 scripts/release_engine.py --skill-path <技能目录>

# 只跑指定几步
python3 scripts/release_engine.py --skill-path <技能目录> --step version,syntax,security

# 输出 JSON 报告，便于接入别处
python3 scripts/release_engine.py --skill-path <技能目录> --output report.json
```

`--step` 可用的值：`version`、`syntax`、`security`、`compat`、`smoke`、`zip`、`colleague`、`trace`、`all`。

退出码 0 表示全过，1 表示有失败项。

报告里四种标记：通过、失败、错误（模块自身异常）、跳过（该项被禁用）。

## 五、没写配置文件会怎样

目标技能根目录没有 `.release-config.json` 时，引擎回落到本技能的 `assets/release-config.json` 模板，只把 `name` 换成目标目录名，并打印提示。这条路能跑，但冒烟用例和依赖白名单都是模板里的占位值，结果不可信——**先写配置，再收口**。

## 六、常见失败与修法

| 现象 | 根因 | 修法 |
| --- | --- | --- |
| `未找到 Python 文件` | `syntax_check.glob` 与实际目录不符 | 改成实际路径，例如 `src/*.py` |
| `发现 N 处 (期望 0)` 且指到检查模块自身 | 检查模块在描述规则，被当成违规 | 无需修；引擎已按文件名与行内容豁免。若自定义规则踩到，把它写进注释或改写措辞 |
| 乱码 / 非 ASCII 文件名 | 目录里有中文名文件 | 重命名。中文名在 Windows 解压时容易乱码，入包文件名必须 ASCII |
| 包体明显偏大 | 旧文件混入 | 引擎已先行删包；再确认 `exclude_patterns` 覆盖到了临时目录与缓存 |
| TRACE 规范维扣分 | 缺 `INSTALL.md` 或版本号不同步 | 补文档、对齐版本号后重跑 |
| 冒烟测试超时 | 用例里有等待或联网 | 超时上限 30 秒，用例应只做本地快速自检 |

## 七、自我收口的闭环

本技能自己也能被收口：

```bash
python3 scripts/release_engine.py --skill-path .
```

这一步值得进 CI 或提交流程——技能是发给别人用的代码，收口就是它的出厂检验。
