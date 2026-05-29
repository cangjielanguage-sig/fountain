package fountain::f_hydra

import std.collection.ArrayList

// Posting list for sparse inverted index.
// Each term has a list of (docId, weight) pairs, sorted by docId.
public class PostingList {
    private var docIds: ArrayList<Int64>
    private var weights: ArrayList<Float32>
    private var skipPointers: ArrayList<Int64>

    public init() {
        this.docIds = ArrayList<Int64>()
        this.weights = ArrayList<Float32>()
        this.skipPointers = ArrayList<Int64>()
    }

    // Add (docId, weight) entry
    public func add(docId: Int64, weight: Float32) {
        this.docIds.add(docId)
        this.weights.add(weight)
    }

    // Sort entries by docId ascending (also reorders weights)
    public func sortByDocId() {
        let n = this.docIds.size
        var indices = Array<Int64>(n) { i => i }
        indices.sort({ a: Int64, b: Int64 => this.docIds[a] < this.docIds[b] ? -1 : 1 })
        this.docIds = ArrayList<Int64>(n) { i => this.docIds[indices[i]] }
        this.weights = ArrayList<Float32>(n) { i => this.weights[indices[i]] }
    }

    // Build skip pointers at intervals of sqrt(N).
    // Skip pointers accelerate multi-term query merging.
    public func buildSkipPointers() {
        let n = this.docIds.size
        if (n <= 1) { return }
        let step = max(1, sqrt(n as Float32) as Int64)
        this.skipPointers = ArrayList<Int64>()
        var pos: Int64 = 0
        while (pos < n) {
            this.skipPointers.add(pos)
            pos += step
        }
    }

    // Get first position >= target using skip pointers
    public func advanceTo(target: Int64): Int64 {
        let n = this.docIds.size
        if (n == 0) { return -1 }

        // Use skip pointers to jump
        let spSize = this.skipPointers.size
        var start: Int64 = 0
        for (i in 0..spSize) {
            let spPos = this.skipPointers[i]
            if (this.docIds[spPos] >= target) {
                start = spPos
                break
            }
        }

        // Linear scan from start
        var pos = start
        while (pos < n) {
            if (this.docIds[pos] >= target) {
                return pos
            }
            pos += 1
        }
        -1
    }

    // Accessors
    public func getDocId(pos: Int64): Int64 { this.docIds[pos] }
    public func getWeight(pos: Int64): Float32 { this.weights[pos] }
    public func size(): Int64 { this.docIds.size }
}
