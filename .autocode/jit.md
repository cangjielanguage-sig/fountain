仓颉JIT
---

## 前置任务
加载技能using-git-worktrees，创建新的worktree

## 模块定义
在fountain项目下面创建两个新的文件夹`f_jit`作为本项目新的仓颉模块。

## 任务
0. 加载技能 using-superpowers、cangjie-doc-lookup、cangjie-architecture-design-harness、
1. 把`./docs/jit/*.md`移到`f_jit/doc`
2. 为m1 m2 m3三篇文档生成三份详细设计文档：`f_jit/doc/design-m1.md` `f_jit/doc/design-m2.md` `f_jit/doc/design-m3.md`。
   - 在文档中添加包级定义、各包的意义与依赖关系
   - 每个包的顶级声明与各顶级声明的意义和依赖关系
   - 添加每个顶级声明的公共成员声明与它们的意义和调用关系
3. 为每篇详细设计文档各生成一篇详细开发计划
   - 以每个公共成员声明为粒度，生成详细的 TDD 开发计划