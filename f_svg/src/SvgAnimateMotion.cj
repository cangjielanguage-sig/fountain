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

/** `animateMotion` 的路径引用子元素。 */
public class SvgMpath <: SvgElement {
    public init() {
        super("mpath")
    }

    public mut prop href: ?String {
        get() {
            readSvgHref(this)
        }
        set(value) {
            match (value) {
                case Some(link) =>
                    this.removeAttr("href")
                    this.removeAttr(SvgNamespaces.XLINK, "href")
                    this.setAttr("href", link)
                case None =>
                    this.removeAttr("href")
                    this.removeAttr(SvgNamespaces.XLINK, "href")
            }
        }
    }
}

/** 类型化 `<animateMotion>`：路径、关键点、旋转与 `mpath` 子元素。 */
public class SvgAnimateMotion <: SvgAnimate {
    public init() {
        super("animateMotion")
    }

    public mut prop path: ?String {
        get() {
            this.attr("path")
        }
        set(value) {
            this.writeOptionalAttribute("path", value)
        }
    }

    public mut prop keyPoints: ?String {
        get() {
            this.attr("keyPoints")
        }
        set(value) {
            this.writeOptionalAttribute("keyPoints", value)
        }
    }

    /**
     * 旋转方式。
     *
     * 属性缺失时 getter 返回 `Auto`，但构造时不写 `rotate`；
     * 只有 setter 被调用才落盘。
     */
    public mut prop rotate: SvgMotionRotate {
        get() {
            match (this.attr("rotate")) {
                case Some(text) =>
                    match (text.trimAscii()) {
                        case "auto" => SvgMotionRotate.Auto
                        case "auto-reverse" => SvgMotionRotate.AutoReverse
                        case _ =>
                            match (tryParseSvgFloat(text)) {
                                case Some(angle) => SvgMotionRotate.Fixed(angle)
                                case None => SvgMotionRotate.Auto
                            }
                    }
                case None => SvgMotionRotate.Auto
            }
        }
        set(value) {
            this.setAttr("rotate", value.toString())
        }
    }

    /** 追加唯一的 `mpath` 子元素；重复调用替换旧引用。 */
    public func mpath(href: String): SvgMpath {
        var index = this.children.size - 1
        while (index >= 0) {
            let isMpath = match (this.children[index]) {
                case ElementNode(element) => element.tag == "mpath"
                case _ => false
            }
            if (isMpath) {
                this.children.remove(at: index)
            }
            index--
        }
        let child = SvgMpath()
        child.href = href
        this.appendElement(child)
        child
    }
}
