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
package fountain::f_rule.agenda

/**
 * 激活汇：Rete 终端只依赖该接口，不直接依赖议程实现（`doc/04-rete-network.md` §12）。
 *
 * 声明在 `agenda` 包而不是 `rete` 包：议程本身就是汇的生产者，`rete` 依赖 `agenda`
 * 才能把激活交给下游。放在 `rete` 会让两个包互相依赖。
 */
public interface ActivationSink {
    func add(activation: Activation): Unit
    func remove(activation: Activation): Unit
}
