# Proposal

## Why

时序图表达参与者之间的消息往返，是接口与流程文档的常用图。M10 提供参与者、生命线、消息与返回虚线。

## What Changes

- 新增 `SequenceChart`，`type` 为 `sequence`。
- 顶层 `participants: [{id,name}]` 与 `messages: [{from,to,text,type?,dashed?,note?}]`。
- 参与者水平排列，生命线向下；消息按顺序自上而下，返回消息用虚线。
- 校验参与者 id 唯一、消息端点存在。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增时序图需求。

## Impact

- 新增 `src/SequenceChart.cj`、`src/SequenceChart_test.cj`。
