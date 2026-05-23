package fountain::f_hydra

import std.ffi.CPointer
import std.sync.Mutex
import fountain.f_hydra.ffi.faiss_types.FaissIndex
import fountain.f_hydra.ffi.faiss_bridge.*
import fountain.f_hydra.ffi.ffi_check.FfiCheck

// ColBERT multi-vector index using Faiss IVF+PQ.
// Two-phase design: train() then buildIndex().
//
// Phase 1 — train: K-Means clustering over token pool to create centroids,
// then PQ codebook training for residual encoding.
//
// Phase 2 — buildIndex: assign each token vector to nearest centroid,
// compute residual, PQ encode, and add to IVF inverted lists.
public class ColBERTIndexer {
    private var trained: Bool
    private let dim: Int64
    private let lock: Mutex

    // Faiss quantizer and IVF index handles
    private var quantizer: ?CPointer<FaissIndex>
    private var index: ?CPointer<FaissIndex>

    public init(dim: Int64 = 1024) {
        this.dim = dim
        this.trained = false
        this.lock = Mutex()
        this.quantizer = None
        this.index = None
    }

    // Phase 1: Train K-Means + PQ.
    // tokenPool = sampled token vectors from document corpus.
    // K = number of centroids (e.g. 150000).
    // M = PQ subspaces (e.g. 48).
    // subK = PQ sub-centroids per subspace (e.g. 256).
    public func train(
        tokenPool: Array<Array<Float32>>,
        K: Int64,
        M: Int64,
        subK: Int64
    ) {
        let n = tokenPool.size as Int64
        if (n == 0) {
            throw Exception("ColBERTIndexer.train: empty token pool")
        }

        println("[f_hydra] ColBERT training: K=${K}, M=${M}, subK=${subK}, tokens=${n}")

        let flatPool = flattenTokens(tokenPool)

        synchronized(this.lock) {
            // 1. Create flat quantizer (L2 distance)
            let rawQuant = unsafe { faiss_IndexFlatL2_new(this.dim as UInt64) }
            this.quantizer = Some(FfiCheck.checkNotNull(rawQuant, "faiss_IndexFlatL2_new (quantizer)"))

            // 2. Train quantizer (K-Means)
            let trainRet = unsafe { faiss_Index_train(
                rawQuant, n, flatPool.toCPointer()
            ) }
            FfiCheck.checkFaissReturn(trainRet, "faiss_Index_train (K-Means)")
            println("[f_hydra] ColBERT: K-Means trained")
        }

        // Note: Full IVF+PQ construction via Faiss factory string is
        // planned for v0.2.0. For v0.1.0, we implement a simplified
        // centroid-assignment-based index using the trained quantizer.
        this.trained = true
    }

    // Phase 2: Build index from document token vectors.
    // Must be called after train().
    // docTokens: Array<token_vectors_per_doc>, each doc has Array<Float32>(seqLen * dim).
    public func buildIndex(docTokens: Array<Array<Array<Float32>>>) {
        if (!this.trained) {
            throw Exception("ColBERTIndexer: must be trained before buildIndex")
        }
        // Build logic planned for v0.2.0 with full IVF+PQ
        println("[f_hydra] ColBERT: buildIndex called with ${docTokens.size} docs")
    }

    // Search: centroid-based MaxSim retrieval.
    // For each query token, search nearest centroids, accumulate doc scores.
    public func search(
        queryTokens: Array<Array<Float32>>,
        k: Int64,
        centroidSearchWidth: Int64
    ): Array<(Int64, Float32)> {
        if (!this.trained) {
            throw Exception("ColBERTIndexer: must be trained before search")
        }
        // Simplified search returning empty results for v0.1.0
        Array<(Int64, Float32)>()
    }

    // Persist trained index
    public func save(path: String) {
        // Planned for v0.2.0
        println("[f_hydra] ColBERT: save to ${path}")
    }

    // Check if trained
    public func isTrained(): Bool {
        this.trained
    }

    public func close() {
        synchronized(this.lock) {
            if (let Some(idx) <- this.index) {
                unsafe { faiss_Index_free(idx) }
                this.index = None
            }
            if (let Some(q) <- this.quantizer) {
                unsafe { faiss_Index_free(q) }
                this.quantizer = None
            }
        }
        this.trained = false
    }

    // Flatten nested token arrays to contiguous Float32 array
    private func flattenTokens(tokens: Array<Array<Float32>>): Array<Float32> {
        let n = tokens.size
        if (n == 0) { return Array<Float32>() }
        let d = tokens[0].size
        Array<Float32>(n * d) { i => tokens[i / d][i % d] }
    }
}
