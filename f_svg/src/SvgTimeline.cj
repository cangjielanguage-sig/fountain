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
package fountain::f_svg

import std.collection.*
import std.math.*
import fountain::f_base.*

private let SVG_ANIMATION_TAGS: Array<String> = ["animate", "animateTransform", "animateMotion", "set"]

private class SvgAnimationSpec {
    let element: SvgElement
    let kind: SvgAnimationKind
    let target: ?SvgElement
    let targetId: ?String
    let attributeName: String
    let beginRaw: ?String
    let endRaw: ?String
    let dur: Float64
    let repeatCount: Float64
    let repeatDur: Float64
    let freeze: Bool
    let values: Array<String>
    let keyTimes: Array<Float64>
    let keySplines: Array<Array<Float64>>
    let calcMode: SvgCalcMode
    let additive: Bool
    let accumulate: Bool
    let transformType: String
    let rotate: String
    let keyPoints: Array<Float64>
    let pathData: ?SvgPathData
    var begin: Float64 = 0.0
    var end: Float64 = 0.0

    init(
        element: SvgElement,
        kind: SvgAnimationKind,
        target: ?SvgElement,
        attributeName: String,
        beginRaw: ?String,
        endRaw: ?String,
        dur: Float64,
        repeatCount: Float64,
        repeatDur: Float64,
        freeze: Bool,
        values: Array<String>,
        keyTimes: Array<Float64>,
        keySplines: Array<Array<Float64>>,
        calcMode: SvgCalcMode,
        additive: Bool,
        accumulate: Bool,
        transformType: String,
        rotate: String,
        keyPoints: Array<Float64>,
        pathData: ?SvgPathData
    ) {
        this.element = element
        this.kind = kind
        this.target = target
        this.targetId = match (target) {
            case Some(value) => value.attr("id")
            case None => None
        }
        this.attributeName = attributeName
        this.beginRaw = beginRaw
        this.endRaw = endRaw
        this.dur = dur
        this.repeatCount = repeatCount
        this.repeatDur = repeatDur
        this.freeze = freeze
        this.values = values
        this.keyTimes = keyTimes
        this.keySplines = keySplines
        this.calcMode = calcMode
        this.additive = additive
        this.accumulate = accumulate
        this.transformType = transformType
        this.rotate = rotate
        this.keyPoints = keyPoints
        this.pathData = pathData
    }

    func totalDuration(): Float64 {
        if (isInfSvg(this.dur)) {
            return Float64.Inf
        }
        var total = this.dur * this.repeatCount
        if (!isInfSvg(this.repeatDur) && this.repeatDur < total) {
            total = this.repeatDur
        }
        if (isInfSvg(this.repeatCount)) {
            return Float64.Inf
        }
        total
    }
}

private class SvgAnimationState {
    let active: Bool
    let progress: Float64
    let iteration: Int64

    init(active: Bool, progress: Float64, iteration: Int64) {
        this.active = active
        this.progress = progress
        this.iteration = iteration
    }
}

/**
 * SMIL 时间轴。
 *
 * `sample` 深拷贝文档后在副本上求值，返回的 `SvgDocument` 可独立渲染；
 * 原文档不被修改。支持 `animate` / `animateTransform` / `animateMotion` / `set`。
 */
public class SvgTimeline {
    public let warnings = ArrayList<String>()
    private let document: SvgDocument
    private let clock: SvgClock
    private let specs: Array<SvgAnimationSpec>
    private let specById = HashMap<String, SvgAnimationSpec>()

    public init(document: SvgDocument, clock!: SvgClock = SvgManualClock()) {
        this.document = document
        this.clock = clock
        let collected = ArrayList<SvgAnimationSpec>()
        collectAnimationSpecs(document.root, collected, this.warnings)
        let array = collected.toArray()
        for (spec in array) {
            match (spec.element.attr("id")) {
                case Some(id) => this.specById[id] = spec
                case None => ()
            }
        }
        for (spec in array) {
            let visitingBegin = HashMap<String, Bool>()
            spec.begin = resolveAnimationTime(spec, true, this.specById, this.warnings, visitingBegin)
            let total = spec.totalDuration()
            let defaultEnd = if (isInfSvg(total)) { Float64.Inf } else { spec.begin + total }
            let visitingEnd = HashMap<String, Bool>()
            spec.end = match (spec.endRaw) {
                case Some(_) => resolveAnimationTime(spec, false, this.specById, this.warnings, visitingEnd)
                case None => defaultEnd
            }
        }
        this.specs = array
    }

    public func duration(): Float64 {
        var result = 0.0
        for (spec in this.specs) {
            if (!isInfSvg(spec.end) && spec.end > result) {
                result = spec.end
            }
        }
        result
    }

    public func animations(): Array<SvgAnimationInfo> {
        let result = ArrayList<SvgAnimationInfo>()
        for (spec in this.specs) {
            result.add(
                SvgAnimationInfo(spec.targetId, spec.attributeName, spec.begin, spec.end, spec.kind)
            )
        }
        result.toArray()
    }

    public func sample(time: Float64): SvgDocument {
        let snapshot = cloneSvgDocument(this.document)
        for (spec in this.specs) {
            let targetId = match (spec.targetId) {
                case Some(value) => value
                case None => continue
            }
            let target = match (snapshot.elementById(targetId)) {
                case Some(value) => value
                case None => continue
            }
            let state = animationStateAt(spec, time)
            if (!state.active) {
                continue
            }
            this.applyAnimation(target, spec, state)
        }
        snapshot
    }

    public func sampleCurrent(): SvgDocument {
        this.sample(this.clock.now())
    }

    private func applyAnimation(
        target: SvgElement,
        spec: SvgAnimationSpec,
        state: SvgAnimationState
    ): Unit {
        let base = target.attr(spec.attributeName) ?? "0"
        if (spec.kind == SvgAnimationKind.AnimateTransform) {
            let animated = evaluateTransformValue(spec, state.progress, this.warnings)
            if (spec.additive) {
                let baseTransform = match (target.transform) {
                    case Some(value) => value
                    case None => SvgTransform.identity
                }
                let combined = SvgTransform(
                    [SvgTransformOp.Matrix(baseTransform.toMatrix().multiply(animated.toMatrix()))]
                )
                target.setAttr("transform", combined.toString())
            } else {
                target.setAttr("transform", animated.toString())
            }
            return
        }
        if (spec.kind == SvgAnimationKind.AnimateMotion) {
            match (spec.pathData) {
                case Some(path) =>
                    let motion = sampleMotion(path, state.progress, spec.rotate, spec.keyPoints, spec.keyTimes)
                    let motionTransform = SvgTransform(
                        [SvgTransformOp.Translate(motion[0], motion[1]),
                        SvgTransformOp.Rotate(motion[2], 0.0, 0.0)]
                    )
                    match (target.transform) {
                        case Some(base) =>
                            let combined = base.toMatrix().multiply(motionTransform.toMatrix())
                            target.setAttr(
                                "transform",
                                SvgTransform([SvgTransformOp.Matrix(combined)]).toString()
                            )
                        case None => target.setAttr("transform", motionTransform.toString())
                    }
                case None => ()
            }
            return
        }
        var value = evaluateKeyframeValue(spec, state.progress, base, this.warnings)
        if (spec.accumulate && state.iteration > 0) {
            let frames = effectiveFrames(spec, base)
            match ((tryParseSvgFloat(value), tryParseSvgFloat(frames[0]), tryParseSvgFloat(frames[frames.size - 1]))) {
                case (Some(current), Some(first), Some(last)) =>
                    value = formatSvgNumber(current + (last - first) * Float64(state.iteration))
                case _ => ()
            }
        }
        if (spec.additive) {
            match ((tryParseSvgFloat(value), tryParseSvgFloat(base))) {
                case (Some(current), Some(baseNumber)) =>
                    value = formatSvgNumber(current + baseNumber)
                case _ => ()
            }
        }
        target.setAttr(spec.attributeName, value)
    }
}

private func collectAnimationSpecs(
    element: SvgElement,
    out: ArrayList<SvgAnimationSpec>,
    warnings: ArrayList<String>
): Unit {
    for (node in element.children) {
        match (node) {
            case ElementNode(child) =>
                if (isSvgAnimationTag(child.tag)) {
                    match (buildAnimationSpec(child, element, warnings)) {
                        case Some(spec) => out.add(spec)
                        case None => ()
                    }
                }
                collectAnimationSpecs(child, out, warnings)
            case _ => ()
        }
    }
}

private func isSvgAnimationTag(tag: String): Bool {
    for (name in SVG_ANIMATION_TAGS) {
        if (name == tag) {
            return true
        }
    }
    false
}

private func buildAnimationSpec(
    element: SvgElement,
    parent: SvgElement,
    warnings: ArrayList<String>
): ?SvgAnimationSpec {
    let kind = match (element.tag) {
        case "animateTransform" => SvgAnimationKind.AnimateTransform
        case "animateMotion" => SvgAnimationKind.AnimateMotion
        case "set" => SvgAnimationKind.Set
        case _ => SvgAnimationKind.Animate
    }
    let attributeName = element.attr("attributeName") ?? ""
    if (attributeName.size == 0 && (kind == SvgAnimationKind.Animate || kind == SvgAnimationKind.Set)) {
        warnings.add("动画缺少 attributeName，已忽略")
        return None
    }
    let values = parseAnimationValues(element.attr("values"))
    if (values.size > 10000) {
        throw SvgException("动画 values 数量超过 10000", kind: SvgErrorKind.Limit)
    }
    let transformType = element.attr("type") ?? "translate"
    if (kind == SvgAnimationKind.AnimateTransform && element.attr("type").isNone()) {
        warnings.add("animateTransform 缺少 type，已忽略")
        return None
    }
    var pathData: ?SvgPathData = None
    if (kind == SvgAnimationKind.AnimateMotion) {
        pathData = resolveMotionPath(element, parent, warnings)
        if (pathData.isNone()) {
            warnings.add("animateMotion 缺少 path / mpath，已忽略")
            return None
        }
    }
    Some(
        SvgAnimationSpec(
            element,
            kind,
            Some(parent),
            attributeName,
            element.attr("begin"),
            element.attr("end"),
            parseSvgTimeValue(element.attr("dur") ?? "indefinite") ?? Float64.Inf,
            parseRepeatCount(element.attr("repeatCount")),
            parseSvgTimeValue(element.attr("repeatDur") ?? "indefinite") ?? Float64.Inf,
            (element.attr("fill") ?? "remove") == "freeze",
            values,
            parseKeyTimes(element.attr("keyTimes")),
            parseKeySplines(element.attr("keySplines")),
            SvgCalcMode.fromName(element.attr("calcMode") ?? "linear"),
            (element.attr("additive") ?? "replace") == "sum",
            (element.attr("accumulate") ?? "none") == "sum",
            transformType,
            element.attr("rotate") ?? "0",
            parseKeyPoints(element.attr("keyPoints"), warnings),
            pathData
        )
    )
}

private func parseAnimationValues(raw: ?String): Array<String> {
    match (raw) {
        case Some(text) => splitSvgSemicolon(text)
        case None => Array<String>()
    }
}

private func splitSvgSemicolon(text: String): Array<String> {
    let result = ArrayList<String>()
    let bytes = text.unsafeBytes()
    var start = 0
    var index = 0
    while (index < bytes.size) {
        if (bytes[index] == b';') {
            let part = text[start..index].trimAscii()
            if (part.size > 0) {
                result.add(part)
            }
            start = index + 1
        }
        index++
    }
    let tail = text[start..bytes.size].trimAscii()
    if (tail.size > 0) {
        result.add(tail)
    }
    result.toArray()
}

private func parseRepeatCount(raw: ?String): Float64 {
    match (raw) {
        case Some(text) =>
            if (text.trimAscii().toAsciiLower() == "indefinite") {
                Float64.Inf
            } else {
                tryParseSvgFloat(text) ?? 1.0
            }
        case None => 1.0
    }
}

private func parseKeyTimes(raw: ?String): Array<Float64> {
    match (raw) {
        case Some(text) =>
            let parts = splitSvgSemicolon(text)
            let result = ArrayList<Float64>()
            for (part in parts) {
                result.add(tryParseSvgFloat(part) ?? 0.0)
            }
            result.toArray()
        case None => Array<Float64>()
    }
}

private func parseKeySplines(raw: ?String): Array<Array<Float64>> {
    match (raw) {
        case Some(text) =>
            let result = ArrayList<Array<Float64>>()
            for (part in splitSvgSemicolon(text)) {
                let values = tryParseSvgNumberArray(part.replace(",", " ")) ?? Array<Float64>()
                if (values.size == 4) {
                    result.add(values)
                }
            }
            result.toArray()
        case None => Array<Array<Float64>>()
    }
}

private func parseKeyPoints(raw: ?String, warnings: ArrayList<String>): Array<Float64> {
    match (raw) {
        case Some(text) =>
            let result = ArrayList<Float64>()
            var invalid = false
            for (part in splitSvgSemicolon(text)) {
                let value = tryParseSvgFloat(part) ?? 0.0
                if (value < 0.0 || value > 1.0) {
                    invalid = true
                }
                result.add(clampSvgUnit(value))
            }
            if (invalid) {
                warnings.add("animateMotion 的 keyPoints 超出 0..1，已钳制")
            }
            result.toArray()
        case None => Array<Float64>()
    }
}

private func resolveMotionPath(
    animation: SvgElement,
    parent: SvgElement,
    warnings: ArrayList<String>
): ?SvgPathData {
    match (animation.attr("path")) {
        case Some(text) => return SvgPathData.tryParse(text)
        case None => ()
    }
    let mpath = animation.childrenOf("mpath")
    if (mpath.size == 0) {
        return None
    }
    let href = readSvgHref(mpath[0])
    let targetId = match (href) {
        case Some(value) => stripSvgHash(value)
        case None => return None
    }
    var depth = 0
    let visited = HashMap<String, Bool>()
    var targetIdValue = targetId
    while (true) {
        if (visited.get(targetIdValue).isSome()) {
            warnings.add("mpath 引用出现循环「${targetIdValue}」，已停止")
            return None
        }
        visited[targetIdValue] = true
        if (depth > 64) {
            throw SvgException("mpath 引用深度超过 64", kind: SvgErrorKind.Limit)
        }
        let target = match (findSvgElementById(Some(parentRoot(parent)), targetIdValue)) {
            case Some(value) => value
            case None =>
                warnings.add("mpath 引用目标「${targetIdValue}」不存在")
                return None
        }
        match (target.attr("d")) {
            case Some(text) => return SvgPathData.tryParse(text)
            case None => ()
        }
        let motions = target.childrenOf("animateMotion")
        if (motions.size == 0) {
            return None
        }
        let nestedMpath = motions[0].childrenOf("mpath")
        if (nestedMpath.size == 0) {
            return None
        }
        targetIdValue = match (readSvgHref(nestedMpath[0])) {
            case Some(value) => stripSvgHash(value)
            case None => return None
        }
        depth++
    }
    None
}

private func parentRoot(element: SvgElement): SvgElement {
    var current = element
    while (true) {
        match (current.parent) {
            case Some(parent) => current = parent
            case None => return current
        }
    }
    current
}

private func resolveAnimationTime(
    spec: SvgAnimationSpec,
    isBegin: Bool,
    specById: HashMap<String, SvgAnimationSpec>,
    warnings: ArrayList<String>,
    visiting: HashMap<String, Bool>
): Float64 {
    let raw = if (isBegin) { spec.beginRaw } else { spec.endRaw }
    match (raw) {
        case None => return if (isBegin) { 0.0 } else { spec.begin + spec.totalDuration() }
        case Some(text) =>
            match (parseSvgTimeReference(text)) {
                case Some(reference) =>
                    if (visiting.get(reference.id).isSome()) {
                        warnings.add("动画时间引用出现循环「${reference.id}」")
                        return if (isBegin) { 0.0 } else { spec.begin + spec.totalDuration() }
                    }
                    let other = match (specById.get(reference.id)) {
                        case Some(value) => value
                        case None =>
                            warnings.add("动画时间引用目标「${reference.id}」不存在")
                            return if (isBegin) { 0.0 } else { spec.begin + spec.totalDuration() }
                    }
                    visiting[reference.id] = true
                    let result = if (reference.isBegin) {
                        resolveAnimationTime(other, true, specById, warnings, visiting)
                    } else {
                        resolveAnimationTime(other, false, specById, warnings, visiting)
                    }
                    return result
                case None =>
                    if (isSvgEventTime(text)) {
                        warnings.add("事件型动画时间「${text}」在 M2 忽略")
                        return 0.0
                    }
                    match (parseSvgTimeValue(text)) {
                        case Some(value) => value
                        case None =>
                            warnings.add("无法解析动画时间「${text}」")
                            0.0
                    }
            }
    }
}

private func isInfSvg(value: Float64): Bool {
    value.isInf() && value > 0.0
}

private func animationStateAt(spec: SvgAnimationSpec, time: Float64): SvgAnimationState {
    if (isInfSvg(spec.begin) || time < spec.begin) {
        return SvgAnimationState(false, 0.0, 0)
    }
    let total = spec.totalDuration()
    let computedEnd = if (isInfSvg(total)) { Float64.Inf } else { spec.begin + total }
    let activeEnd = if (spec.end < computedEnd) { spec.end } else { computedEnd }
    if (!isInfSvg(activeEnd) && time >= activeEnd) {
        if (spec.freeze) {
            let iteration = if (spec.dur > 0.0 && !isInfSvg(spec.dur)) {
                Int64(maxFloat(0.0, ceil((activeEnd - spec.begin) / spec.dur) - 1.0))
            } else {
                0
            }
            return SvgAnimationState(true, 1.0, iteration)
        }
        return SvgAnimationState(false, 0.0, 0)
    }
    let local = time - spec.begin
    if (spec.dur <= 0.0 || isInfSvg(spec.dur)) {
        return SvgAnimationState(true, 0.0, 0)
    }
    var iteration = Int64(floor(local / spec.dur))
    if (iteration < 0) {
        iteration = 0
    }
    let progress = clampSvgUnit((local - Float64(iteration) * spec.dur) / spec.dur)
    SvgAnimationState(true, progress, iteration)
}

private func evaluateKeyframeValue(
    spec: SvgAnimationSpec,
    progress: Float64,
    base: String,
    warnings: ArrayList<String>
): String {
    if (spec.kind == SvgAnimationKind.Set) {
        return spec.element.attr("to") ?? base
    }
    let frames = effectiveFrames(spec, base)
    if (frames.size == 0) {
        return base
    }
    if (frames.size == 1) {
        return frames[0]
    }
    let times = effectiveKeyTimesForFrames(spec, frames, warnings)
    if (spec.calcMode == SvgCalcMode.Discrete) {
        var index = 0
        for (position in 0..times.size) {
            if (progress >= times[position]) {
                index = position
            }
        }
        return frames[index]
    }
    var segment = 0
    for (position in 0..times.size - 1) {
        if (progress >= times[position]) {
            segment = position
        }
    }
    if (segment >= frames.size - 1) {
        return frames[frames.size - 1]
    }
    let span = times[segment + 1] - times[segment]
    var local = if (span <= 0.0) { 1.0 } else { (progress - times[segment]) / span }
    local = clampSvgUnit(local)
    let mode = if (spec.calcMode == SvgCalcMode.Spline) { SvgCalcMode.Linear } else { spec.calcMode }
    interpolateAnimationValue(
        frames[segment],
        frames[segment + 1],
        local,
        mode,
        spec,
        segment,
        frames.size,
        warnings
    )
}

private func effectiveFrames(spec: SvgAnimationSpec, base: String): Array<String> {
    if (spec.values.size > 0) {
        return spec.values
    }
    let from = spec.element.attr("from") ?? base
    let to = match (spec.element.attr("to")) {
        case Some(value) => value
        case None => match (spec.element.attr("by")) {
            case Some(byValue) =>
                match ((tryParseSvgFloat(from), tryParseSvgFloat(byValue))) {
                    case (Some(fromNumber), Some(byNumber)) => formatSvgNumber(fromNumber + byNumber)
                    case _ => from
                }
            case None => from
        }
    }
    [from, to]
}

private func effectiveKeyTimes(
    spec: SvgAnimationSpec,
    count: Int64,
    warnings: ArrayList<String>
): Array<Float64> {
    if (spec.keyTimes.size == count) {
        return spec.keyTimes
    }
    if (spec.keyTimes.size > 0) {
        warnings.add("keyTimes 数量 ${spec.keyTimes.size} 与关键帧数量 ${count} 不一致，回退均匀分布")
    }
    let times = Array<Float64>(count, repeat: 0.0)
    for (index in 0..count) {
        times[index] = Float64(index) / Float64(count - 1)
    }
    times
}

/** `paced` 按相邻关键帧的数值距离生成时间分布，其余模式沿用 keyTimes。 */
private func effectiveKeyTimesForFrames(
    spec: SvgAnimationSpec,
    frames: Array<String>,
    warnings: ArrayList<String>
): Array<Float64> {
    if (spec.calcMode == SvgCalcMode.Paced && frames.size > 1) {
        return pacedKeyTimes(frames)
    }
    effectiveKeyTimes(spec, frames.size, warnings)
}

private func pacedKeyTimes(frames: Array<String>): Array<Float64> {
    let count = frames.size
    let distances = Array<Float64>(count - 1, repeat: 0.0)
    var total = 0.0
    for (index in 1..count) {
        let distance = animationValueDistance(frames[index - 1], frames[index])
        distances[index - 1] = distance
        total += distance
    }
    let times = Array<Float64>(count, repeat: 0.0)
    if (total <= 0.0) {
        for (index in 0..count) {
            times[index] = Float64(index) / Float64(count - 1)
        }
        return times
    }
    var walked = 0.0
    for (index in 1..count) {
        walked += distances[index - 1]
        times[index] = walked / total
    }
    times[count - 1] = 1.0
    times
}

private func animationValueDistance(first: String, second: String): Float64 {
    match ((tryParseSvgFloat(first), tryParseSvgFloat(second))) {
        case (Some(left), Some(right)) => return abs(right - left)
        case _ => ()
    }
    let firstList = tryParseSvgNumberArray(first.replace(",", " "))
    let secondList = tryParseSvgNumberArray(second.replace(",", " "))
    match ((firstList, secondList)) {
        case (Some(left), Some(right)) =>
            let common = if (left.size < right.size) { left.size } else { right.size }
            var total = 0.0
            for (index in 0..common) {
                total += abs(right[index] - left[index])
            }
            return total
        case _ => ()
    }
    match ((SvgColor.tryParse(first), SvgColor.tryParse(second))) {
        case (Some(left), Some(right)) =>
            let dr = Float64(right.red) - Float64(left.red)
            let dg = Float64(right.green) - Float64(left.green)
            let db = Float64(right.blue) - Float64(left.blue)
            let da = (right.alpha - left.alpha) * 255.0
            return sqrt(dr * dr + dg * dg + db * db + da * da)
        case _ => ()
    }
    if (first == second) { 0.0 } else { 1.0 }
}

private func interpolateAnimationValue(
    from: String,
    to: String,
    t: Float64,
    mode: SvgCalcMode,
    spec: SvgAnimationSpec,
    segment: Int64,
    frameCount: Int64,
    warnings: ArrayList<String>
): String {
    var local = t
    if (spec.calcMode == SvgCalcMode.Spline) {
        if (spec.keySplines.size == frameCount - 1 && segment < spec.keySplines.size) {
            let spline = spec.keySplines[segment]
            local = SvgInterpolator.splineValue(local, spline[0], spline[1], spline[2], spline[3])
        } else if (spec.keySplines.size != frameCount - 1) {
            warnings.add(
                "keySplines 数量 ${spec.keySplines.size} 与关键帧数量 ${frameCount} 不匹配，回退 linear"
            )
        }
    }
    match ((tryParseSvgFloat(from), tryParseSvgFloat(to))) {
        case (Some(first), Some(second)) =>
            return formatSvgNumber(SvgInterpolator.numeric(first, second, local, mode: mode))
        case _ => ()
    }
    match ((SvgColor.tryParse(from), SvgColor.tryParse(to))) {
        case (Some(first), Some(second)) =>
            return SvgInterpolator.color(first, second, local, mode: mode).toString()
        case _ => ()
    }
    match ((SvgPathData.tryParse(from), SvgPathData.tryParse(to))) {
        case (Some(first), Some(second)) =>
            match (SvgInterpolator.path(first, second, local)) {
                case Some(path) => return path.toString()
                case None => ()
            }
        case _ => ()
    }
    SvgInterpolator.stringValue(from, to, local, mode: mode)
}

private func evaluateTransformValue(
    spec: SvgAnimationSpec,
    progress: Float64,
    warnings: ArrayList<String>
): SvgTransform {
    let frames = effectiveFrames(spec, "translate(0 0)")
    if (frames.size == 0) {
        return SvgTransform.identity
    }
    if (frames.size == 1) {
        return parseAnimationTransform(spec, frames[0])
    }
    let times = effectiveKeyTimesForFrames(spec, frames, warnings)
    var segment = 0
    for (position in 0..times.size - 1) {
        if (progress >= times[position]) {
            segment = position
        }
    }
    if (segment >= frames.size - 1) {
        return parseAnimationTransform(spec, frames[frames.size - 1])
    }
    let span = times[segment + 1] - times[segment]
    let local = if (span <= 0.0) { 1.0 } else { clampSvgUnit((progress - times[segment]) / span) }
    let from = parseAnimationTransform(spec, frames[segment])
    let to = parseAnimationTransform(spec, frames[segment + 1])
    match (SvgInterpolator.transform(from, to, local)) {
        case Some(value) => value
        case None => if (local >= 0.5) { to } else { from }
    }
}

private func parseAnimationTransform(spec: SvgAnimationSpec, text: String): SvgTransform {
    let trimmed = text.trimAscii()
    if (trimmed.size == 0) {
        return SvgTransform.identity
    }
    if (trimmed.contains("(")) {
        return SvgTransform.parse(trimmed)
    }
    SvgTransform.parse(spec.transformType + "(" + trimmed + ")")
}

private func resolveMotionProgress(
    progress: Float64,
    keyPoints: Array<Float64>,
    keyTimes: Array<Float64>
): Float64 {
    let clamped = clampSvgUnit(progress)
    if (keyPoints.size == 0) {
        return clamped
    }
    if (keyPoints.size == 1) {
        return clampSvgUnit(keyPoints[0])
    }
    let times = if (keyTimes.size == keyPoints.size) {
        keyTimes
    } else {
        let uniform = Array<Float64>(keyPoints.size, repeat: 0.0)
        for (index in 0..keyPoints.size) {
            uniform[index] = Float64(index) / Float64(keyPoints.size - 1)
        }
        uniform
    }
    var segment = 0
    for (position in 0..times.size - 1) {
        if (clamped >= times[position]) {
            segment = position
        }
    }
    if (segment >= keyPoints.size - 1) {
        return clampSvgUnit(keyPoints[keyPoints.size - 1])
    }
    let span = times[segment + 1] - times[segment]
    let local = if (span <= 0.0) { 1.0 } else { clampSvgUnit((clamped - times[segment]) / span) }
    clampSvgUnit(keyPoints[segment] + (keyPoints[segment + 1] - keyPoints[segment]) * local)
}

private func sampleMotion(
    path: SvgPathData,
    progress: Float64,
    rotate: String,
    keyPoints: Array<Float64>,
    keyTimes: Array<Float64>
): Array<Float64> {
    let contours = flattenPathData(path, SvgMatrix.identity, 0.1)
    if (contours.size == 0 || contours[0].size == 0) {
        return [0.0, 0.0, 0.0]
    }
    let points = contours[0]
    if (points.size == 1) {
        return [points[0].x, points[0].y, 0.0]
    }
    var total = 0.0
    for (index in 1..points.size) {
        total += distanceBetween(points[index - 1], points[index])
    }
    let target = resolveMotionProgress(progress, keyPoints, keyTimes) * total
    var walked = 0.0
    for (index in 1..points.size) {
        let segmentLength = distanceBetween(points[index - 1], points[index])
        if (walked + segmentLength >= target || index == points.size - 1) {
            let local = if (segmentLength <= 0.0) { 0.0 } else { (target - walked) / segmentLength }
            let x = points[index - 1].x + (points[index].x - points[index - 1].x) * local
            let y = points[index - 1].y + (points[index].y - points[index - 1].y) * local
            let angle = atan2(points[index].y - points[index - 1].y, points[index].x - points[index - 1].x) *
                180.0 / 3.141592653589793
            let rotation = match (rotate.trimAscii().toAsciiLower()) {
                case "auto" => angle
                case "auto-reverse" => angle + 180.0
                case _ => tryParseSvgFloat(rotate) ?? 0.0
            }
            return [x, y, rotation]
        }
        walked += segmentLength
    }
    [points[points.size - 1].x, points[points.size - 1].y, 0.0]
}

private func distanceBetween(first: SvgPoint, second: SvgPoint): Float64 {
    let dx = second.x - first.x
    let dy = second.y - first.y
    sqrt(dx * dx + dy * dy)
}

private func maxFloat(first: Float64, second: Float64): Float64 {
    if (first > second) { first } else { second }
}

private func cloneSvgDocument(source: SvgDocument): SvgDocument {
    let clonedRoot = match (cloneSvgElement(source.root)) {
        case root: SvgRoot => root
        case _ => throw SvgException("根元素克隆失败", kind: SvgErrorKind.InvalidValue)
    }
    let document = SvgDocument(clonedRoot)
    document.declaration = source.declaration
    document.doctype = source.doctype
    for (node in source.prolog) {
        document.prolog.add(cloneSvgNode(node))
    }
    for (node in source.epilog) {
        document.epilog.add(cloneSvgNode(node))
    }
    for (warning in source.warnings) {
        document.warnings.add(warning)
    }
    document
}

private func cloneSvgElement(element: SvgElement): SvgElement {
    let clone = match (element) {
        case unknown: SvgUnknownElement => SvgUnknownElement(unknown.rawName)
        case _ =>
            match (SvgTag.create(element.tag)) {
                case Some(created) => created
                case None => SvgElement(element.tag, namespace: element.namespace)
            }
    }
    for (attribute in element.attributes) {
        clone.appendAttribute(attribute.name, attribute.value)
    }
    for (node in element.children) {
        clone.appendChild(cloneSvgNode(node))
    }
    clone
}

private func cloneSvgNode(node: SvgNode): SvgNode {
    match (node) {
        case ElementNode(element) => SvgNode.ElementNode(cloneSvgElement(element))
        case TextNode(text) => SvgNode.TextNode(text)
        case CDataNode(text) => SvgNode.CDataNode(text)
        case CommentNode(text) => SvgNode.CommentNode(text)
        case PiNode(target, data) => SvgNode.PiNode(target, data)
    }
}
