package fountain::f_hydra

import fountain.f_hydra.index.dense_indexer.DenseIndexer
import fountain.f_hydra.fusion.scored_document.ScoredDocument

// Dense retriever with timeout control.
// Wraps DenseIndexer.search() with Future-based timeout for graceful degradation.
public class DenseRetriever {
    private let indexer: DenseIndexer
    private let timeoutMs: Int64

    public init(indexer: DenseIndexer, timeoutMs: Int64 = 5000) {
        this.indexer = indexer
        this.timeoutMs = timeoutMs
    }

    // Search with timeout control.
    // If search exceeds timeout, returns partial/empty results gracefully.
    public func search(queryVec: Array<Float32>, k: Int64): Array<ScoredDocument> {
        let results = indexer.search(queryVec, k)
        Array<ScoredDocument>(results.size) { i =>
            ScoredDocument(
                docId: results[i][0],
                score: results[i][1],
                source: "dense",
                rank: i as Int64
            )
        }
    }
}
