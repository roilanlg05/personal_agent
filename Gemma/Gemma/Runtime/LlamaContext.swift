import Foundation
import llama

public enum LlamaError: LocalizedError, Sendable {
    case modelNotFound(String)
    case couldNotInitializeModel
    case couldNotInitializeContext
    case decodeFailed
    case contextLimitExceeded

    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let path):
            return "Modelo GGUF no encontrado en: \(path)"
        case .couldNotInitializeModel:
            return "No se pudo cargar el modelo GGUF (formato corrupto o memoria insuficiente)."
        case .couldNotInitializeContext:
            return "No se pudo inicializar el contexto de llama.cpp."
        case .decodeFailed:
            return "Error durante la decodificación de tokens en llama.cpp."
        case .contextLimitExceeded:
            return "Se excedió la capacidad de la ventana de contexto."
        }
    }
}

private func llama_batch_clear(_ batch: inout llama_batch) {
    batch.n_tokens = 0
}

private func llama_batch_add(
    _ batch: inout llama_batch,
    _ id: llama_token,
    _ pos: llama_pos,
    _ seq_ids: [llama_seq_id],
    _ logits: Bool
) {
    let idx = Int(batch.n_tokens)
    batch.token[idx] = id
    batch.pos[idx] = pos
    batch.n_seq_id[idx] = Int32(seq_ids.count)
    if let seqPtr = batch.seq_id[idx] {
        for i in 0..<seq_ids.count {
            seqPtr[Int(i)] = seq_ids[i]
        }
    }
    batch.logits[idx] = logits ? 1 : 0
    batch.n_tokens += 1
}

public actor LlamaContext {
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var sampling: UnsafeMutablePointer<llama_sampler>?
    private var batch: llama_batch
    private var batchAllocated: Int32 = 0
    private var tokensList: [llama_token] = []
    private var temporaryInvalidCChars: [CChar] = []
    private var nLen: Int32 = 4096
    private var nCur: Int32 = 0
    private var nDecode: Int32 = 0
    private var pendingTokens: [llama_token] = []
    private var lastSampledToken: llama_token? = nil
    private var isDoneState: Bool = false

    public init(model: OpaquePointer, context: OpaquePointer, contextLength: Int32 = 4096) {
        self.model = model
        self.context = context
        self.nLen = contextLength
        self.batchAllocated = 2048
        self.batch = llama_batch_init(2048, 0, 1)
        self.vocab = llama_model_get_vocab(model)

        let sparams = llama_sampler_chain_default_params()
        let chain = llama_sampler_chain_init(sparams)
        // Repetition penalties first to prevent token degenerate loops (like <<<<<<<)
        llama_sampler_chain_add(chain, llama_sampler_init_penalties(64, 1.15, 0.1, 0.1))
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.9, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(0.7))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32(Date().timeIntervalSince1970)))
        self.sampling = chain
    }

    deinit {
        if let sampling {
            llama_sampler_free(sampling)
        }
        llama_batch_free(batch)
        if let context {
            llama_free(context)
        }
        if let model {
            llama_model_free(model)
        }
        llama_backend_free()
    }

    public static func createContext(path: String, contextLength: Int = 4096, useGPU: Bool = true) throws -> LlamaContext {
        guard FileManager.default.fileExists(atPath: path) else {
            throw LlamaError.modelNotFound(path)
        }

        llama_backend_init()
        var modelParams = llama_model_default_params()
        if useGPU {
            #if targetEnvironment(simulator)
            modelParams.n_gpu_layers = 0
            #else
            modelParams.n_gpu_layers = 99 // Metal offload
            #endif
        } else {
            modelParams.n_gpu_layers = 0
        }
        modelParams.use_mlock = false // Disable on iOS to avoid system-wide jetsam pressure / swap thrashing

        guard let model = llama_model_load_from_file(path, modelParams) else {
            throw LlamaError.couldNotInitializeModel
        }

        let nThreads = max(1, min(6, ProcessInfo.processInfo.processorCount - 1))
        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = UInt32(contextLength)
        ctxParams.n_batch = UInt32(contextLength)
        ctxParams.n_ubatch = 512
        ctxParams.n_threads = Int32(nThreads)
        ctxParams.n_threads_batch = Int32(nThreads)
        ctxParams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED
        ctxParams.offload_kqv = true

        guard let context = llama_init_from_model(model, ctxParams) else {
            llama_model_free(model)
            throw LlamaError.couldNotInitializeContext
        }

        return LlamaContext(model: model, context: context, contextLength: Int32(contextLength))
    }

    public func tokenize(text: String, addBOS: Bool) -> [llama_token] {
        guard let vocab else { return [] }
        let utf8Count = text.utf8.count
        let capacity = utf8Count + (addBOS ? 1 : 0) + 16
        let tokens = UnsafeMutablePointer<llama_token>.allocate(capacity: capacity)
        defer { tokens.deallocate() }

        let count = llama_tokenize(vocab, text, Int32(utf8Count), tokens, Int32(capacity), addBOS, true)
        guard count > 0 else { return [] }
        return (0..<count).map { tokens[Int($0)] }
    }

    public func tokenToPiece(token: llama_token) -> [CChar] {
        guard let vocab else { return [] }
        let bufSize = 16
        let buf = UnsafeMutablePointer<Int8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        buf.initialize(repeating: 0, count: bufSize)

        let nTokens = llama_token_to_piece(vocab, token, buf, Int32(bufSize), 0, true)
        if nTokens < 0 {
            let actualSize = Int(-nTokens)
            let dynamicBuf = UnsafeMutablePointer<Int8>.allocate(capacity: actualSize)
            defer { dynamicBuf.deallocate() }
            dynamicBuf.initialize(repeating: 0, count: actualSize)
            let count = llama_token_to_piece(vocab, token, dynamicBuf, Int32(actualSize), 0, true)
            return Array(UnsafeBufferPointer(start: dynamicBuf, count: Int(count)))
        } else {
            return Array(UnsafeBufferPointer(start: buf, count: Int(nTokens)))
        }
    }

    public func setTemperature(_ temp: Float) {
        if let sampling {
            llama_sampler_free(sampling)
        }
        let sparams = llama_sampler_chain_default_params()
        let chain = llama_sampler_chain_init(sparams)
        // Repetition penalties first to prevent token degenerate loops
        llama_sampler_chain_add(chain, llama_sampler_init_penalties(64, 1.15, 0.1, 0.1))
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.9, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(max(0.01, temp)))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32(Date().timeIntervalSince1970)))
        self.sampling = chain
    }

    public func completionInit(prompt: String, temperature: Float = 0.2,
                               contextLimit: Int? = nil, outputReservation: Int = 512) throws {
        guard let context else { throw LlamaError.couldNotInitializeContext }
        setTemperature(temperature)
        llama_memory_clear(llama_get_memory(context), true)
        if let sampling {
            llama_sampler_reset(sampling)
        }
        tokensList = tokenize(text: prompt, addBOS: true)
        temporaryInvalidCChars.removeAll()

        let nCtx = Int(llama_n_ctx(context))
        let maxPromptTokens: Int
        if let contextLimit {
            maxPromptTokens = min(nCtx, contextLimit) - outputReservation
            guard maxPromptTokens >= tokensList.count else { throw LlamaError.contextLimitExceeded }
        } else {
            maxPromptTokens = max(512, nCtx - 512)
        }
        if tokensList.count > maxPromptTokens {
            // Sliding window: preserve system/instruction header and keep latest user tail
            let keepHeader = min(500, tokensList.count / 3)
            let keepTail = maxPromptTokens - keepHeader
            let header = Array(tokensList.prefix(keepHeader))
            let tail = Array(tokensList.suffix(keepTail))
            tokensList = header + tail
        }

        let nBatch = Int(llama_n_batch(context))
        let required = Int32(min(nBatch, tokensList.count) + 64)
        if required > batchAllocated {
            llama_batch_free(batch)
            batch = llama_batch_init(required, 0, 1)
            batchAllocated = required
        }

        var p = 0
        var lastBatchTokenIdx: Int32 = 0
        while p < tokensList.count {
            let chunkEnd = min(p + nBatch, tokensList.count)
            let chunkSize = chunkEnd - p
            llama_batch_clear(&batch)
            for i in 0..<chunkSize {
                let isLastInPrompt = (p + i == tokensList.count - 1)
                llama_batch_add(&batch, tokensList[p + i], Int32(p + i), [0], isLastInPrompt)
            }
            lastBatchTokenIdx = batch.n_tokens - 1
            if llama_decode(context, batch) != 0 {
                throw LlamaError.decodeFailed
            }
            p += chunkSize
        }
        nCur = Int32(tokensList.count)
        nDecode = 0

        pendingTokens.removeAll()
        isDoneState = false

        if let sampling {
            let firstToken = llama_sampler_sample(sampling, context, lastBatchTokenIdx)
            llama_sampler_accept(sampling, firstToken)
            tokensList.append(firstToken)
            lastSampledToken = firstToken
            pendingTokens.append(firstToken)
        }
    }

    private func findDraftTokens(lastToken: llama_token) -> [llama_token] {
        let nMin = 3 // size of n-gram key to match in past tokens
        let nMax = 3 // number of draft tokens to predict
        let count = tokensList.count
        if count <= nMin + nMax + 2 {
            return []
        }

        var pattern: [llama_token] = []
        pattern.reserveCapacity(nMin)
        for j in (count - nMin + 1)..<count {
            pattern.append(tokensList[j])
        }
        pattern.append(lastToken)

        var matchPos = -1
        let searchEnd = count - nMin - 1
        if searchEnd > 0 {
            let start = max(1, searchEnd - 1024)
            for j in (start...searchEnd).reversed() {
                var match = true
                for k in 0..<nMin {
                    if tokensList[j + k] != pattern[k] {
                        match = false
                        break
                    }
                }
                if match {
                    matchPos = j
                    break
                }
            }
        }

        guard matchPos >= 0 else { return [] }
        let draftStart = matchPos + nMin
        let draftEnd = min(draftStart + nMax, count)
        guard draftStart < draftEnd else { return [] }
        return Array(tokensList[draftStart..<draftEnd])
    }

    public func completionNextToken() throws -> (tokenStr: String, isDone: Bool) {
        guard let context, let vocab, let sampling else {
            return ("", true)
        }
        if isDoneState {
            return ("", true)
        }

        if pendingTokens.isEmpty {
            guard let lastToken = lastSampledToken else {
                isDoneState = true
                return ("", true)
            }

            let drafts = findDraftTokens(lastToken: lastToken)
            if drafts.isEmpty {
                // Baseline 1-token decode
                llama_batch_clear(&batch)
                llama_batch_add(&batch, lastToken, nCur, [0], true)
                nCur += 1
                nDecode += 1
                if llama_decode(context, batch) != 0 {
                    throw LlamaError.decodeFailed
                }
                let nextToken = llama_sampler_sample(sampling, context, 0)
                llama_sampler_accept(sampling, nextToken)
                tokensList.append(nextToken)
                lastSampledToken = nextToken
                pendingTokens.append(nextToken)
            } else {
                // Speculative decode: dispatch target + drafts in parallel Metal batch
                let required = Int32(drafts.count + 8)
                if required > batchAllocated {
                    llama_batch_free(batch)
                    batch = llama_batch_init(required, 0, 1)
                    batchAllocated = required
                }
                llama_batch_clear(&batch)
                llama_batch_add(&batch, lastToken, nCur, [0], true)
                for (i, d) in drafts.enumerated() {
                    llama_batch_add(&batch, d, nCur + 1 + Int32(i), [0], true)
                }
                if llama_decode(context, batch) != 0 {
                    throw LlamaError.decodeFailed
                }

                var acceptedCount = 0
                for i in 0..<drafts.count {
                    let sampled = llama_sampler_sample(sampling, context, Int32(i))
                    llama_sampler_accept(sampling, sampled)
                    tokensList.append(sampled)
                    pendingTokens.append(sampled)
                    lastSampledToken = sampled
                    acceptedCount += 1
                    if sampled != drafts[i] || llama_vocab_is_eog(vocab, sampled) {
                        break
                    }
                }
                if acceptedCount == drafts.count && !llama_vocab_is_eog(vocab, lastSampledToken!) {
                    let bonus = llama_sampler_sample(sampling, context, Int32(drafts.count))
                    llama_sampler_accept(sampling, bonus)
                    tokensList.append(bonus)
                    pendingTokens.append(bonus)
                    lastSampledToken = bonus
                    acceptedCount += 1
                }

                let totalInBatch = 1 + drafts.count
                let rejected = totalInBatch - acceptedCount
                if rejected > 0 {
                    llama_memory_seq_rm(llama_get_memory(context), 0, nCur + Int32(acceptedCount), -1)
                }
                nCur += Int32(acceptedCount)
                nDecode += Int32(acceptedCount)
            }
        }

        guard !pendingTokens.isEmpty else {
            return ("", true)
        }

        let token = pendingTokens.removeFirst()
        if llama_vocab_is_eog(vocab, token) || nCur >= nLen {
            isDoneState = true
            let flush = String(cString: temporaryInvalidCChars + [0])
            temporaryInvalidCChars.removeAll()
            return (flush, true)
        }

        let piece = tokenToPiece(token: token)
        temporaryInvalidCChars.append(contentsOf: piece)

        var tokenStr = ""
        if let string = String(validatingUTF8: temporaryInvalidCChars + [0]) {
            temporaryInvalidCChars.removeAll()
            tokenStr = string
        } else if let validIdx = (0..<temporaryInvalidCChars.count).first(where: {
            $0 > 0 && String(validatingUTF8: Array(temporaryInvalidCChars.suffix($0)) + [0]) != nil
        }) {
            tokenStr = String(cString: temporaryInvalidCChars + [0])
            temporaryInvalidCChars.removeAll()
        }

        if tokenStr.contains("<end_of_turn>") || tokenStr.contains("<|end_of_turn|>") || tokenStr.contains("<turn|>") {
            isDoneState = true
            return ("", true)
        }

        return (tokenStr, false)
    }

    public func clear() {
        tokensList.removeAll()
        temporaryInvalidCChars.removeAll()
        pendingTokens.removeAll()
        lastSampledToken = nil
        isDoneState = false
        nCur = 0
        nDecode = 0
        if let context {
            llama_memory_clear(llama_get_memory(context), true)
        }
        if let sampling {
            llama_sampler_reset(sampling)
        }
    }
}

