# skill-generator 版本历史

## v2.0.0（2026-10-16）

### 融合
- 吸收「技能检查大师」（skill check master）的全部能力，技能从「只会写技能」变为「写得出、也发得出去」。
- 新增收口检查引擎：`scripts/release_engine.py` 加 8 个检查模块（版本 / 语法 / 安全 / 兼容性 / 冒烟 / 打包 / 同事模拟 / TRACE 评测）。
- 新增通用配置模板 `assets/release-config.json` 与单文件轻量版 `assets/release_check.py`。
- 新增收口参考文档 `references/release-check.md`。

### 修正
- `scripts/init_skill.py` 默认安装位置从 CodeBuddy 用户目录改为 WorkBuddy 用户目录 `~/.workbuddy/skills/`。
- 收口引擎的默认配置模板路径从 `templates/` 改为 `assets/`，与技能结构约定一致。

### 结构
- 引入版本号机制：`references/VERSION.txt` + 本文件，技能自身可被收口引擎检查。

## v1.0.0（导入版，日期不详）

- 由 Anthropic 的 `skill-creator`（Apache-2.0）与 superpowers 的 `writing-skills` 合并而来。
- 提供技能创作管线：脚手架初始化、结构校验、打包；以及 RED-GREEN-REFACTOR 式的技能测试纪律。
