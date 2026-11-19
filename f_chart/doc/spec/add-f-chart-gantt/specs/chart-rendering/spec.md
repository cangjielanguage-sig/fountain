# Spec Delta

## ADDED Requirements

### Requirement: 甘特任务条

`GanttChart` SHALL 按 `start` / `end` 把每个任务画成时间轴上的一条水平条，并在左侧显示任务名。

#### Scenario: 两个任务

- **WHEN** `tasks` 含 2 个任务
- **THEN** 输出 2 个 `class="gantt-bar"` 与 2 个 `class="task-label"`

### Requirement: 进度

`progress` 为 0–1 时 MUST 在任务条上叠加 `class="progress"` 的子条。

#### Scenario: 半程进度

- **WHEN** 某任务 `progress` 为 0.5
- **THEN** 输出包含 1 个 `class="progress"`

### Requirement: 依赖

`dependsOn` 中的 id MUST 解析为其他任务，并绘制 `class="dependency"` 的折线。

#### Scenario: 依赖线

- **WHEN** 任务 B 依赖任务 A
- **THEN** 输出包含 1 条 `class="dependency"`

#### Scenario: 悬空依赖

- **WHEN** `dependsOn` 指向不存在的 id
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

### Requirement: 时间轴

`start` / `end` MUST 接受 `YYYY-MM-DD`；图表 SHALL 在 x 轴显示日期刻度。

#### Scenario: 日期刻度

- **WHEN** 任务跨越 2026-01
- **THEN** x 轴标签包含 `2026-01`
