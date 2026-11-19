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
package fountain::f_chart

import std.fs.{Directory, File, Path, exists}
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.json.*

/**
 * 图表样例画廊：每个里程碑用一份真实 JSON 渲染，并把 SVG 写入 `charts/`。
 *
 * 运行 `cd f_chart && cjpm test --skip-build` 后，`f_chart/charts` 下会生成
 * 107 个可直接用浏览器打开的 SVG 文件。
 */
@Test
public class ChartGallery_test {
    private func save(name: String, chart: Chart, json: String): Unit {
        let svg = chart.draw(JsonValue.fromStr(json).asObject())
        @Assert(svg.contains("<svg"))
        let directory = Path("charts")
        if (!exists(directory)) {
            Directory.create(directory, recursive: true)
        }
        File.writeTo(Path("charts/${name}.svg"), svg.toArray())
    }


    /** M1 柱状图 `bar`。 */
    @TestCase
    public func m001_bar(): Unit {
        save("M001-bar", BarChart(), """
{
  "type": "bar",
  "title": "月度销售额",
  "width": 800,
  "height": 480,
  "xAxis": { "type": "category", "title": "月份", "labels": ["1月", "2月", "3月", "4月", "5月", "6月"] },
  "yAxis": { "type": "linear", "title": "销售额（万元）", "min": 0, "grid": true },
  "legend": { "show": false },
  "series": [
    { "name": "销售额", "type": "bar", "data": [120, 200, 150, 180, 240, 210], "barWidth": 32 }
  ]
}
""")
    }


    /** M2 分组柱状图 `grouped-bar`。 */
    @TestCase
    public func m002_grouped_bar(): Unit {
        save("M002-grouped-bar", GroupedBarChart(), """
{
  "type": "grouped-bar",
  "title": "各季度产品销售额",
  "xAxis": { "type": "category", "labels": ["Q1", "Q2", "Q3", "Q4"] },
  "yAxis": { "type": "linear", "title": "万元", "min": 0 },
  "legend": { "show": true, "position": "top" },
  "series": [
    { "name": "产品 A", "data": [120, 150, 170, 160] },
    { "name": "产品 B", "data": [90, 110, 130, 140] },
    { "name": "产品 C", "data": [60, 70, 80, 95] }
  ]
}
""")
    }


    /** M3 堆叠柱状图 `stacked-bar`。 */
    @TestCase
    public func m003_stacked_bar(): Unit {
        save("M003-stacked-bar", StackedBarChart(), """
{
  "type": "stacked-bar",
  "title": "各区收入构成",
  "xAxis": { "type": "category", "labels": ["华东", "华南", "华北", "西部"] },
  "yAxis": { "type": "linear", "title": "万元", "min": 0 },
  "series": [
    { "name": "线上", "stack": "revenue", "data": [120, 90, 70, 50] },
    { "name": "门店", "stack": "revenue", "data": [80, 70, 60, 40] },
    { "name": "分销", "stack": "revenue", "data": [40, 35, 30, 25] }
  ]
}
""")
    }


    /** M4 百分比堆叠柱状图 `percent-stacked-bar`。 */
    @TestCase
    public func m004_percent_stacked_bar(): Unit {
        save("M004-percent-stacked-bar", PercentStackedBarChart(), """
{
  "type": "percent-stacked-bar",
  "title": "各渠道占比",
  "xAxis": { "type": "category", "labels": ["2024", "2025", "2026"] },
  "yAxis": { "type": "linear", "title": "占比", "min": 0, "max": 100, "labelFormat": "{value}%" },
  "series": [
    { "name": "线上", "stack": "share", "data": [45, 52, 60] },
    { "name": "门店", "stack": "share", "data": [35, 30, 25] },
    { "name": "分销", "stack": "share", "data": [20, 18, 15] }
  ]
}
""")
    }


    /** M5 折线图 `line`。 */
    @TestCase
    public func m005_line(): Unit {
        save("M005-line", LineChart(), """
{
  "type": "line",
  "title": "月活跃用户",
  "xAxis": { "type": "category", "labels": ["1月", "2月", "3月", "4月", "5月", "6月"] },
  "yAxis": { "type": "linear", "title": "万人", "min": 0 },
  "series": [
    { "name": "App", "data": [120, 132, 145, 160, 178, 190], "smooth": true, "symbol": "circle", "symbolSize": 6 },
    { "name": "Web", "data": [80, 78, 82, 85, 88, 92], "smooth": true, "symbol": "square", "symbolSize": 6 }
  ]
}
""")
    }


    /** M6 散点图 `scatter`。 */
    @TestCase
    public func m006_scatter(): Unit {
        save("M006-scatter", ScatterChart(), """
{
  "type": "scatter",
  "title": "身高与体重",
  "xAxis": { "type": "linear", "title": "身高（cm）" },
  "yAxis": { "type": "linear", "title": "体重（kg）" },
  "series": [
    {
      "name": "样本",
      "symbolSize": 8,
      "data": [
        { "x": 160, "y": 52 }, { "x": 165, "y": 56 }, { "x": 168, "y": 60 },
        { "x": 170, "y": 62 }, { "x": 172, "y": 65 }, { "x": 175, "y": 68 },
        { "x": 178, "y": 72 }, { "x": 180, "y": 75 }, { "x": 183, "y": 80 }
      ]
    }
  ]
}
""")
    }


    /** M7 组合图 `combo`。 */
    @TestCase
    public func m007_combo(): Unit {
        save("M007-combo", ComboChart(), """
{
  "type": "combo",
  "title": "销售额与增长率",
  "width": 900,
  "height": 480,
  "xAxis": { "type": "category", "labels": ["Q1", "Q2", "Q3", "Q4"] },
  "yAxis": { "type": "linear", "title": "销售额（万元）", "min": 0 },
  "yAxis2": { "type": "linear", "title": "增长率", "min": 0, "max": 50, "labelFormat": "{value}%" },
  "legend": { "show": true, "position": "top" },
  "series": [
    { "name": "产品 A", "type": "bar", "stack": "sales", "data": [120, 150, 170, 180] },
    { "name": "产品 B", "type": "bar", "stack": "sales", "data": [90, 110, 120, 130] },
    { "name": "增长率", "type": "line", "axis": "right", "smooth": true, "data": [8, 14, 18, 22] }
  ]
}
""")
    }


    /** M8 甘特图 `gantt`。 */
    @TestCase
    public func m008_gantt(): Unit {
        save("M008-gantt", GanttChart(), """
{
  "type": "gantt",
  "title": "项目进度",
  "width": 900,
  "height": 480,
  "xAxis": { "type": "time", "title": "日期" },
  "yAxis": { "type": "category", "labels": ["需求", "设计", "开发", "测试", "上线"] },
  "tasks": [
    { "id": "t1", "name": "需求调研", "start": "2026-01-05", "end": "2026-01-16", "progress": 1.0, "lane": "需求" },
    { "id": "t2", "name": "方案设计", "start": "2026-01-19", "end": "2026-02-06", "progress": 0.8, "dependsOn": ["t1"], "lane": "设计" },
    { "id": "t3", "name": "编码", "start": "2026-02-09", "end": "2026-03-20", "progress": 0.45, "dependsOn": ["t2"], "lane": "开发" },
    { "id": "t4", "name": "联调测试", "start": "2026-03-23", "end": "2026-04-10", "progress": 0.1, "dependsOn": ["t3"], "lane": "测试" },
    { "id": "t5", "name": "发布", "start": "2026-04-13", "end": "2026-04-17", "progress": 0, "dependsOn": ["t4"], "lane": "上线" }
  ]
}
""")
    }


    /** M9 流程图 `flowchart`。 */
    @TestCase
    public func m009_flowchart(): Unit {
        save("M009-flowchart", Flowchart(), """
{
  "type": "flowchart",
  "title": "订单处理流程",
  "width": 900,
  "height": 520,
  "layout": "vertical",
  "nodes": [
    { "id": "start", "label": "开始", "shape": "ellipse" },
    { "id": "create", "label": "创建订单", "shape": "rect" },
    { "id": "pay", "label": "已支付?", "shape": "diamond" },
    { "id": "ship", "label": "发货", "shape": "rect" },
    { "id": "cancel", "label": "取消订单", "shape": "rect" },
    { "id": "end", "label": "结束", "shape": "ellipse" }
  ],
  "edges": [
    { "source": "start", "target": "create" },
    { "source": "create", "target": "pay" },
    { "source": "pay", "target": "ship", "label": "是" },
    { "source": "pay", "target": "cancel", "label": "否" },
    { "source": "ship", "target": "end" },
    { "source": "cancel", "target": "end" }
  ]
}
""")
    }


    /** M10 时序图 `sequence`。 */
    @TestCase
    public func m010_sequence(): Unit {
        save("M010-sequence", SequenceChart(), """
{
  "type": "sequence",
  "title": "登录时序",
  "width": 900,
  "height": 520,
  "participants": [
    { "id": "user", "name": "用户" },
    { "id": "app", "name": "客户端" },
    { "id": "auth", "name": "认证服务" },
    { "id": "db", "name": "数据库" }
  ],
  "messages": [
    { "from": "user", "to": "app", "text": "输入账号密码", "type": "sync" },
    { "from": "app", "to": "auth", "text": "POST /login", "type": "sync" },
    { "from": "auth", "to": "db", "text": "查询用户", "type": "sync" },
    { "from": "db", "to": "auth", "text": "用户记录", "type": "return", "dashed": true },
    { "from": "auth", "to": "app", "text": "token", "type": "return", "dashed": true },
    { "from": "app", "to": "user", "text": "登录成功", "type": "async" }
  ]
}
""")
    }


    /** M11 条形图 `horizontal-bar`。 */
    @TestCase
    public func m011_horizontal_bar(): Unit {
        save("M011-horizontal-bar", HorizontalBarChart(), """
{
  "type": "horizontal-bar",
  "title": "各城市销售额",
  "width": 720,
  "height": 420,
  "xAxis": { "type": "linear", "title": "万元", "min": 0, "grid": true },
  "yAxis": { "type": "category", "labels": ["上海", "北京", "深圳", "广州", "杭州"] },
  "legend": { "show": false },
  "series": [
    { "name": "销售额", "data": [320, 290, 260, 210, 180], "barWidth": 24 }
  ]
}
""")
    }


    /** M12 点图 / 克利夫兰点图 `dot`。 */
    @TestCase
    public func m012_dot(): Unit {
        save("M012-dot", DotChart(), """
{
  "type": "dot",
  "title": "各科室满意度",
  "xAxis": { "type": "linear", "title": "满意度", "min": 0, "max": 100 },
  "yAxis": { "type": "category", "labels": ["内科", "外科", "儿科", "妇产科", "急诊"] },
  "legend": { "show": false },
  "series": [
    { "name": "满意度", "data": [88, 82, 91, 86, 79], "symbolSize": 10 }
  ]
}
""")
    }


    /** M13 雷达图 `radar`。 */
    @TestCase
    public func m013_radar(): Unit {
        save("M013-radar", RadarChart(), """
{
  "type": "radar",
  "title": "选手能力评估",
  "width": 600,
  "height": 600,
  "indicators": [
    { "name": "速度", "max": 100 },
    { "name": "力量", "max": 100 },
    { "name": "技巧", "max": 100 },
    { "name": "耐力", "max": 100 },
    { "name": "意识", "max": 100 }
  ],
  "series": [
    { "name": "选手 A", "data": [85, 70, 90, 75, 88] },
    { "name": "选手 B", "data": [70, 88, 65, 82, 72] }
  ]
}
""")
    }


    /** M14 面积图 `area`。 */
    @TestCase
    public func m014_area(): Unit {
        save("M014-area", AreaChart(), """
{
  "type": "area",
  "title": "累计注册用户",
  "xAxis": { "type": "category", "labels": ["1月", "2月", "3月", "4月", "5月", "6月"] },
  "yAxis": { "type": "linear", "title": "万人", "min": 0 },
  "series": [
    { "name": "注册用户", "data": [20, 45, 75, 110, 150, 195], "smooth": true, "areaStyle": { "opacity": 0.25 } }
  ]
}
""")
    }


    /** M15 堆叠面积图 `stacked-area`。 */
    @TestCase
    public func m015_stacked_area(): Unit {
        save("M015-stacked-area", StackedAreaChart(), """
{
  "type": "stacked-area",
  "title": "各端流量构成",
  "xAxis": { "type": "category", "labels": ["1月", "2月", "3月", "4月", "5月", "6月"] },
  "yAxis": { "type": "linear", "title": "万次", "min": 0 },
  "series": [
    { "name": "App", "stack": "traffic", "data": [120, 132, 145, 160, 178, 190], "areaStyle": { "opacity": 0.6 } },
    { "name": "Web", "stack": "traffic", "data": [80, 78, 82, 85, 88, 92], "areaStyle": { "opacity": 0.6 } },
    { "name": "小程序", "stack": "traffic", "data": [40, 48, 55, 62, 70, 80], "areaStyle": { "opacity": 0.6 } }
  ]
}
""")
    }


    /** M16 瀑布图 `waterfall`。 */
    @TestCase
    public func m016_waterfall(): Unit {
        save("M016-waterfall", WaterfallChart(), """
{
  "type": "waterfall",
  "title": "利润增减分解",
  "xAxis": { "type": "category", "labels": ["期初", "收入", "成本", "税费", "期末"] },
  "yAxis": { "type": "linear", "title": "万元", "min": 0 },
  "legend": { "show": false },
  "series": [
    {
      "name": "利润",
      "data": [
        { "name": "期初", "value": 120, "type": "total" },
        { "name": "收入", "value": 80, "type": "increase" },
        { "name": "成本", "value": -45, "type": "decrease" },
        { "name": "税费", "value": -15, "type": "decrease" },
        { "name": "期末", "value": 140, "type": "total" }
      ]
    }
  ]
}
""")
    }


    /** M17 直方图 `histogram`。 */
    @TestCase
    public func m017_histogram(): Unit {
        save("M017-histogram", HistogramChart(), """
{
  "type": "histogram",
  "title": "身高分布",
  "xAxis": { "type": "linear", "title": "身高（cm）" },
  "yAxis": { "type": "linear", "title": "频数", "min": 0 },
  "legend": { "show": false },
  "series": [
    {
      "name": "样本",
      "data": [162, 165, 168, 170, 171, 172, 173, 174, 175, 176, 178, 180, 182, 185, 168, 172, 174, 176, 169, 171],
      "bins": 8
    }
  ]
}
""")
    }


    /** M18 核密度图 / 密度图 `density`。 */
    @TestCase
    public func m018_density(): Unit {
        save("M018-density", DensityChart(), """
{
  "type": "density",
  "title": "收入分布",
  "xAxis": { "type": "linear", "title": "月收入（千元）" },
  "yAxis": { "type": "linear", "title": "密度", "min": 0 },
  "series": [
    { "name": "2025", "data": [8, 9, 10, 10, 11, 12, 13, 15, 16, 18, 20, 22, 25, 30], "bandwidth": 2.0, "fill": true },
    { "name": "2026", "data": [9, 10, 11, 12, 13, 14, 15, 17, 19, 21, 24, 27, 30, 35], "bandwidth": 2.0, "fill": false }
  ]
}
""")
    }


    /** M19 箱线图 `boxplot`。 */
    @TestCase
    public func m019_boxplot(): Unit {
        save("M019-boxplot", BoxPlotChart(), """
{
  "type": "boxplot",
  "title": "各班级成绩分布",
  "xAxis": { "type": "category", "labels": ["一班", "二班", "三班", "四班"] },
  "yAxis": { "type": "linear", "title": "分数", "min": 0, "max": 100 },
  "legend": { "show": false },
  "series": [
    {
      "name": "成绩",
      "data": [
        { "name": "一班", "min": 55, "q1": 68, "median": 76, "q3": 85, "max": 96, "outliers": [42, 98] },
        { "name": "二班", "min": 60, "q1": 70, "median": 78, "q3": 86, "max": 94, "outliers": [] },
        { "name": "三班", "min": 50, "q1": 62, "median": 70, "q3": 80, "max": 90, "outliers": [35] },
        { "name": "四班", "min": 58, "q1": 72, "median": 82, "q3": 90, "max": 99, "outliers": [] }
      ]
    }
  ]
}
""")
    }


    /** M20 小提琴图 `violin`。 */
    @TestCase
    public func m020_violin(): Unit {
        save("M020-violin", ViolinChart(), """
{
  "type": "violin",
  "title": "各渠道客单价分布",
  "xAxis": { "type": "category", "labels": ["搜索", "社交", "邮件", "直访"] },
  "yAxis": { "type": "linear", "title": "客单价（元）", "min": 0 },
  "legend": { "show": false },
  "series": [
    { "name": "客单价", "data": [[88, 92, 95, 99, 105], [110, 115, 120, 130, 150], [90, 96, 102, 108, 118], [85, 89, 94, 101, 112]], "bandwidth": 6.0, "showBox": true }
  ]
}
""")
    }


    /** M21 蜂群图 / 抖动图 `swarm`。 */
    @TestCase
    public func m021_swarm(): Unit {
        save("M021-swarm", SwarmChart(), """
{
  "type": "swarm",
  "title": "各组测量值",
  "xAxis": { "type": "category", "labels": ["对照组", "低剂量", "高剂量"] },
  "yAxis": { "type": "linear", "title": "测量值", "min": 0 },
  "series": [
    { "name": "测量值", "data": [[12, 14, 15, 18], [22, 25, 30, 33], [36, 38, 40, 41]], "jitter": 0.25, "side": "both" }
  ]
}
""")
    }


    /** M22 茎叶图 `stem-leaf`。 */
    @TestCase
    public func m022_stem_leaf(): Unit {
        save("M022-stem-leaf", StemLeafChart(), """
{
  "type": "stem-leaf",
  "title": "考试成绩茎叶图",
  "width": 600,
  "height": 520,
  "stemUnit": 10,
  "leafDigits": 1,
  "series": [
    { "name": "成绩", "data": [52, 55, 58, 61, 63, 63, 67, 70, 72, 75, 78, 81, 85, 88, 92, 96] }
  ]
}
""")
    }


    /** M23 QQ 图 `qq`。 */
    @TestCase
    public func m023_qq(): Unit {
        save("M023-qq", QQChart(), """
{
  "type": "qq",
  "title": "正态 QQ 图",
  "xAxis": { "type": "linear", "title": "理论分位数" },
  "yAxis": { "type": "linear", "title": "样本分位数" },
  "legend": { "show": false },
  "series": [
    { "name": "样本", "data": [12, 15, 18, 20, 22, 24, 26, 28, 31, 35, 40], "distribution": "normal", "showLine": true }
  ]
}
""")
    }


    /** M24 山脊图 `ridge`。 */
    @TestCase
    public func m024_ridge(): Unit {
        save("M024-ridge", RidgeChart(), """
{
  "type": "ridge",
  "title": "各年份收入分布",
  "xAxis": { "type": "linear", "title": "月收入（千元）" },
  "yAxis": { "type": "category", "labels": ["2023", "2024", "2025", "2026"] },
  "series": [
    { "name": "2023", "data": [6, 8, 9, 10, 11, 12, 14, 16, 18, 22], "overlap": 0.5 },
    { "name": "2024", "data": [7, 9, 10, 12, 13, 15, 17, 20, 23, 28], "overlap": 0.5 },
    { "name": "2025", "data": [8, 10, 12, 14, 16, 18, 21, 25, 30, 36], "overlap": 0.5 },
    { "name": "2026", "data": [10, 12, 15, 18, 21, 24, 28, 33, 40, 48], "overlap": 0.5 }
  ]
}
""")
    }


    /** M25 二维直方图 / 六边形分箱图 `2d-histogram`。 */
    @TestCase
    public func m025_2d_histogram(): Unit {
        save("M025-2d-histogram", Histogram2DChart(), """
{
  "type": "2d-histogram",
  "title": "身高体重联合分布",
  "xAxis": { "type": "linear", "title": "身高（cm）" },
  "yAxis": { "type": "linear", "title": "体重（kg）" },
  "legend": { "show": false },
  "series": [
    {
      "name": "样本",
      "bins": [12, 12],
      "shape": "hexagon",
      "data": [
        { "x": 165, "y": 58 }, { "x": 168, "y": 60 }, { "x": 170, "y": 62 },
        { "x": 172, "y": 65 }, { "x": 175, "y": 68 }, { "x": 178, "y": 72 },
        { "x": 180, "y": 75 }, { "x": 182, "y": 78 }, { "x": 168, "y": 55 }
      ]
    }
  ]
}
""")
    }


    /** M26 气泡图 `bubble`。 */
    @TestCase
    public func m026_bubble(): Unit {
        save("M026-bubble", BubbleChart(), """
{
  "type": "bubble",
  "title": "国家指标",
  "xAxis": { "type": "linear", "title": "人均 GDP" },
  "yAxis": { "type": "linear", "title": "预期寿命" },
  "series": [
    {
      "name": "国家",
      "sizeRange": [6, 34],
      "data": [
        { "x": 12000, "y": 72, "size": 40, "label": "A 国" },
        { "x": 25000, "y": 78, "size": 80, "label": "B 国" },
        { "x": 40000, "y": 82, "size": 120, "label": "C 国" },
        { "x": 60000, "y": 84, "size": 60, "label": "D 国" }
      ]
    }
  ]
}
""")
    }


    /** M27 相关矩阵图 `correlation-matrix`。 */
    @TestCase
    public func m027_correlation_matrix(): Unit {
        save("M027-correlation-matrix", CorrelationMatrixChart(), """
{
  "type": "correlation-matrix",
  "title": "变量相关性",
  "width": 640,
  "height": 640,
  "xAxis": { "type": "category", "labels": ["身高", "体重", "年龄", "收入"] },
  "yAxis": { "type": "category", "labels": ["身高", "体重", "年龄", "收入"] },
  "method": "pearson",
  "showValues": true,
  "series": [
    {
      "name": "相关系数",
      "data": [
        [1.00, 0.81, 0.12, 0.08],
        [0.81, 1.00, 0.18, 0.15],
        [0.12, 0.18, 1.00, 0.42],
        [0.08, 0.15, 0.42, 1.00]
      ]
    }
  ]
}
""")
    }


    /** M28 平行坐标图 `parallel-coordinates`。 */
    @TestCase
    public func m028_parallel_coordinates(): Unit {
        save("M028-parallel-coordinates", ParallelCoordinatesChart(), """
{
  "type": "parallel-coordinates",
  "title": "车型多指标对比",
  "width": 760,
  "height": 440,
  "dimensions": [
    { "name": "价格", "min": 0, "max": 60 },
    { "name": "油耗", "min": 0, "max": 20 },
    { "name": "马力", "min": 0, "max": 400 },
    { "name": "空间", "min": 0, "max": 10 }
  ],
  "series": [
    { "name": "轿车", "data": [[25, 7, 180, 6], [18, 6, 150, 5], [40, 9, 300, 7]] },
    { "name": "SUV", "data": [[35, 12, 250, 9], [50, 14, 350, 10]] }
  ]
}
""")
    }


    /** M29 等高线图 `contour`。 */
    @TestCase
    public func m029_contour(): Unit {
        save("M029-contour", ContourChart(), """
{
  "type": "contour",
  "title": "响应面",
  "xAxis": { "type": "linear", "title": "温度" },
  "yAxis": { "type": "linear", "title": "压力" },
  "legend": { "show": false },
  "levels": 8,
  "interpolate": "linear",
  "series": [
    {
      "name": "响应",
      "data": [
        { "x": 0, "y": 0, "value": 10 }, { "x": 1, "y": 0, "value": 14 }, { "x": 2, "y": 0, "value": 20 },
        { "x": 0, "y": 1, "value": 12 }, { "x": 1, "y": 1, "value": 18 }, { "x": 2, "y": 1, "value": 26 },
        { "x": 0, "y": 2, "value": 16 }, { "x": 1, "y": 2, "value": 24 }, { "x": 2, "y": 2, "value": 34 }
      ]
    }
  ]
}
""")
    }


    /** M30 散点矩阵图 `scatter-matrix`。 */
    @TestCase
    public func m030_scatter_matrix(): Unit {
        save("M030-scatter-matrix", ScatterMatrixChart(), """
{
  "type": "scatter-matrix",
  "title": "多变量两两关系",
  "width": 720,
  "height": 720,
  "variables": ["身高", "体重", "年龄"],
  "series": [
    {
      "name": "样本",
      "data": [
        [160, 52, 22], [165, 56, 25], [168, 60, 28],
        [170, 62, 31], [172, 65, 35], [175, 68, 38],
        [178, 72, 42], [180, 75, 45], [183, 80, 50]
      ]
    }
  ]
}
""")
    }


    /** M31 饼图 `pie`。 */
    @TestCase
    public func m031_pie(): Unit {
        save("M031-pie", PieChart(), """
{
  "type": "pie",
  "title": "市场份额",
  "width": 600,
  "height": 480,
  "startAngle": 0,
  "showPercent": true,
  "series": [
    {
      "name": "份额",
      "data": [
        { "name": "品牌 A", "value": 38 },
        { "name": "品牌 B", "value": 27 },
        { "name": "品牌 C", "value": 20 },
        { "name": "其他", "value": 15 }
      ]
    }
  ]
}
""")
    }


    /** M32 环形图 `donut`。 */
    @TestCase
    public func m032_donut(): Unit {
        save("M032-donut", DonutChart(), """
{
  "type": "donut",
  "title": "预算构成",
  "width": 600,
  "height": 480,
  "innerRadius": 0.55,
  "centerText": "总预算 100%",
  "series": [
    {
      "name": "预算",
      "data": [
        { "name": "研发", "value": 42 },
        { "name": "市场", "value": 28 },
        { "name": "运营", "value": 18 },
        { "name": "其他", "value": 12 }
      ]
    }
  ]
}
""")
    }


    /** M33 马赛克图 `mosaic`。 */
    @TestCase
    public func m033_mosaic(): Unit {
        save("M033-mosaic", MosaicChart(), """
{
  "type": "mosaic",
  "title": "地区与购买意愿",
  "width": 720,
  "height": 480,
  "xAxis": { "type": "category", "labels": ["华东", "华南", "华北", "西部"] },
  "series": [
    { "name": "购买", "data": [120, 90, 70, 50] },
    { "name": "未购买", "data": [80, 70, 60, 40] }
  ]
}
""")
    }


    /** M34 矩形树图 `treemap`。 */
    @TestCase
    public func m034_treemap(): Unit {
        save("M034-treemap", TreemapChart(), """
{
  "type": "treemap",
  "title": "磁盘占用",
  "width": 760,
  "height": 480,
  "tiling": "squarify",
  "nodes": [
    { "id": "root", "name": "根目录", "parent": null },
    { "id": "usr", "name": "usr", "parent": "root" },
    { "id": "var", "name": "var", "parent": "root" },
    { "id": "bin", "name": "bin", "parent": "usr", "value": 120 },
    { "id": "lib", "name": "lib", "parent": "usr", "value": 260 },
    { "id": "log", "name": "log", "parent": "var", "value": 90 },
    { "id": "cache", "name": "cache", "parent": "var", "value": 60 }
  ]
}
""")
    }


    /** M35 漏斗图 `funnel`。 */
    @TestCase
    public func m035_funnel(): Unit {
        save("M035-funnel", FunnelChart(), """
{
  "type": "funnel",
  "title": "注册转化",
  "width": 640,
  "height": 480,
  "gap": 2,
  "showConversion": true,
  "series": [
    {
      "name": "阶段",
      "data": [
        { "name": "访问", "value": 10000 },
        { "name": "注册", "value": 6200 },
        { "name": "激活", "value": 3800 },
        { "name": "付费", "value": 1200 }
      ]
    }
  ]
}
""")
    }


    /** M36 桑基图 `sankey`。 */
    @TestCase
    public func m036_sankey(): Unit {
        save("M036-sankey", SankeyChart(), """
{
  "type": "sankey",
  "title": "流量来源",
  "width": 760,
  "height": 480,
  "nodeWidth": 16,
  "nodeGap": 12,
  "nodes": [
    { "id": "search", "name": "搜索" },
    { "id": "social", "name": "社交" },
    { "id": "home", "name": "首页" },
    { "id": "detail", "name": "详情" },
    { "id": "cart", "name": "购物车" },
    { "id": "pay", "name": "支付" }
  ],
  "links": [
    { "source": "search", "target": "home", "value": 400 },
    { "source": "social", "target": "home", "value": 300 },
    { "source": "home", "target": "detail", "value": 550 },
    { "source": "detail", "target": "cart", "value": 260 },
    { "source": "cart", "target": "pay", "value": 180 }
  ]
}
""")
    }


    /** M37 帕累托图 `pareto`。 */
    @TestCase
    public func m037_pareto(): Unit {
        save("M037-pareto", ParetoChart(), """
{
  "type": "pareto",
  "title": "缺陷原因分析",
  "xAxis": { "type": "category", "labels": ["外观", "尺寸", "装配", "功能", "包装", "其他"] },
  "yAxis": { "type": "linear", "title": "缺陷数", "min": 0 },
  "showCumulative": true,
  "series": [
    { "name": "缺陷数", "data": [120, 80, 55, 30, 12, 8] }
  ]
}
""")
    }


    /** M38 控制图 `control`。 */
    @TestCase
    public func m038_control(): Unit {
        save("M038-control", ControlChart(), """
{
  "type": "control",
  "title": "过程控制图",
  "xAxis": { "type": "category", "labels": ["1", "2", "3", "4", "5", "6", "7", "8"] },
  "yAxis": { "type": "linear", "title": "测量值" },
  "legend": { "show": false },
  "series": [
    {
      "name": "测量值",
      "data": [50.2, 49.8, 50.5, 50.1, 51.2, 49.5, 50.0, 50.3],
      "center": 50.0,
      "ucl": 51.5,
      "lcl": 48.5
    }
  ]
}
""")
    }


    /** M39 误差线图 `error-bar`。 */
    @TestCase
    public func m039_error_bar(): Unit {
        save("M039-error-bar", ErrorBarChart(), """
{
  "type": "error-bar",
  "title": "各组均值与置信区间",
  "xAxis": { "type": "category", "labels": ["A", "B", "C", "D"] },
  "yAxis": { "type": "linear", "title": "均值", "min": 0 },
  "legend": { "show": false },
  "series": [
    {
      "name": "均值",
      "data": [
        { "x": "A", "y": 12.0, "low": 10.5, "high": 13.5 },
        { "x": "B", "y": 15.0, "low": 13.2, "high": 16.8 },
        { "x": "C", "y": 11.0, "low": 9.0, "high": 13.0 },
        { "x": "D", "y": 18.0, "low": 16.5, "high": 19.5 }
      ]
    }
  ]
}
""")
    }


    /** M40 残差图 `residual`。 */
    @TestCase
    public func m040_residual(): Unit {
        save("M040-residual", ResidualChart(), """
{
  "type": "residual",
  "title": "回归残差",
  "xAxis": { "type": "linear", "title": "拟合值" },
  "yAxis": { "type": "linear", "title": "残差" },
  "legend": { "show": false },
  "series": [
    {
      "name": "残差",
      "data": [
        { "x": 10, "y": 0.5 }, { "x": 12, "y": -1.2 }, { "x": 14, "y": 0.8 },
        { "x": 16, "y": -0.4 }, { "x": 18, "y": 1.1 }, { "x": 20, "y": -0.9 }
      ]
    }
  ]
}
""")
    }


    /** M41 杠杆图 / 影响图 `influence`。 */
    @TestCase
    public func m041_influence(): Unit {
        save("M041-influence", InfluenceChart(), """
{
  "type": "influence",
  "title": "杠杆与影响",
  "xAxis": { "type": "linear", "title": "杠杆值" },
  "yAxis": { "type": "linear", "title": "学生化残差" },
  "legend": { "show": false },
  "series": [
    {
      "name": "样本",
      "data": [
        { "x": 0.05, "y": 0.4, "cooksDistance": 0.02 },
        { "x": 0.08, "y": -1.1, "cooksDistance": 0.04 },
        { "x": 0.12, "y": 0.9, "cooksDistance": 0.06 },
        { "x": 0.20, "y": -2.0, "cooksDistance": 0.18 },
        { "x": 0.25, "y": 1.6, "cooksDistance": 0.12 }
      ]
    }
  ]
}
""")
    }


    /** M42 概率图 `probability`。 */
    @TestCase
    public func m042_probability(): Unit {
        save("M042-probability", ProbabilityChart(), """
{
  "type": "probability",
  "title": "正态概率图",
  "xAxis": { "type": "linear", "title": "理论分位数" },
  "yAxis": { "type": "linear", "title": "样本分位数" },
  "legend": { "show": false },
  "series": [
    { "name": "样本", "data": [12, 15, 18, 20, 22, 24, 26, 28, 31, 35, 40], "distribution": "normal", "showLine": true }
  ]
}
""")
    }


    /** M43 热力图 `heatmap`。 */
    @TestCase
    public func m043_heatmap(): Unit {
        save("M043-heatmap", HeatmapChart(), """
{
  "type": "heatmap",
  "title": "周活跃热力",
  "xAxis": { "type": "category", "labels": ["周一", "周二", "周三", "周四", "周五"] },
  "yAxis": { "type": "category", "labels": ["上午", "下午", "晚上"] },
  "colorRange": ["#e8f1fb", "#7fb3d5", "#1f4e79"],
  "showValues": true,
  "series": [
    {
      "name": "活跃度",
      "data": [
        [12, 18, 20, 17, 25],
        [22, 28, 30, 26, 35],
        [30, 36, 32, 28, 40]
      ]
    }
  ]
}
""")
    }


    /** M44 日历热力图 `calendar-heatmap`。 */
    @TestCase
    public func m044_calendar_heatmap(): Unit {
        save("M044-calendar-heatmap", CalendarHeatmapChart(), """
{
  "type": "calendar-heatmap",
  "title": "提交活跃度",
  "width": 900,
  "height": 220,
  "startDate": "2026-01-01",
  "endDate": "2026-03-31",
  "cellSize": 14,
  "weekStart": "mon",
  "colorRange": ["#ebedf0", "#9be9a8", "#40c463", "#216e39"],
  "series": [
    {
      "name": "提交数",
      "data": [
        { "date": "2026-01-05", "value": 2 },
        { "date": "2026-01-06", "value": 5 },
        { "date": "2026-01-12", "value": 8 },
        { "date": "2026-02-03", "value": 3 },
        { "date": "2026-02-04", "value": 12 },
        { "date": "2026-03-09", "value": 6 }
      ]
    }
  ]
}
""")
    }


    /** M45 箱线图 + 散点组合图 `box-scatter`。 */
    @TestCase
    public func m045_box_scatter(): Unit {
        save("M045-box-scatter", BoxScatterChart(), """
{
  "type": "box-scatter",
  "title": "分布与原始点",
  "xAxis": { "type": "category", "labels": ["A 组", "B 组", "C 组"] },
  "yAxis": { "type": "linear", "title": "测量值", "min": 0 },
  "series": [
    { "name": "测量值", "data": [12, 14, 15, 17, 19, 22, 25, 28, 31, 35], "showBox": true, "jitter": 0.2 }
  ]
}
""")
    }


    /** M46 小提琴 + 箱线组合图 `violin-box`。 */
    @TestCase
    public func m046_violin_box(): Unit {
        save("M046-violin-box", ViolinBoxChart(), """
{
  "type": "violin-box",
  "title": "分布、分位数与异常值",
  "xAxis": { "type": "category", "labels": ["A 组", "B 组", "C 组"] },
  "yAxis": { "type": "linear", "title": "测量值", "min": 0 },
  "series": [
    { "name": "测量值", "data": [11, 13, 14, 16, 18, 20, 23, 26, 30, 36, 45], "bandwidth": 4.0, "showBox": true, "showOutliers": true }
  ]
}
""")
    }


    /** M47 ROC 曲线 `roc`。 */
    @TestCase
    public func m047_roc(): Unit {
        save("M047-roc", RocChart(), """
{
  "type": "roc",
  "title": "ROC 曲线",
  "xAxis": { "type": "linear", "title": "假阳性率", "min": 0, "max": 1 },
  "yAxis": { "type": "linear", "title": "真阳性率", "min": 0, "max": 1 },
  "diagonal": true,
  "series": [
    {
      "name": "模型 A（AUC=0.86）",
      "auc": 0.86,
      "data": [
        { "x": 0.0, "y": 0.0 }, { "x": 0.1, "y": 0.45 }, { "x": 0.2, "y": 0.65 },
        { "x": 0.4, "y": 0.80 }, { "x": 0.6, "y": 0.90 }, { "x": 1.0, "y": 1.0 }
      ]
    }
  ]
}
""")
    }


    /** M48 PR 曲线 `pr`。 */
    @TestCase
    public func m048_pr(): Unit {
        save("M048-pr", PrChart(), """
{
  "type": "pr",
  "title": "PR 曲线",
  "xAxis": { "type": "linear", "title": "召回率", "min": 0, "max": 1 },
  "yAxis": { "type": "linear", "title": "精确率", "min": 0, "max": 1 },
  "baseline": 0.12,
  "series": [
    {
      "name": "模型 A（AP=0.72）",
      "ap": 0.72,
      "data": [
        { "x": 0.0, "y": 1.0 }, { "x": 0.2, "y": 0.92 }, { "x": 0.4, "y": 0.81 },
        { "x": 0.6, "y": 0.68 }, { "x": 0.8, "y": 0.45 }, { "x": 1.0, "y": 0.12 }
      ]
    }
  ]
}
""")
    }


    /** M49 生存曲线 / Kaplan-Meier 图 `survival`。 */
    @TestCase
    public func m049_survival(): Unit {
        save("M049-survival", SurvivalChart(), """
{
  "type": "survival",
  "title": "Kaplan-Meier 生存曲线",
  "xAxis": { "type": "linear", "title": "时间（月）", "min": 0 },
  "yAxis": { "type": "linear", "title": "生存率", "min": 0, "max": 1 },
  "confidence": false,
  "series": [
    {
      "name": "治疗组",
      "data": [
        { "time": 0, "survival": 1.0 }, { "time": 6, "survival": 0.92 },
        { "time": 12, "survival": 0.80 }, { "time": 18, "survival": 0.70, "censored": true },
        { "time": 24, "survival": 0.62 }
      ]
    },
    {
      "name": "对照组",
      "data": [
        { "time": 0, "survival": 1.0 }, { "time": 6, "survival": 0.85 },
        { "time": 12, "survival": 0.68 }, { "time": 18, "survival": 0.55 },
        { "time": 24, "survival": 0.40 }
      ]
    }
  ]
}
""")
    }


    /** M50 森林图 `forest`。 */
    @TestCase
    public func m050_forest(): Unit {
        save("M050-forest", ForestChart(), """
{
  "type": "forest",
  "title": "效应量汇总",
  "width": 720,
  "height": 480,
  "nullLine": 1,
  "xAxis": { "type": "log", "title": "OR（95% CI）", "min": 0.1, "max": 10 },
  "yAxis": { "type": "category", "labels": ["研究 A", "研究 B", "研究 C", "合并"] },
  "series": [
    {
      "name": "OR",
      "data": [
        { "label": "研究 A", "estimate": 0.8, "lower": 0.5, "upper": 1.3, "weight": 30 },
        { "label": "研究 B", "estimate": 1.5, "lower": 1.1, "upper": 2.1, "weight": 45 },
        { "label": "研究 C", "estimate": 1.1, "lower": 0.7, "upper": 1.8, "weight": 25 },
        { "label": "合并", "estimate": 1.2, "lower": 0.95, "upper": 1.5, "weight": 100 }
      ]
    }
  ]
}
""")
    }


    /** M51 列线图 `nomogram`。 */
    @TestCase
    public func m051_nomogram(): Unit {
        save("M051-nomogram", NomogramChart(), """
{
  "type": "nomogram",
  "title": "风险预测列线图",
  "width": 760,
  "height": 420,
  "variables": [
    { "name": "年龄", "range": [20, 80], "points": [0, 100] },
    { "name": "血压", "range": [90, 180], "points": [0, 80] },
    { "name": "BMI", "range": [18, 35], "points": [0, 60] }
  ],
  "totalPoints": [0, 240],
  "risk": [
    { "points": 0, "probability": 0.02 },
    { "points": 80, "probability": 0.15 },
    { "points": 160, "probability": 0.45 },
    { "points": 240, "probability": 0.80 }
  ]
}
""")
    }


    /** M52 火焰图 `flame`。 */
    @TestCase
    public func m052_flame(): Unit {
        save("M052-flame", FlameChart(), """
{
  "type": "flame",
  "title": "CPU 火焰图",
  "width": 900,
  "height": 480,
  "orientation": "bottom-up",
  "colorBy": "name",
  "nodes": [
    { "id": "root", "name": "main", "parent": null, "value": 100 },
    { "id": "parse", "name": "parse", "parent": "root", "value": 40 },
    { "id": "render", "name": "render", "parent": "root", "value": 60 },
    { "id": "lex", "name": "lex", "parent": "parse", "value": 25 },
    { "id": "ast", "name": "ast", "parent": "parse", "value": 15 },
    { "id": "layout", "name": "layout", "parent": "render", "value": 35 },
    { "id": "paint", "name": "paint", "parent": "render", "value": 25 }
  ]
}
""")
    }


    /** M53 冰柱图 `icicle`。 */
    @TestCase
    public func m053_icicle(): Unit {
        save("M053-icicle", IcicleChart(), """
{
  "type": "icicle",
  "title": "调用栈冰柱图",
  "width": 900,
  "height": 480,
  "orientation": "top-down",
  "colorBy": "name",
  "nodes": [
    { "id": "root", "name": "main", "parent": null, "value": 100 },
    { "id": "parse", "name": "parse", "parent": "root", "value": 40 },
    { "id": "render", "name": "render", "parent": "root", "value": 60 },
    { "id": "lex", "name": "lex", "parent": "parse", "value": 25 },
    { "id": "ast", "name": "ast", "parent": "parse", "value": 15 },
    { "id": "layout", "name": "layout", "parent": "render", "value": 35 },
    { "id": "paint", "name": "paint", "parent": "render", "value": 25 }
  ]
}
""")
    }


    /** M54 差分火焰图 `differential-flame`。 */
    @TestCase
    public func m054_differential_flame(): Unit {
        save("M054-differential-flame", DifferentialFlameChart(), """
{
  "type": "differential-flame",
  "title": "版本差异",
  "width": 900,
  "height": 480,
  "nodes": [
    { "id": "root", "name": "main", "parent": null, "value1": 100, "value2": 120 },
    { "id": "parse", "name": "parse", "parent": "root", "value1": 40, "value2": 30 },
    { "id": "render", "name": "render", "parent": "root", "value1": 60, "value2": 90 },
    { "id": "lex", "name": "lex", "parent": "parse", "value1": 25, "value2": 20 },
    { "id": "layout", "name": "layout", "parent": "render", "value1": 35, "value2": 55 },
    { "id": "paint", "name": "paint", "parent": "render", "value1": 25, "value2": 35 }
  ]
}
""")
    }


    /** M55 离线火焰图 `offline-flame`。 */
    @TestCase
    public func m055_offline_flame(): Unit {
        save("M055-offline-flame", OfflineFlameChart(), """
{
  "type": "offline-flame",
  "title": "render 子树",
  "width": 900,
  "height": 480,
  "root": "render",
  "maxDepth": 4,
  "nodes": [
    { "id": "root", "name": "main", "parent": null, "value": 100 },
    { "id": "parse", "name": "parse", "parent": "root", "value": 40 },
    { "id": "render", "name": "render", "parent": "root", "value": 60 },
    { "id": "layout", "name": "layout", "parent": "render", "value": 35 },
    { "id": "paint", "name": "paint", "parent": "render", "value": 25 },
    { "id": "text", "name": "text", "parent": "layout", "value": 20 },
    { "id": "image", "name": "image", "parent": "layout", "value": 15 }
  ]
}
""")
    }


    /** M56 热火焰图 `heat-flame`。 */
    @TestCase
    public func m056_heat_flame(): Unit {
        save("M056-heat-flame", HeatFlameChart(), """
{
  "type": "heat-flame",
  "title": "CPU 热点",
  "width": 900,
  "height": 480,
  "heatField": "self",
  "colorRange": ["#ffffcc", "#fd8d3c", "#800026"],
  "nodes": [
    { "id": "root", "name": "main", "parent": null, "value": 100, "self": 0 },
    { "id": "parse", "name": "parse", "parent": "root", "value": 40, "self": 5 },
    { "id": "render", "name": "render", "parent": "root", "value": 60, "self": 8 },
    { "id": "lex", "name": "lex", "parent": "parse", "value": 25, "self": 25 },
    { "id": "layout", "name": "layout", "parent": "render", "value": 35, "self": 35 },
    { "id": "paint", "name": "paint", "parent": "render", "value": 25, "self": 25 }
  ]
}
""")
    }


    /** M57 分级统计地图 / 等值线地图 `choropleth`。 */
    @TestCase
    public func m057_choropleth(): Unit {
        save("M057-choropleth", ChoroplethChart(), """
{
  "type": "choropleth",
  "title": "各省销售额",
  "width": 760,
  "height": 560,
  "viewBox": [0, 0, 760, 560],
  "colorRange": ["#e8f1fb", "#7fb3d5", "#1f4e79"],
  "showLabels": true,
  "regions": [
    { "id": "east", "name": "华东", "value": 320, "path": "M 420 180 L 560 190 L 570 300 L 430 310 Z" },
    { "id": "south", "name": "华南", "value": 260, "path": "M 430 320 L 560 315 L 550 430 L 420 420 Z" },
    { "id": "north", "name": "华北", "value": 210, "path": "M 300 120 L 410 130 L 415 240 L 300 230 Z" },
    { "id": "west", "name": "西部", "value": 150, "path": "M 120 180 L 290 190 L 295 360 L 130 350 Z" }
  ]
}
""")
    }


    /** M58 点密度地图 `dot-density-map`。 */
    @TestCase
    public func m058_dot_density_map(): Unit {
        save("M058-dot-density-map", DotDensityMapChart(), """
{
  "type": "dot-density-map",
  "title": "门店分布",
  "width": 760,
  "height": 560,
  "viewBox": [0, 0, 760, 560],
  "radius": 3,
  "regions": [
    { "id": "area", "name": "区域", "path": "M 100 100 L 650 110 L 640 480 L 120 470 Z" }
  ],
  "points": [
    { "x": 220, "y": 210, "weight": 2 },
    { "x": 260, "y": 230, "weight": 1 },
    { "x": 410, "y": 300, "weight": 3 },
    { "x": 450, "y": 320, "weight": 2 },
    { "x": 520, "y": 380, "weight": 1 }
  ]
}
""")
    }


    /** M59 热力地图 `heat-map`。 */
    @TestCase
    public func m059_heat_map(): Unit {
        save("M059-heat-map", HeatMapChart(), """
{
  "type": "heat-map",
  "title": "访问热力",
  "width": 760,
  "height": 560,
  "viewBox": [0, 0, 760, 560],
  "radius": 28,
  "colorRange": ["#ffffcc", "#fd8d3c", "#800026"],
  "regions": [
    { "id": "area", "name": "区域", "path": "M 100 100 L 650 110 L 640 480 L 120 470 Z" }
  ],
  "points": [
    { "x": 240, "y": 220, "value": 20 },
    { "x": 300, "y": 260, "value": 45 },
    { "x": 420, "y": 310, "value": 80 },
    { "x": 500, "y": 360, "value": 35 }
  ]
}
""")
    }


    /** M60 流向地图 `flow-map`。 */
    @TestCase
    public func m060_flow_map(): Unit {
        save("M060-flow-map", FlowMapChart(), """
{
  "type": "flow-map",
  "title": "人口迁移",
  "width": 760,
  "height": 560,
  "viewBox": [0, 0, 760, 560],
  "regions": [
    { "id": "a", "name": "A 市", "path": "M 170 200 L 250 210 L 245 280 L 165 270 Z" },
    { "id": "b", "name": "B 市", "path": "M 480 300 L 560 310 L 555 380 L 475 370 Z" }
  ],
  "flows": [
    { "source": "a", "target": "b", "value": 1200, "points": [[210, 240], [350, 300], [520, 340]] },
    { "source": "b", "target": "a", "value": 800, "points": [[520, 340], [350, 320], [210, 240]] }
  ]
}
""")
    }


    /** M61 变形地图 / 卡托图 `cartogram`。 */
    @TestCase
    public func m061_cartogram(): Unit {
        save("M061-cartogram", CartogramChart(), """
{
  "type": "cartogram",
  "title": "按人口变形",
  "width": 760,
  "height": 560,
  "viewBox": [0, 0, 760, 560],
  "scaleBy": "sqrt",
  "regions": [
    { "id": "a", "name": "A 区", "value": 400, "path": "M 180 200 L 260 205 L 265 280 L 185 275 Z", "centroid": [220, 240] },
    { "id": "b", "name": "B 区", "value": 100, "path": "M 460 300 L 520 305 L 525 365 L 465 360 Z", "centroid": [490, 330] },
    { "id": "c", "name": "C 区", "value": 250, "path": "M 320 120 L 400 125 L 405 190 L 325 185 Z", "centroid": [360, 155] }
  ]
}
""")
    }


    /** M62 节点-链接图 `node-link`。 */
    @TestCase
    public func m062_node_link(): Unit {
        save("M062-node-link", NodeLinkChart(), """
{
  "type": "node-link",
  "title": "服务依赖",
  "width": 760,
  "height": 520,
  "layout": "force",
  "linkDistance": 120,
  "charge": -300,
  "nodes": [
    { "id": "gw", "name": "网关", "group": "接入" },
    { "id": "order", "name": "订单", "group": "业务" },
    { "id": "stock", "name": "库存", "group": "业务" },
    { "id": "pay", "name": "支付", "group": "业务" },
    { "id": "db", "name": "数据库", "group": "存储" }
  ],
  "links": [
    { "source": "gw", "target": "order", "value": 3 },
    { "source": "order", "target": "stock", "value": 2 },
    { "source": "order", "target": "pay", "value": 2 },
    { "source": "order", "target": "db", "value": 1 },
    { "source": "stock", "target": "db", "value": 1 }
  ]
}
""")
    }


    /** M63 弧线图 `arc`。 */
    @TestCase
    public func m063_arc(): Unit {
        save("M063-arc", ArcChart(), """
{
  "type": "arc",
  "title": "部门协作",
  "width": 640,
  "height": 640,
  "arcHeight": 0.5,
  "nodes": [
    { "id": "rd", "name": "研发" },
    { "id": "pm", "name": "产品" },
    { "id": "design", "name": "设计" },
    { "id": "qa", "name": "测试" },
    { "id": "ops", "name": "运维" }
  ],
  "links": [
    { "source": "pm", "target": "rd", "value": 8 },
    { "source": "design", "target": "rd", "value": 5 },
    { "source": "rd", "target": "qa", "value": 6 },
    { "source": "qa", "target": "ops", "value": 3 }
  ]
}
""")
    }


    /** M64 和弦图 `chord`。 */
    @TestCase
    public func m064_chord(): Unit {
        save("M064-chord", ChordChart(), """
{
  "type": "chord",
  "title": "城市迁移",
  "width": 640,
  "height": 640,
  "padAngle": 0.02,
  "nodes": [
    { "id": "bj", "name": "北京" },
    { "id": "sh", "name": "上海" },
    { "id": "gz", "name": "广州" },
    { "id": "sz", "name": "深圳" }
  ],
  "links": [
    { "source": "bj", "target": "sh", "value": 120 },
    { "source": "sh", "target": "bj", "value": 90 },
    { "source": "gz", "target": "sz", "value": 80 },
    { "source": "sz", "target": "gz", "value": 60 },
    { "source": "bj", "target": "sz", "value": 40 }
  ]
}
""")
    }


    /** M65 蜂巢图 `hive`。 */
    @TestCase
    public func m065_hive(): Unit {
        save("M065-hive", HiveChart(), """
{
  "type": "hive",
  "title": "技能关系",
  "width": 760,
  "height": 520,
  "groupField": "group",
  "nodeRadius": 18,
  "clusterGap": 80,
  "nodes": [
    { "id": "cangjie", "name": "仓颉", "group": "语言" },
    { "id": "go", "name": "Go", "group": "语言" },
    { "id": "sql", "name": "SQL", "group": "数据" },
    { "id": "redis", "name": "Redis", "group": "数据" },
    { "id": "k8s", "name": "K8s", "group": "运维" }
  ],
  "links": [
    { "source": "cangjie", "target": "sql", "value": 2 },
    { "source": "go", "target": "redis", "value": 3 },
    { "source": "sql", "target": "redis", "value": 2 },
    { "source": "redis", "target": "k8s", "value": 1 }
  ]
}
""")
    }


    /** M66 冲积图 `alluvial`。 */
    @TestCase
    public func m066_alluvial(): Unit {
        save("M066-alluvial", AlluvialChart(), """
{
  "type": "alluvial",
  "title": "用户状态迁移",
  "width": 800,
  "height": 480,
  "stages": ["2025", "2026"],
  "nodeWidth": 14,
  "nodeGap": 10,
  "nodes": [
    { "id": "new-2025", "name": "新客", "stage": "2025" },
    { "id": "old-2025", "name": "老客", "stage": "2025" },
    { "id": "new-2026", "name": "新客", "stage": "2026" },
    { "id": "old-2026", "name": "老客", "stage": "2026" },
    { "id": "lost-2026", "name": "流失", "stage": "2026" }
  ],
  "links": [
    { "source": "new-2025", "target": "old-2026", "value": 420 },
    { "source": "new-2025", "target": "lost-2026", "value": 180 },
    { "source": "old-2025", "target": "old-2026", "value": 600 },
    { "source": "old-2025", "target": "lost-2026", "value": 120 },
    { "source": "new-2026", "target": "old-2026", "value": 300 }
  ]
}
""")
    }


    /** M67 桑基图 `sankey`（别名）。 */
    @TestCase
    public func m067_sankey(): Unit {
        save("M067-sankey", SankeyChart(), """
{
  "type": "sankey",
  "title": "流量来源",
  "width": 760,
  "height": 480,
  "nodeWidth": 16,
  "nodeGap": 12,
  "nodes": [
    { "id": "search", "name": "搜索" },
    { "id": "social", "name": "社交" },
    { "id": "home", "name": "首页" },
    { "id": "detail", "name": "详情" },
    { "id": "cart", "name": "购物车" },
    { "id": "pay", "name": "支付" }
  ],
  "links": [
    { "source": "search", "target": "home", "value": 400 },
    { "source": "social", "target": "home", "value": 300 },
    { "source": "home", "target": "detail", "value": 550 },
    { "source": "detail", "target": "cart", "value": 260 },
    { "source": "cart", "target": "pay", "value": 180 }
  ]
}
""")
    }


    /** M68 网络热力图 `network-heatmap`。 */
    @TestCase
    public func m068_network_heatmap(): Unit {
        save("M068-network-heatmap", NetworkHeatmapChart(), """
{
  "type": "network-heatmap",
  "title": "节点关系强度",
  "width": 640,
  "height": 640,
  "nodes": [
    { "id": "a", "name": "网关" },
    { "id": "b", "name": "订单" },
    { "id": "c", "name": "库存" },
    { "id": "d", "name": "支付" }
  ],
  "colorRange": ["#f7fbff", "#6baed6", "#08306b"],
  "series": [
    {
      "name": "调用量",
      "data": [
        [0, 120, 80, 95],
        [60, 0, 40, 130],
        [35, 25, 0, 20],
        [90, 110, 15, 0]
      ]
    }
  ]
}
""")
    }


    /** M69 旭日图 `sunburst`。 */
    @TestCase
    public func m069_sunburst(): Unit {
        save("M069-sunburst", SunburstChart(), """
{
  "type": "sunburst",
  "title": "产品收入层级",
  "width": 640,
  "height": 640,
  "innerRadius": 0.2,
  "nodes": [
    { "id": "root", "name": "全部", "parent": null },
    { "id": "hw", "name": "硬件", "parent": "root" },
    { "id": "sw", "name": "软件", "parent": "root" },
    { "id": "phone", "name": "手机", "parent": "hw", "value": 60 },
    { "id": "pc", "name": "电脑", "parent": "hw", "value": 40 },
    { "id": "saas", "name": "SaaS", "parent": "sw", "value": 55 },
    { "id": "license", "name": "授权", "parent": "sw", "value": 25 }
  ]
}
""")
    }


    /** M70 圆堆积图 `circle-packing`。 */
    @TestCase
    public func m070_circle_packing(): Unit {
        save("M070-circle-packing", CirclePackingChart(), """
{
  "type": "circle-packing",
  "title": "文件类型占比",
  "width": 640,
  "height": 640,
  "padding": 2,
  "nodes": [
    { "id": "root", "name": "全部", "parent": null },
    { "id": "code", "name": "代码", "parent": "root" },
    { "id": "asset", "name": "资源", "parent": "root" },
    { "id": "ts", "name": "TypeScript", "parent": "code", "value": 120 },
    { "id": "cj", "name": "Cangjie", "parent": "code", "value": 90 },
    { "id": "img", "name": "图片", "parent": "asset", "value": 70 },
    { "id": "font", "name": "字体", "parent": "asset", "value": 30 }
  ]
}
""")
    }


    /** M71 组织图 / 树状图 `org-chart`。 */
    @TestCase
    public func m071_org_chart(): Unit {
        save("M071-org-chart", OrgChart(), """
{
  "type": "org-chart",
  "title": "组织架构",
  "width": 900,
  "height": 560,
  "layout": "vertical",
  "nodeWidth": 140,
  "nodeHeight": 48,
  "levelGap": 80,
  "nodes": [
    { "id": "ceo", "name": "CEO", "parent": null },
    { "id": "cto", "name": "CTO", "parent": "ceo" },
    { "id": "cfo", "name": "CFO", "parent": "ceo" },
    { "id": "fe", "name": "前端组", "parent": "cto" },
    { "id": "be", "name": "后端组", "parent": "cto" },
    { "id": "fin", "name": "财务组", "parent": "cfo" }
  ]
}
""")
    }


    /** M72 南丁格尔玫瑰图 `rose`。 */
    @TestCase
    public func m072_rose(): Unit {
        save("M072-rose", RoseChart(), """
{
  "type": "rose",
  "title": "各品类销量占比",
  "width": 600,
  "height": 600,
  "roseType": "radius",
  "series": [
    {
      "name": "销量",
      "data": [
        { "name": "女装", "value": 40 },
        { "name": "男装", "value": 30 },
        { "name": "鞋靴", "value": 18 },
        { "name": "箱包", "value": 12 }
      ]
    }
  ]
}
""")
    }


    /** M73 华夫图 `waffle`。 */
    @TestCase
    public func m073_waffle(): Unit {
        save("M073-waffle", WaffleChart(), """
{
  "type": "waffle",
  "title": "预算分配",
  "width": 520,
  "height": 520,
  "cells": 100,
  "columns": 10,
  "series": [
    {
      "name": "预算",
      "data": [
        { "name": "研发", "value": 42 },
        { "name": "市场", "value": 28 },
        { "name": "运营", "value": 18 },
        { "name": "其他", "value": 12 }
      ]
    }
  ]
}
""")
    }


    /** M74 象形图 `pictogram`。 */
    @TestCase
    public func m074_pictogram(): Unit {
        save("M074-pictogram", PictogramChart(), """
{
  "type": "pictogram",
  "title": "团队人数",
  "width": 720,
  "height": 360,
  "icon": "person",
  "unit": 10,
  "columns": 10,
  "series": [
    { "name": "研发", "data": [{ "name": "研发", "value": 120 }] },
    { "name": "市场", "data": [{ "name": "市场", "value": 60 }] }
  ]
}
""")
    }


    /** M75 百分比条 `percent-bar`。 */
    @TestCase
    public func m075_percent_bar(): Unit {
        save("M075-percent-bar", PercentBarChart(), """
{
  "type": "percent-bar",
  "title": "各季度收入构成",
  "width": 720,
  "height": 360,
  "xAxis": { "type": "category", "labels": ["Q1", "Q2", "Q3", "Q4"] },
  "series": [
    { "name": "产品 A", "data": [30, 40, 35, 50] },
    { "name": "产品 B", "data": [50, 40, 45, 30] },
    { "name": "产品 C", "data": [20, 20, 20, 20] }
  ]
}
""")
    }


    /** M76 子弹图 `bullet`。 */
    @TestCase
    public func m076_bullet(): Unit {
        save("M076-bullet", BulletChart(), """
{
  "type": "bullet",
  "title": "季度目标完成情况",
  "width": 720,
  "height": 360,
  "xAxis": { "type": "linear", "min": 0, "max": 100, "title": "完成率" },
  "yAxis": { "type": "category", "labels": ["营收", "回款", "新客"] },
  "series": [
    {
      "name": "完成率",
      "data": [
        { "name": "营收", "value": 72, "target": 80, "ranges": [50, 75, 100] },
        { "name": "回款", "value": 88, "target": 85, "ranges": [60, 80, 100] },
        { "name": "新客", "value": 45, "target": 70, "ranges": [40, 70, 100] }
      ]
    }
  ]
}
""")
    }


    /** M77 哑铃图 `dumbbell`。 */
    @TestCase
    public func m077_dumbbell(): Unit {
        save("M077-dumbbell", DumbbellChart(), """
{
  "type": "dumbbell",
  "title": "两年得分变化",
  "xAxis": { "type": "linear", "title": "得分", "min": 0, "max": 100 },
  "yAxis": { "type": "category", "labels": ["A 团队", "B 团队", "C 团队"] },
  "series": [
    {
      "name": "2025 → 2026",
      "data": [
        { "name": "A 团队", "low": 60, "high": 82 },
        { "name": "B 团队", "low": 75, "high": 68 },
        { "name": "C 团队", "low": 52, "high": 74 }
      ]
    }
  ]
}
""")
    }


    /** M78 斜率图 `slope`。 */
    @TestCase
    public func m078_slope(): Unit {
        save("M078-slope", SlopeChart(), """
{
  "type": "slope",
  "title": "排名变化",
  "xAxis": { "type": "category", "labels": ["2025", "2026"] },
  "yAxis": { "type": "linear", "title": "得分", "min": 0, "max": 100 },
  "series": [
    { "name": "A 团队", "data": [60, 82] },
    { "name": "B 团队", "data": [75, 68] },
    { "name": "C 团队", "data": [52, 74] }
  ]
}
""")
    }


    /** M79 棒棒糖图 `lollipop`。 */
    @TestCase
    public func m079_lollipop(): Unit {
        save("M079-lollipop", LollipopChart(), """
{
  "type": "lollipop",
  "title": "各渠道转化率",
  "xAxis": { "type": "category", "labels": ["搜索", "社交", "邮件", "直访", "联盟"] },
  "yAxis": { "type": "linear", "title": "转化率", "min": 0, "labelFormat": "{value}%" },
  "legend": { "show": false },
  "series": [
    { "name": "转化率", "data": [4.2, 2.8, 3.6, 5.1, 1.9], "symbolSize": 8 }
  ]
}
""")
    }


    /** M80 配对连线图 `paired-line`。 */
    @TestCase
    public func m080_paired_line(): Unit {
        save("M080-paired-line", PairedLineChart(), """
{
  "type": "paired-line",
  "title": "干预前后指标",
  "xAxis": { "type": "category", "labels": ["干预前", "干预后"] },
  "yAxis": { "type": "linear", "title": "指标值", "min": 0, "max": 100 },
  "series": [
    {
      "name": "受试者",
      "data": [
        { "name": "S1", "before": 62, "after": 78 },
        { "name": "S2", "before": 70, "after": 66 },
        { "name": "S3", "before": 55, "after": 81 },
        { "name": "S4", "before": 80, "after": 85 }
      ]
    }
  ]
}
""")
    }


    /** M81 时间线图 `timeline`。 */
    @TestCase
    public func m081_timeline(): Unit {
        save("M081-timeline", TimelineChart(), """
{
  "type": "timeline",
  "title": "产品里程碑",
  "width": 900,
  "height": 420,
  "orientation": "horizontal",
  "events": [
    { "date": "2026-01", "title": "立项", "description": "完成需求评审" },
    { "date": "2026-03", "title": "内测", "description": "首批用户试用" },
    { "date": "2026-06", "title": "公测", "description": "开放注册" },
    { "date": "2026-09", "title": "正式发布", "description": "全量上线" }
  ]
}
""")
    }


    /** M82 主题河流图 `streamgraph`。 */
    @TestCase
    public func m082_streamgraph(): Unit {
        save("M082-streamgraph", StreamgraphChart(), """
{
  "type": "streamgraph",
  "title": "音乐流派热度",
  "xAxis": { "type": "category", "labels": ["2019", "2020", "2021", "2022", "2023", "2024"] },
  "yAxis": { "type": "linear", "grid": false },
  "baseline": "wiggle",
  "series": [
    { "name": "流行", "data": [40, 45, 50, 48, 55, 60] },
    { "name": "摇滚", "data": [30, 28, 25, 27, 24, 22] },
    { "name": "电子", "data": [15, 20, 28, 35, 40, 45] },
    { "name": "民谣", "data": [10, 12, 14, 13, 16, 18] }
  ]
}
""")
    }


    /** M83 蜡烛图 / K 线图 `candlestick`。 */
    @TestCase
    public func m083_candlestick(): Unit {
        save("M083-candlestick", CandlestickChart(), """
{
  "type": "candlestick",
  "title": "日 K 线",
  "xAxis": { "type": "category", "labels": ["2026-01-05", "2026-01-06", "2026-01-07", "2026-01-08"] },
  "yAxis": { "type": "linear", "title": "价格", "min": 0 },
  "series": [
    {
      "name": "价格",
      "data": [
        { "date": "2026-01-05", "open": 100, "high": 108, "low": 98, "close": 105 },
        { "date": "2026-01-06", "open": 105, "high": 110, "low": 103, "close": 108 },
        { "date": "2026-01-07", "open": 108, "high": 109, "low": 101, "close": 103 },
        { "date": "2026-01-08", "open": 103, "high": 107, "low": 100, "close": 106 }
      ]
    }
  ]
}
""")
    }


    /** M84 螺旋图 `spiral`。 */
    @TestCase
    public func m084_spiral(): Unit {
        save("M084-spiral", SpiralChart(), """
{
  "type": "spiral",
  "title": "月度周期",
  "width": 600,
  "height": 600,
  "turns": 3,
  "startAngle": -90,
  "clockwise": true,
  "series": [
    {
      "name": "周期值",
      "data": [
        { "period": "1月", "value": 12 },
        { "period": "2月", "value": 18 },
        { "period": "3月", "value": 25 },
        { "period": "4月", "value": 20 },
        { "period": "5月", "value": 30 },
        { "period": "6月", "value": 28 }
      ]
    }
  ]
}
""")
    }


    /** M85 泳道图 `swimlane`。 */
    @TestCase
    public func m085_swimlane(): Unit {
        save("M085-swimlane", SwimlaneChart(), """
{
  "type": "swimlane",
  "title": "审批流程",
  "width": 900,
  "height": 560,
  "direction": "horizontal",
  "lanes": [
    { "id": "employee", "name": "员工" },
    { "id": "manager", "name": "主管" },
    { "id": "finance", "name": "财务" }
  ],
  "nodes": [
    { "id": "submit", "label": "提交申请", "lane": "employee" },
    { "id": "review", "label": "主管审批", "lane": "manager" },
    { "id": "pay", "label": "财务打款", "lane": "finance" },
    { "id": "reject", "label": "驳回", "lane": "manager" }
  ],
  "edges": [
    { "source": "submit", "target": "review" },
    { "source": "review", "target": "pay", "label": "通过" },
    { "source": "review", "target": "reject", "label": "不通过" }
  ]
}
""")
    }


    /** M86 漏斗图 `funnel`（别名）。 */
    @TestCase
    public func m086_funnel(): Unit {
        save("M086-funnel", FunnelChart(), """
{
  "type": "funnel",
  "title": "注册转化",
  "width": 640,
  "height": 480,
  "gap": 2,
  "showConversion": true,
  "series": [
    {
      "name": "阶段",
      "data": [
        { "name": "访问", "value": 10000 },
        { "name": "注册", "value": 6200 },
        { "name": "激活", "value": 3800 },
        { "name": "付费", "value": 1200 }
      ]
    }
  ]
}
""")
    }


    /** M87 瀑布图 `waterfall`（别名）。 */
    @TestCase
    public func m087_waterfall(): Unit {
        save("M087-waterfall", WaterfallChart(), """
{
  "type": "waterfall",
  "title": "利润增减分解",
  "xAxis": { "type": "category", "labels": ["期初", "收入", "成本", "税费", "期末"] },
  "yAxis": { "type": "linear", "title": "万元", "min": 0 },
  "legend": { "show": false },
  "series": [
    {
      "name": "利润",
      "data": [
        { "name": "期初", "value": 120, "type": "total" },
        { "name": "收入", "value": 80, "type": "increase" },
        { "name": "成本", "value": -45, "type": "decrease" },
        { "name": "税费", "value": -15, "type": "decrease" },
        { "name": "期末", "value": 140, "type": "total" }
      ]
    }
  ]
}
""")
    }


    /** M88 雨云图 `raincloud`。 */
    @TestCase
    public func m088_raincloud(): Unit {
        save("M088-raincloud", RaincloudChart(), """
{
  "type": "raincloud",
  "title": "各组得分分布",
  "xAxis": { "type": "category", "labels": ["A 组", "B 组", "C 组"] },
  "yAxis": { "type": "linear", "title": "得分", "min": 0 },
  "series": [
    { "name": "得分", "data": [55, 60, 62, 65, 68, 70, 72, 75, 78, 82, 88, 92], "bandwidth": 4.0, "showCloud": true, "showRain": true, "showBox": true }
  ]
}
""")
    }


    /** M89 豆图 `dot-strip`。 */
    @TestCase
    public func m089_dot_strip(): Unit {
        save("M089-dot-strip", DotStripChart(), """
{
  "type": "dot-strip",
  "title": "各组小样本",
  "xAxis": { "type": "category", "labels": ["A", "B", "C"] },
  "yAxis": { "type": "linear", "title": "值", "min": 0 },
  "series": [
    { "name": "样本", "data": [12, 15, 18, 20, 24, 28, 31, 35], "jitter": 0.15, "dotSize": 7 }
  ]
}
""")
    }


    /** M90 累积频率图 `ecdf`。 */
    @TestCase
    public func m090_ecdf(): Unit {
        save("M090-ecdf", EcdfChart(), """
{
  "type": "ecdf",
  "title": "响应时间累积分布",
  "xAxis": { "type": "linear", "title": "响应时间（ms）" },
  "yAxis": { "type": "linear", "title": "累积频率", "min": 0, "max": 1 },
  "series": [
    { "name": "优化前", "data": [120, 135, 150, 160, 175, 190, 210, 240, 280, 320] },
    { "name": "优化后", "data": [80, 90, 95, 100, 110, 120, 130, 145, 160, 180] }
  ]
}
""")
    }


    /** M91 Bland-Altman 图 `bland-altman`。 */
    @TestCase
    public func m091_bland_altman(): Unit {
        save("M091-bland-altman", BlandAltmanChart(), """
{
  "type": "bland-altman",
  "title": "两种测量方法一致性",
  "xAxis": { "type": "linear", "title": "均值" },
  "yAxis": { "type": "linear", "title": "差值" },
  "legend": { "show": false },
  "series": [
    {
      "name": "测量对",
      "data": [
        { "x": 10.2, "y": 10.5 }, { "x": 12.0, "y": 11.6 }, { "x": 14.5, "y": 14.9 },
        { "x": 16.1, "y": 15.8 }, { "x": 18.3, "y": 18.9 }, { "x": 20.0, "y": 19.5 }
      ]
    }
  ]
}
""")
    }


    /** M92 火山图 `volcano`。 */
    @TestCase
    public func m092_volcano(): Unit {
        save("M092-volcano", VolcanoChart(), """
{
  "type": "volcano",
  "title": "差异表达",
  "xAxis": { "type": "linear", "title": "log2 Fold Change" },
  "yAxis": { "type": "linear", "title": "-log10(p)" },
  "foldChangeThreshold": 1,
  "pThreshold": 1.3,
  "legend": { "show": false },
  "series": [
    {
      "name": "基因",
      "data": [
        { "x": -2.4, "y": 4.1, "label": "GENE1" },
        { "x": 2.1, "y": 3.6, "label": "GENE2" },
        { "x": 0.3, "y": 0.8, "label": "GENE3" },
        { "x": -0.6, "y": 1.1, "label": "GENE4" },
        { "x": 1.8, "y": 2.9, "label": "GENE5" }
      ]
    }
  ]
}
""")
    }


    /** M93 曼哈顿图 `manhattan`。 */
    @TestCase
    public func m093_manhattan(): Unit {
        save("M093-manhattan", ManhattanChart(), """
{
  "type": "manhattan",
  "title": "GWAS 曼哈顿图",
  "xAxis": { "type": "linear", "title": "染色体位置" },
  "yAxis": { "type": "linear", "title": "-log10(p)" },
  "threshold": 5.0,
  "legend": { "show": false },
  "series": [
    {
      "name": "SNP",
      "data": [
        { "x": 1000, "y": 2.1, "chromosome": "1" },
        { "x": 2500, "y": 4.8, "chromosome": "1" },
        { "x": 5200, "y": 6.2, "chromosome": "2" },
        { "x": 7800, "y": 1.5, "chromosome": "3" },
        { "x": 9900, "y": 5.4, "chromosome": "3" }
      ]
    }
  ]
}
""")
    }


    /** M93b 混淆矩阵 `confusion-matrix`。 */
    @TestCase
    public func m093b_confusion_matrix(): Unit {
        save("M093b-confusion-matrix", ConfusionMatrixChart(), """
{
  "type": "confusion-matrix",
  "title": "分类混淆矩阵",
  "width": 560,
  "height": 560,
  "labels": ["猫", "狗", "鸟"],
  "normalize": "row",
  "showValues": true,
  "series": [
    {
      "name": "样本数",
      "data": [
        [45, 3, 2],
        [4, 38, 8],
        [1, 6, 33]
      ]
    }
  ]
}
""")
    }


    /** M94 提升图 / Lift 图 `lift`。 */
    @TestCase
    public func m094_lift(): Unit {
        save("M094-lift", LiftChart(), """
{
  "type": "lift",
  "title": "Lift 曲线",
  "xAxis": { "type": "linear", "title": "样本比例", "min": 0, "max": 1 },
  "yAxis": { "type": "linear", "title": "Lift" },
  "baseline": 1,
  "series": [
    {
      "name": "模型 A",
      "data": [
        { "x": 0.1, "y": 2.8 }, { "x": 0.2, "y": 2.3 }, { "x": 0.4, "y": 1.7 },
        { "x": 0.6, "y": 1.35 }, { "x": 0.8, "y": 1.12 }, { "x": 1.0, "y": 1.0 }
      ]
    }
  ]
}
""")
    }


    /** M95 增益图 `gain`。 */
    @TestCase
    public func m095_gain(): Unit {
        save("M095-gain", GainChart(), """
{
  "type": "gain",
  "title": "累积增益",
  "xAxis": { "type": "linear", "title": "样本比例", "min": 0, "max": 1 },
  "yAxis": { "type": "linear", "title": "捕获比例", "min": 0, "max": 1 },
  "series": [
    {
      "name": "模型 A",
      "data": [
        { "x": 0.1, "y": 0.42 }, { "x": 0.2, "y": 0.62 }, { "x": 0.4, "y": 0.82 },
        { "x": 0.6, "y": 0.91 }, { "x": 0.8, "y": 0.97 }, { "x": 1.0, "y": 1.0 }
      ]
    }
  ]
}
""")
    }


    /** M96 校准曲线 `calibration`。 */
    @TestCase
    public func m096_calibration(): Unit {
        save("M096-calibration", CalibrationChart(), """
{
  "type": "calibration",
  "title": "概率校准",
  "xAxis": { "type": "linear", "title": "预测概率", "min": 0, "max": 1 },
  "yAxis": { "type": "linear", "title": "实际频率", "min": 0, "max": 1 },
  "diagonal": true,
  "series": [
    {
      "name": "模型 A",
      "data": [
        { "x": 0.05, "y": 0.08 }, { "x": 0.15, "y": 0.12 }, { "x": 0.30, "y": 0.35 },
        { "x": 0.50, "y": 0.46 }, { "x": 0.70, "y": 0.74 }, { "x": 0.90, "y": 0.88 }
      ]
    }
  ]
}
""")
    }


    /** M97 学习曲线 `learning-curve`。 */
    @TestCase
    public func m097_learning_curve(): Unit {
        save("M097-learning-curve", LearningCurveChart(), """
{
  "type": "learning-curve",
  "title": "学习曲线",
  "xAxis": { "type": "linear", "title": "训练样本量" },
  "yAxis": { "type": "linear", "title": "准确率", "min": 0, "max": 1 },
  "metric": "score",
  "series": [
    { "name": "训练集", "data": [{ "x": 100, "y": 0.72 }, { "x": 500, "y": 0.86 }, { "x": 1000, "y": 0.91 }, { "x": 2000, "y": 0.94 }] },
    { "name": "验证集", "data": [{ "x": 100, "y": 0.60 }, { "x": 500, "y": 0.78 }, { "x": 1000, "y": 0.84 }, { "x": 2000, "y": 0.87 }] }
  ]
}
""")
    }


    /** M98 LASSO 路径图 `lasso-path`。 */
    @TestCase
    public func m098_lasso_path(): Unit {
        save("M098-lasso-path", LassoPathChart(), """
{
  "type": "lasso-path",
  "title": "LASSO 系数路径",
  "xAxis": { "type": "linear", "title": "log(lambda)" },
  "yAxis": { "type": "linear", "title": "系数" },
  "variables": ["年龄", "血压", "BMI", "血糖"],
  "series": [
    { "name": "年龄", "data": [{ "x": -4, "y": 0.8 }, { "x": -2, "y": 0.5 }, { "x": 0, "y": 0.1 }, { "x": 2, "y": 0.0 }] },
    { "name": "血压", "data": [{ "x": -4, "y": 0.6 }, { "x": -2, "y": 0.4 }, { "x": 0, "y": 0.2 }, { "x": 2, "y": 0.0 }] },
    { "name": "BMI", "data": [{ "x": -4, "y": 0.3 }, { "x": -2, "y": 0.1 }, { "x": 0, "y": 0.0 }, { "x": 2, "y": 0.0 }] },
    { "name": "血糖", "data": [{ "x": -4, "y": 0.2 }, { "x": -2, "y": 0.0 }, { "x": 0, "y": 0.0 }, { "x": 2, "y": 0.0 }] }
  ]
}
""")
    }


    /** M99 决策树图 `decision-tree`。 */
    @TestCase
    public func m099_decision_tree(): Unit {
        save("M099-decision-tree", DecisionTreeChart(), """
{
  "type": "decision-tree",
  "title": "决策树",
  "width": 900,
  "height": 520,
  "nodes": [
    { "id": "root", "label": "年龄 > 30?", "leaf": false },
    { "id": "left", "label": "收入 > 10k?", "parent": "root", "leaf": false },
    { "id": "right", "label": "通过", "parent": "root", "leaf": true },
    { "id": "ll", "label": "拒绝", "parent": "left", "leaf": true },
    { "id": "lr", "label": "通过", "parent": "left", "leaf": true }
  ],
  "edges": [
    { "source": "root", "target": "left", "label": "否" },
    { "source": "root", "target": "right", "label": "是" },
    { "source": "left", "target": "ll", "label": "否" },
    { "source": "left", "target": "lr", "label": "是" }
  ]
}
""")
    }


    /** M100 部分依赖图 `pdp`。 */
    @TestCase
    public func m100_pdp(): Unit {
        save("M100-pdp", PdpChart(), """
{
  "type": "pdp",
  "title": "年龄对预测的影响",
  "xAxis": { "type": "linear", "title": "年龄" },
  "yAxis": { "type": "linear", "title": "预测值" },
  "feature": "年龄",
  "legend": { "show": false },
  "series": [
    {
      "name": "PDP",
      "data": [
        { "x": 20, "y": 0.12 }, { "x": 30, "y": 0.28 }, { "x": 40, "y": 0.45 },
        { "x": 50, "y": 0.58 }, { "x": 60, "y": 0.62 }, { "x": 70, "y": 0.55 }
      ]
    }
  ]
}
""")
    }


    /** M101 SHAP 图 `shap`。 */
    @TestCase
    public func m101_shap(): Unit {
        save("M101-shap", ShapChart(), """
{
  "type": "shap",
  "title": "单样本 SHAP 解释",
  "width": 720,
  "height": 440,
  "features": ["年龄", "血压", "BMI", "血糖"],
  "series": [
    {
      "name": "SHAP",
      "data": [
        { "feature": "年龄", "value": 0.32 },
        { "feature": "血压", "value": -0.18 },
        { "feature": "BMI", "value": 0.12 },
        { "feature": "血糖", "value": -0.05 }
      ]
    }
  ]
}
""")
    }


    /** M102 词云 `word-cloud`。 */
    @TestCase
    public func m102_word_cloud(): Unit {
        save("M102-word-cloud", WordCloudChart(), """
{
  "type": "word-cloud",
  "title": "用户反馈关键词",
  "width": 760,
  "height": 480,
  "minFontSize": 14,
  "maxFontSize": 56,
  "rotate": [0, 90],
  "words": [
    { "text": "易用", "weight": 80 },
    { "text": "稳定", "weight": 65 },
    { "text": "快速", "weight": 60 },
    { "text": "界面", "weight": 45 },
    { "text": "文档", "weight": 35 },
    { "text": "价格", "weight": 25 }
  ]
}
""")
    }


    /** M103 词网络图 `word-network`。 */
    @TestCase
    public func m103_word_network(): Unit {
        save("M103-word-network", WordNetworkChart(), """
{
  "type": "word-network",
  "title": "词语共现",
  "width": 760,
  "height": 520,
  "layout": "force",
  "linkDistance": 100,
  "nodes": [
    { "id": "chart", "name": "图表", "weight": 40 },
    { "id": "svg", "name": "SVG", "weight": 30 },
    { "id": "json", "name": "JSON", "weight": 28 },
    { "id": "data", "name": "数据", "weight": 36 }
  ],
  "links": [
    { "source": "chart", "target": "svg", "value": 18 },
    { "source": "chart", "target": "json", "value": 15 },
    { "source": "chart", "target": "data", "value": 22 },
    { "source": "json", "target": "data", "value": 12 }
  ]
}
""")
    }


    /** M104 标签云 `tag-cloud`（别名）。 */
    @TestCase
    public func m104_tag_cloud(): Unit {
        save("M104-tag-cloud", WordCloudChart(), """
{
  "type": "tag-cloud",
  "title": "热门标签",
  "width": 760,
  "height": 480,
  "words": [
    { "text": "仓颉", "weight": 90 },
    { "text": "SVG", "weight": 70 },
    { "text": "JSON", "weight": 55 },
    { "text": "图表", "weight": 40 }
  ]
}
""")
    }


    /** M105 仪表盘 `gauge`。 */
    @TestCase
    public func m105_gauge(): Unit {
        save("M105-gauge", GaugeChart(), """
{
  "type": "gauge",
  "title": "任务完成率",
  "width": 480,
  "height": 360,
  "min": 0,
  "max": 100,
  "startAngle": -120,
  "endAngle": 120,
  "thresholds": [
    { "value": 60, "color": "#e15759" },
    { "value": 85, "color": "#edc948" },
    { "value": 100, "color": "#59a14f" }
  ],
  "series": [
    { "name": "完成率", "data": [{ "name": "完成率", "value": 72 }] }
  ]
}
""")
    }


    /** M106 日历热力图 `calendar-heatmap`（别名）。 */
    @TestCase
    public func m106_calendar_heatmap(): Unit {
        save("M106-calendar-heatmap", CalendarHeatmapChart(), """
{
  "type": "calendar-heatmap",
  "title": "提交活跃度",
  "width": 900,
  "height": 220,
  "startDate": "2026-01-01",
  "endDate": "2026-03-31",
  "cellSize": 14,
  "weekStart": "mon",
  "colorRange": ["#ebedf0", "#9be9a8", "#40c463", "#216e39"],
  "series": [
    {
      "name": "提交数",
      "data": [
        { "date": "2026-01-05", "value": 2 },
        { "date": "2026-01-06", "value": 5 },
        { "date": "2026-01-12", "value": 8 },
        { "date": "2026-02-03", "value": 3 },
        { "date": "2026-02-04", "value": 12 },
        { "date": "2026-03-09", "value": 6 }
      ]
    }
  ]
}
""")
    }

}
