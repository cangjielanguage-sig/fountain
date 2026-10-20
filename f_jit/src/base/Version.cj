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
package fountain::f_jit.base

/**
 * 字节码版本常量命名空间 —— design-m1 §2.3.11、plan-m1 S1.4。
 *
 * 数值权威 = `doc/jit-bytecode-m1.md` §11.6 容器头 `.fbc`：
 *
 * ```
 * off  size 字段
 * 0    4    magic       "FBC1"
 * 4    2    verMajor    1
 * 6    2    verMinor    14（v0.18.25）
 * 12   4    hdrSize     36（v0.18.25 起；旧单元 32）
 * ```
 *
 * **写方与读方共用同一份定义**（plan-m1 S1.4「与 `.fbc` 读写两侧共用同一份定义」）：`FbcWriter`
 * （S2.12）与 `FbcReader`（S2.13）都只引用这里的常量，避免两侧版本口径漂移。
 *
 * `MAGIC` 取 u32 形态是因为头里 magic 是定长 4 字节数值字段；按 §11.2「显式小端」
 * 编码后得到的字节序列正好是 ASCII `FBC1`（`0x31434246` LE = `46 42 43 31`）。
 * `MAGIC_TEXT` 是同一常量的文本形态，供诊断 / 断言直接比对。
 */
public class Version {
    /**
     * M1 产物的 `verMajor`（§11.6）。
     *
     * **legacy 常量**：M1 的写入/读取路径仍只引用它，M2 不得改写它来表达新版本
     * （spec「legacy 常量与 M1 路径不变」）。
     */
    public static const MAJOR: UInt16 = 1u16

    // ---------------- M2 多版本常量（design-m2 §2.1、spec「版本常量」） ----------------

    /** M1 主版本的显式命名（值与 legacy `MAJOR` 相同）。 */
    public static const M1_MAJOR: UInt16 = 1u16

    /** M2 主版本。 */
    public static const M2_MAJOR: UInt16 = 2u16

    /** M2 次版本（M2 产物从 0 起算）。 */
    public static const M2_MINOR: UInt16 = 0u16

    /** M3 主版本（M3 规则集已落地：LocalType 合法集 0–19）。 */
    public static const M3_MAJOR: UInt16 = 3u16

    /**
     * 本加载器**已实现**的 `verMajor` 集合：v1（M1）、v2（M2）、v3（M3）。
     *
     * 三者均有已实现规则集；v3 的合法 LocalType 集为 0–19（15=Any、16–19=JSON 谱系）。
     * 每次返回新数组，避免调用方修改共享实例。
     */
    public static func supportedMajors(): Array<UInt16> {
        [M1_MAJOR, M2_MAJOR, M3_MAJOR]
    }

    /** 本实现写出的 `verMinor` = 14（v0.18.25；加载器接受 ≤ 自身版本的 verMinor，§11.6）。 */
    public static const MINOR: UInt16 = 14u16

    /** 新布局头长度（magic 之后的部分）；`payload = 4 + HDR_SIZE`；旧单元为 32，走兼容分支。 */
    public static const HDR_SIZE: UInt32 = 36u32

    /** 容器 magic 的 u32 形态：按 LE 写出即 "FBC1" 四字节（见类注释）。 */
    public static const MAGIC: UInt32 = 0x31434246u32

    /** 容器 magic 的文本形态（§11.6 表中写作 `"FBC1"`）。 */
    public static const MAGIC_TEXT: String = 'FBC1'
}
