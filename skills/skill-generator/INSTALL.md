# skill-generator 安装说明

## 一、把本技能装上

### 方式 A：从 fountain 仓库安装（推荐）

```bash
python3 <fountain>/skills/fountain-developer/scripts/install_skill.py skill-generator
```

### 方式 B：手动复制

```bash
mkdir -p ~/.workbuddy/skills
cp -r <fountain>/skills/skill-generator ~/.workbuddy/skills/
```

安装位置只应是 `~/.workbuddy/skills/`。WorkBuddy 与 CodeBuddy 是两个独立产品，技能目录互不共享，不要写到 CodeBuddy 的用户目录下。

### 方式 C：导入 zip 包

WorkBuddy 的 Skill 管理里选择「导入 Skill」，选中打包出来的 `skill-generator.zip`。

## 二、验证安装

```bash
python3 ~/.workbuddy/skills/skill-generator/scripts/release_engine.py --help
```

看到 `--skill-path` 等参数说明即安装成功。技能装好后需要重启 WorkBuddy，新技能才会进入技能清单。

## 三、给已有技能加上收口能力

### 方式一：独立引擎（一次安装，检查任意技能）

```bash
# 1. 复制配置模板到目标技能根目录，改名为 .release-config.json
cp ~/.workbuddy/skills/skill-generator/assets/release-config.json \
   ~/.workbuddy/skills/你的技能/.release-config.json

# 2. 编辑配置：至少改 name，并把 smoke_test.tests 换成你自己脚本的自检命令
# 3. 运行收口
python3 ~/.workbuddy/skills/skill-generator/scripts/release_engine.py \
  --skill-path ~/.workbuddy/skills/你的技能
```

### 方式二：轻量脚本（把检查能力嵌进目标技能，自给自足）

```bash
cp ~/.workbuddy/skills/skill-generator/assets/release_check.py \
   ~/.workbuddy/skills/你的技能/scripts/

cd ~/.workbuddy/skills/你的技能
python3 scripts/release_check.py
```

轻量版把配置写死在文件顶部的「配置区」，只覆盖版本 / 语法 / 安全 / 兼容性 / 打包五项，不读 `.release-config.json`，也不做同事模拟与 TRACE 评测。

## 四、配置项速查

`.release-config.json` 放在目标技能根目录，逐项控制检查行为。

| 字段 | 说明 |
| --- | --- |
| `name` | 技能名，决定 zip 文件名 |
| `version_file` | 版本号文件，默认 `references/VERSION.txt` |
| `syntax_check.glob` | 参与语法编译的脚本，默认 `scripts/*.py` |
| `security_check.checks` | 安全规则，每项含 `pattern` / `glob` / `expected_count` |
| `compatibility_check.os_compat` | 跨平台规则，另含 `must_have`（必须出现）、`allow_list`（放行） |
| `smoke_test.tests` | 冒烟用例，每项含 `name` / `command` / `expect_contains` |
| `zip_pack` | 打包配置，`require_skill_md_root` 控制 SKILL.md 是否必须在 zip 根 |
| `colleague_sim` | 外部视角模拟，含纯净性禁用词与密钥扫描 |
| `trace_eval` | TRACE 五维权重与检查项 |
| `lessons` | 经验条目，供人或智能体阅读，不参与判定 |

每个顶层检查项都可以写 `"enabled": false` 跳过。

## 五、常见问题

**Q：收口引擎需要给自己收口吗？**
可以，而且应该。本技能根目录就有 `.release-config.json`：

```bash
python3 ~/.workbuddy/skills/skill-generator/scripts/release_engine.py \
  --skill-path ~/.workbuddy/skills/skill-generator
```

**Q：检查报告里出现「找不到打包文件」怎么办？**
同事模拟依赖 zip 包。先跑包含 `zip` 的步骤，或者用 `--step zip,colleague` 单独跑这两步。

**Q：冒烟测试可以关掉吗？**
可以，把 `smoke_test.enabled` 设为 `false`。但冒烟测试是唯一在真机环境里跑过你脚本的环节，关掉等于放弃动态验证。

**Q：打包出来后 SKILL.md 不在 zip 根目录？**
本技能附带的两个打包器视角不同：`scripts/package_skill.py` 会保留技能目录名一层，`scripts/zip_pack.py` 把内容平铺到 zip 根。以目标平台的要求为准。
