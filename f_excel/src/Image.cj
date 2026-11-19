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
package fountain::f_excel

import std.fs.{File, Path}

/** M1.5 支持的图片格式（按文件扩展名判定）。 */
public enum ImageFormat <: ToString {
    | Png
    | Jpeg

    public func toString(): String {
        match (this) {
            case Png => "png"
            case Jpeg => "jpeg"
        }
    }

    internal func extension(): String {
        match (this) {
            case Png => "png"
            case Jpeg => "jpeg"
        }
    }

    internal func contentType(): String {
        match (this) {
            case Png => "image/png"
            case Jpeg => "image/jpeg"
        }
    }
}

/** 一张锚定到单元格区域的图片。 */
internal class SheetImage {
    let data: Array<Byte>
    let format: ImageFormat
    let from: CellRef
    let to: CellRef

    init(data: Array<Byte>, format: ImageFormat, from: CellRef, to: CellRef) {
        this.data = data
        this.format = format
        this.from = from
        this.to = to
    }
}

internal func imageFormatOf(path: Path): ImageFormat {
    let name = path.toString().toAsciiLower()
    if (name.endsWith(".png")) {
        return ImageFormat.Png
    }
    if (name.endsWith(".jpg") || name.endsWith(".jpeg")) {
        return ImageFormat.Jpeg
    }
    throw ExcelException("不支持的图片格式（仅 png / jpg）：${path}")
}

/** `Worksheet.addImage` 的公共入口实现，转成内部 [SheetImage]。 */
internal func readImage(path: Path): (Array<Byte>, ImageFormat) {
    let format = imageFormatOf(path)
    let data = File.readFrom(path)
    if (data.size == 0) {
        throw ExcelException("图片为空：${path}")
    }
    (data, format)
}
