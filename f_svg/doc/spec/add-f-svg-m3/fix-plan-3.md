# add-f-svg-m3 终验修复计划（第三轮）

> 依据：`verify-report-3.md`（CRITICAL=0，新增 4 条 WARNING）。
> 纪律：每项先写失败用例（Red），确认失败原因正确，再写最小实现（Green），`cjpm test` 全绿后独立提交。
> 分支：`feature/f_svg`。

## 1. WARNING（本轮修复）

### NEW-W1. 自交场景未按新规格做 64× 逐像素比较

**问题**：C6 的两个“自交”Scenario 只断言中心像素 / 总面积，未按规格对 64× 参考图做逐像素 ≤ 2/255 比较，但 §2.2 记为通过。

**要求**：为五角星（nonzero / evenodd）与甜甜圈补充 64× 参考图逐像素比较，最大通道差 ≤ 2/255；保留面积断言。

**用例**：两个新用例，失败时能指出最大差与像素坐标。

### NEW-W3. guard 的循环 / 深度 warning 缺少定位信息

**问题**：`SvgRenderGuard` 产生的循环与深度 warning 没有元素 id 或路径，违反 `svg-security` 的“每条 warning 含可定位信息”。

**要求**：guard 的循环 / 超深 warning 附带触发引用的元素路径（`/svg[1]/...`）或引用名（如 `url(#p)`）。

**用例**：自引用 pattern / marker 的 warning 断言包含 `/svg[1]/` 或 `#p`。

### NEW-W4. `SvgPatternSampler.sample` 跨调用复用首次 provider

**问题**：sampler 实例缓存了首次 `options.images`，后续调用传入不同 provider 不生效；公开 API 语义错误。

**要求**：`sample` 每次按传入 `options.images` 解析资源；缓存只用于同一 `render` 内的 `href` 去重，不得跨调用复用 provider。

**用例**：同一 sampler 连续两次 `sample`，分别传入返回红/蓝的 provider → 输出颜色各自正确；同一 provider 内同一 `href` 只调用一次。

## 2. 记录不改

- W6 `linearRGB` 常量色近似；
- W8 marker `href` 属性/内容继承；
- W15/W16 剩余覆盖缺口；
- W18 `SvgPatternSampler.sample` 的 `transform` 参数语义；
- SUGGESTION 未处理项。

## 3. 完成标准

- NEW-W1、NEW-W3、NEW-W4 落地并有对应用例；
- `cjpm test` 全绿（≥ 525 条），`f_svg` 自身 0 warning；
- M1/M2 逐字节基线仍通过；
- `verification.md` 追加第 8 节，结论 `CRITICAL=0`。
