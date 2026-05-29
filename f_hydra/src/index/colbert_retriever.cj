package fountain::f_hydra

import fountain.f_hydra.index.colbert_indexer.ColBERTIndexer
import fountain.f_hydra.fusion.scored_document.ScoredDocument

// ColBERT MaxSim retriever with timeout control.
// Wraps ColBERTIndexer.search() for use by HybridSearchEngine.
public class ColBERTRetriever {
    private let indexer: ColBERTIndexer

    public init(indexer: ColBERTIndexer) {
        this.indexer = indexer
    }

    // Search with ColBERT query token vectors.
    // centroidSearchWidth controls how many centroids to probe per token.
    public func search(
        queryTokens: Array<Array<Float32>>,
        k: Int64,
        centroidSearchWidth: Int64
    ): Array<ScoredDocument> {
        if (!indexer.isTrained()) {
            return Array<ScoredDocument>()
        }
        let raw = indexer.search(queryTokens, k, centroidSearchWidth)
        Array<ScoredDocument>(raw.size) { i =>
            ScoredDocument(
                docId: raw[i][0],
                score: raw[i][1] as Float32,
                source: "colbert",
                rank: i as Int64
            )
        }
    }
}
