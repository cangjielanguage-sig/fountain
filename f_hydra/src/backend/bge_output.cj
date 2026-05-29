package fountain::f_hydra

import std.collection.HashMap

public struct BgeOutput {
    public let denseVec: Array<Float32>
    public let sparseVec: HashMap<Int64, Float32>
    public let colbertVecs: Array<Array<Float32>>
}
