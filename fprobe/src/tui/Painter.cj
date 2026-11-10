/*
Copyright (c) 2026 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
package fountain::fprobe.tui

/**
 * 终端绘制薄层的抽象。
 *
 * `RenderLoop` 只依赖该接口：用例注入假 painter 即可断言「resident 不初始化
 * TUI」「渲染慢不影响拉取」，无需真实终端。
 */
public interface Painter {
    func start(): Unit

    func draw(plan: RenderPlan): Unit

    func restore(): Unit

    /** 当前视口高度；未知或非交互时返回 0。 */
    func viewportHeight(): Int64
}

/** 按键来源抽象；生产实现由终端薄层提供，用例可注入脚本化按键。 */
public interface KeySource {
    func readKey(timeoutMs: Int64): ?UiKey
}
