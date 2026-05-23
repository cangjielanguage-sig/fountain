package fountain::f_hydra

import std.ffi.CPointer
import std.sync.Mutex
import fountain.f_hydra.ffi.faiss_types.FaissIndex
import fountain.f_hydra.ffi.faiss_bridge.*
import fountain.f_hydra.ffi.ffi_check.FfiCheck

// HNSW dense vector index via Faiss C library.
// All Faiss operations are protected by synchronized(lock) for thread safety.
public class DenseIndexer {
    private let handle: CPointer<FaissIndex>
    private let dim: Int64
    private let lock: Mutex
    private var indexCount: Int64

    // Create HNSW index with given dimension and M (neighbor count).
    // efConstruction is set after index creation via Faiss parameter space.
    public init(dim: Int64, M: Int64, efConstruction: Int64) {
        this.dim = dim
        this.lock = Mutex()
        this.indexCount = 0

        let raw = unsafe { faiss_IndexHNSWFlat_new(dim as UInt64, M) }
        this.handle = FfiCheck.checkNotNull(raw, "faiss_IndexHNSWFlat_new")
    }

    // Build index from embedding vectors.
    // Flattens Array<Array<Float32>> to a single Float32 array for Faiss.
    public func buildIndex(embeddings: Array<Array<Float32>>) {
        let n = embeddings.size as Int64
        if (n == 0) { return }

        let flat = flattenEmbeddings(embeddings)
        synchronized(this.lock) {
            let ret = unsafe { faiss_Index_add(this.handle, n, flat.toCPointer()) }
            FfiCheck.checkFaissReturn(ret, "faiss_Index_add")
            this.indexCount += n
        }
    }

    // Batch build: processes embeddings in batches to avoid double memory.
    // Each batch: create flat array → add to Faiss → release batch memory.
    public func buildIndexBatched(
        embeddings: Array<Array<Float32>>,
        batchSize: Int64 = 1000
    ) {
        let total = embeddings.size as Int64
        var start: Int64 = 0
        while (start < total) {
            let end = if (start + batchSize < total) { start + batchSize } else { total }
            let batchN = end - start
            let batch = Array<Array<Float32>>(batchN) { i => embeddings[start + i] }
            let flat = flattenEmbeddings(batch)

            synchronized(this.lock) {
                let ret = unsafe { faiss_Index_add(this.handle, batchN, flat.toCPointer()) }
                FfiCheck.checkFaissReturn(ret, "faiss_Index_add batched")
                this.indexCount += batchN
            }
            start = end
        }
    }

    // Search for k nearest neighbors.
    // Returns Array of (docId, distance) tuples sorted by distance (ascending).
    public func search(
        query: Array<Float32>,
        k: Int64
    ): Array<(Int64, Float32)> {
        let distances = Array<Float32>(k, init: 0.0)
        let labels = Array<Int64>(k, init: -1)

        synchronized(this.lock) {
            let ret = unsafe {
                faiss_Index_search(
                    this.handle,
                    1,                          // n = 1 query
                    query.toCPointer(),
                    k,
                    distances.toCPointer(),
                    labels.toCPointer()
                )
            }
            FfiCheck.checkFaissReturn(ret, "faiss_Index_search")
        }

        Array<(Int64, Float32)>(k) { i => (labels[i], distances[i]) }
    }

    // Persist index to file
    public func save(path: String) {
        synchronized(this.lock) {
            let ret = unsafe { faiss_write_index_fname(this.handle, path.toCString()) }
            FfiCheck.checkFaissReturn(ret, "faiss_write_index_fname")
        }
    }

    // Number of indexed vectors
    public func count(): Int64 {
        this.indexCount
    }

    // Release the Faiss C index handle
    public func close() {
        synchronized(this.lock) {
            unsafe { faiss_Index_free(this.handle) }
        }
    }

    // Flatten Array<Array<Float32>> to contiguous Float32 array
    private func flattenEmbeddings(embeddings: Array<Array<Float32>>): Array<Float32> {
        let n = embeddings.size
        if (n == 0) { return Array<Float32>() }
        let d = embeddings[0].size
        Array<Float32>(n * d) { i => embeddings[i / d][i % d] }
    }
}
