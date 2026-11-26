# Tasks

## 1. 复现缺陷（Red）

- [x] 1.1 新增 `f_util/src/TextTemplateCacheKey_test.cj`，覆盖「同一模板串先 `prefix: "{", suffix: "}"` 后默认 `${`/`}`」与反向顺序两个场景，断言各自输出符合自己的分隔符语义。验证：`cjpm test f_util` 中这两条失败（当前缓存串味）。
- [x] 1.2 同文件补「相同模板 + 相同分隔符重复编译输出一致」「默认 `${name}` 替换」「`placeholder` 重载同串前后缀」三条。验证：修复前这三条通过，只有 1.1 的两条红。

## 2. 修复缓存键（Green）

- [x] 2.1 新增私有 `cacheKey(template, prefix, suffix)`，用长度前缀编码三元组，避免前缀/后缀与模板串拼接歧义。验证：1.1 的两条转绿。
- [x] 2.2 `compile` 两个重载统一用复合键查缓存；`computeIfAbsent` 的键改为复合键，`doCompile` 仍接收原始 `template` / `prefix` / `suffix`。验证：`cjpm test f_util` 全绿。

## 3. 回归与文档

- [x] 3.1 `f_util` 全量测试。验证：`cjpm test` 全绿，0 失败。
- [x] 3.2 `f_log` 全量测试（`{}` 前缀的主要调用方）。验证：`cjpm test` 全绿。
- [x] 3.3 检查 `f_util/README.md` / `README_en.md` 是否需要补缓存语义；不需要则记录「已检查，无变更」。验证：diff 为空或中英成对更新。

## Workflow follow-up

- 归档后用最终版覆盖 `f_util/doc/spec/fix-text-template-cache-key/` 四件套。
- 提交并合并回 `sts/1.3.x-LocalMode`，推送远端。
