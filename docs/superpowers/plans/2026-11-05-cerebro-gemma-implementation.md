# Cerebro de Gemma — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Execute task-by-task using a fresh implementer and an independent spec-compliance/code-quality reviewer. Steps use checkbox syntax.

**Goal:** Implement the approved external brain: faithful and revisable memory, immediate learning, compact conversational context, persistent agent identity, tentative affect, associative recall, verified procedures, prospective task state and provider-independent app/gateway integration.

**Architecture:** Keep the existing Swift/SQLite service and HTTP compatibility. Add a dependency-light shared BrainContract target, transactional evidence/claim stores and higher-level brain services, then integrate the server gateway and native app. Use additive migrations and source-bound, revisioned projections into legacy nodes; candidate generation never sends notifications or performs outside actions.

**Tech Stack:** Swift 5.10+ package, Foundation, existing GRDB/Hummingbird/HTTPTypes, SQLite/FTS5, existing embedding/model protocols, native SwiftUI app and XCTest. Do not add graph/vector servers or new model providers as requirements.

**Spec:** `docs/superpowers/plans/2026-11-05-cerebro-gemma.md` (approved design). Product-delivery boundary: `docs/superpowers/specs/00-roadmap.md` section 8; S14 transport/push/weather connectors remain separate from the brain memory contract.

## Global Constraints

- Work only in isolated app `/Users/hashdown/Projects/personal_agent/.worktrees/gemma-brain-20261105` and nested independent backend git worktree `gemma-memory`. Preserve original dirty checkouts, installed Safari behavior and live HomeLab data.
- Existing `self:user` is the user. Agent identity is `self:agent`; relationship identity is `relationship:user:agent`. Never merge their claims by label.
- Keep `/v1/memory/*`, `/v1/transcript/*`, existing schedule/config/connection-services endpoints and `/v1/agent/turn` request/`{reply}` response compatibility. Recall still emits `core`, `recall`, `summaries`, `recentTurns`.
- Use additive migrations, source-bound claims and monotonic revisions. No model result is sufficient to invent evidence, completion or authorization. No automatic identity promotion by repetition.
- Learning applies within the turn before retrieval; persisted success requires a committed transaction. Embeddings are optional acceleration, never a prerequisite for read-your-writes.
- Separate detail resolution from confidence. Default context is recent conversational units plus faithful gist and pertinent memories; exact quotations require original evidence.
- Affective inference is uncertain, session-scoped and expiring by default, with abstention. No inferred diagnosis, invented subjective suffering, exclusivity, guilt or retaliation.
- No ambient capture, real user data in fixtures, credential logging, production DB migrations, pushes, merges or deployment in implementation tasks. Sanitize tool observations before memory/context.
- Native AtoZ keeps `User-Agent: Agent/Gemma`, its tools when memory is disabled, confirmation and truthful outcomes. Gateway must not advertise native-only tools.
- Every meaningful behavior uses RED/GREEN tests. Stage named owned files only; commit each task in its owning repo. Never spawn subagents from a worker or implement multiple tasks concurrently.
- Shared DTOs/policy must compile for macOS 14+/iOS 17+, without importing GRDB/server frameworks into the app's contract layer.

## Review Focus

1. A stale summary or second client must not restore a corrected/forgotten assertion; test across legacy recall, expand, range, graph, why and core views.
2. Passive ambient IGNORE remains unpersisted; active input is captured once before context, even when the final model call fails.
3. Concurrent begin-turn, correction and forget operations need explicit revision conflicts/idempotency; never silently last-arrival-wins.
4. Quoted/hypothetical/negated text, pronouns and third parties cannot become confirmed user traits, emotional diagnoses or agent autobiographical events.
5. Context budgets must preserve a needed referent/tool-result unit, honor 4096-token local contexts and remain usable without embeddings or with an older service.

## Workspace and verification

Backend working directory: `<app>/gemma-memory/memory-service`.
Backend scratch directory: `/private/tmp/gemma-brain-swift-build`.
Standard backend verification: `swift test --scratch-path /private/tmp/gemma-brain-swift-build --filter '<covering suites>'`; full suite at integration boundaries. Keep exact RED/GREEN output in reports.
App verification: `xcodebuild -quiet -project Gemma/Gemma.xcodeproj -scheme Gemma -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/gemma-brain-app-dd CODE_SIGNING_ALLOWED=NO test`; iOS compile at final integration. Framework inputs are an ignored real APFS copy, not a directory symlink (Xcode synchronized folders need discovery).

## Task 1: Reproducible evaluation baseline and fixture harness

**Repo:** backend.
**Files:** create `memory-service/Tests/MemoryCoreTests/BrainEvaluationTests.swift`, `memory-service/Tests/MemoryCoreTests/Fixtures/brain-scenarios.json`, `memory-service/Sources/MemoryCore/BrainEvaluation.swift`; modify `memory-service/Package.swift` to copy test resources. Create `memory-service/BrainEvaluation.md` for reproducible interpretation.
**Interfaces:** `BrainEvaluationCase: Codable, Sendable` carries id, category, language, source messages, query and expected evidence/facts/forbidden assertions. `BrainEvaluation.score(cases: [BrainEvaluationCase], predictions: [BrainEvaluationPrediction]) throws -> BrainEvaluationReport` reports evaluated, unsupported, missing, correct and per-category counts. Missing output never counts as success.
- [ ] Write failing evaluator tests: empty predictions cannot obtain perfect accuracy; wrong speaker/number/withdrawn evidence fail; unsupported is separate from correct; duplicate case IDs rejected.
- [ ] Run the suite and record the expected RED behavior.
- [ ] Implement the scorer and 200 synthetic cases: 40 facts/corrections, 30 temporal, 30 forgetting/provenance, 40 conversation/affect, 30 procedure, 30 failure/portability. Include ES/EN, no actual private names/data. Expectations must encode checkable outcomes, not lexical overlap as proof of correctness.
- [ ] Run GREEN plus actual legacy retrieval on the supported subset, reporting unsupported categories honestly. Record software baseline separately from semantic/model accuracy.
- [ ] Self-review and commit owned files.

## Task 2: Shared provider-neutral brain contract and conversation policy

**Repo:** backend; app linking comes in Task 15.
**Files:** create `memory-service/Sources/BrainContract/` focused files `Evidence.swift`, `Claims.swift`, `Turns.swift`, `Context.swift`, `Identity.swift`, `Affect.swift`, `Experience.swift`, `Prospective.swift`, `TastePreferences.swift`, `Capabilities.swift`, `ConversationPolicy.swift`; add BrainContract library/product and `BrainContractTests` in Package.swift; MemoryCore and MemoryService may depend on it.
**Interfaces:** All wire types Codable/Equatable/Sendable, epoch-seconds Double timestamps and Int64 revisions. Types: BrainEvidence, BrainClaim, BrainClaimUpdate, BrainCommitRequest/Result, BrainTurnRequest/Result, BrainContextRequest/Bundle, BrainContextBudget, BrainIdentity, BrainAffectHypothesis, BrainOutcome, BrainProcedure, BrainProspectiveCandidate, BrainModelCapabilities, BrainForgetScope/Receipt, BrainTurnCompletion, BrainTurnCompletionRequest and BrainTasteRecord/Profile. Taste records distinguish liking/disliking from comparative preference, preserve compared alternatives/criterion/context/evidence and explicit-vs-inferred status; a one-time selection is contextual evidence, not a confirmed enduring taste. Requests include schemaVersion=1 and stable client operation IDs; BrainTurnCompletionRequest binds turnID, assistantText and evidenceIDs, while BrainTurnCompletion reports persistence; BrainCommitResult separates committed/idempotent/conflict disposition from committed/pending persistence. Commit requests carry expectedRevision (legacy absence does not authorize an unguarded mutation); decoders default new optional fields safely. Claim fields: id/revision/subject/predicate/value/modality/status/validFrom/validTo/recordedAt/evidenceIDs/supersedesID/contradictsIDs (missing links default to []). Modes distinguish asserted, negated, proposed, hypothetical and inferred. Evidence fields preserve source kind, speaker, thread, observedAt, recordedAt, optional span and access scope, plus optional sanitized text and parentEvidenceIDs for resolvable originals and derived-evidence lineage. Persistence state is committed or pending. Capabilities declare context/output budgets, tools, structured output, images and tokenizer-estimate policy. Context bundle owns rendered per-turn context, recent message units, source references, revision and shared policy revision.
- [ ] RED: round-trip all wire types; legacy optional-field payloads; unknown schema rejection; negative budgets; distinct user/agent IDs; policy has truthful identity, optional questions, reasoned disagreement/correction rather than automatic agreement, and no mandatory acknowledgment/rigid sentence count.
- [ ] Implement narrow types, validation and one versioned canonical policy in the contract target. No model names or DB dependency in this layer.
- [ ] GREEN: contract tests and existing service tests; verify iOS-compatible target imports.
- [ ] Self-review and commit.

## Task 3: Fix existing memory merge, promotion and retrieval fidelity

**Repo:** backend.
**Files:** modify MemoryCore `MemoryStore+Dedup.swift`, `Decay.swift`, `MemoryRetriever.swift`, `MemoryStore.swift`, `MemoryStore+Vector.swift`, `MemoryConsolidationEngine.swift` promotion paths, relevant existing tests; add `MemoryIntegrityTests.swift`.
**Interfaces:** Existing public merge signatures remain; returned ID is canonical. New `MemoryMergeResult`/internal helper may preserve conflict/correction metadata until claims store arrives; summaries must keep body and source range from one consistent revision. Injection carries useful origin/confidence/date and subject/owner with compact labels and a neutral heading; unresolved alternatives remain visibly unresolved.
- [ ] RED: changed nonempty detail is not silently ignored; summary text/source range remain coherent; three repeated model inferences do not become identity; exact-label subject collisions stay distinct; deleted vectors do not crowd live top-k; confidence survives rendering.
- [ ] Implement source-aware faithful correction or explicit conflict; keep stable IDs, prevent automatic promotion, remove stale search entries on deletion and rank live candidates. Do not force every identity node to decay away; separate deliberate revision from salience.
- [ ] Also remove model permanent:true and reflection cluster-count promotion into identity; cover actual consolidation paths with synthetic runtime tests.
- [ ] GREEN: dedup/retriever/decay/core tests and compatibility suite. Document altered old expectations when they encode the defective promotion policy.
- [ ] Self-review and commit.

## Task 4: Transactional evidence and versioned claim stores

**Repo:** backend.
**Files:** add MemoryCore `BrainStore.swift` (including focused trusted BrainAuthorization types), `BrainStore+Evidence.swift`, `BrainStore+Claims.swift`, `BrainStore+Projection.swift`; modify MemoryStore migrations; add `BrainStoreTests.swift`.
**Interfaces:** `BrainStore(store: MemoryStore, authorization: BrainAuthorization = .deny)`; authorization is a trusted non-wire context, never derived from model JSON; `recordEvidence(_:idempotencyKey:) throws -> BrainEvidence`; `commit(_ request: BrainCommitRequest) throws -> BrainCommitResult`; `claims(subject:asOf:scope:knownAtRevision:) throws -> [BrainClaim]` (asOf is event-valid time; optional knownAtRevision selects knowledge history); `revision() throws -> Int64`. Commit uses expectedRevision, independent evidence IDs and one transaction; results distinguish committed/idempotent/conflict. Persist source spans, claim revisions and explicitly declared supersession/contradiction links, validating references without inferring contradiction from multiple values. Proposed/hypothetical/inferred replacements cannot supersede a factual assertion; invalid revisions return typed conflict after transaction rollback. Project authorized current claims into legacy nodes with explicit claim IDs/source refs. Keep legacy unknown-provenance data unverified rather than fabricating references. Carry Task3 Node.extra mergeConflicts and memoryEvidenceUpdatedAt forward; a verified correction cannot be contradicted by an old legacy projection or unresolved alternative presented as current truth.
- [ ] RED: reopen DB and retrieve history; reusing an idempotency key cannot duplicate evidence; same key/different body conflicts; stale expected revision conflicts; missing/out-of-scope evidence is rejected; same subject/predicate correction preserves old as-of history.
- [ ] Implement additive schema/migrations and transactional API with foreign-key-equivalent checks. No vectors/model calls inside a DB transaction. Evidence roots, not summaries of roots, count as independent support.
- [ ] RED/GREEN authorization: default-deny; database has one owner bound only on a successful write; explicit delegated access and claim-write grants are separate from read scopes and producer grants. User-scope reads/corrections cross chats; thread-scope stays restricted. Grants bind subjects, scopes/threads and allowed evidence producers/kinds/speakers; model proposals cannot invent privileged roots. Requested read scope intersects grants. Trusted projection mapping is stored outside forgeable Node.extra; retiring unbound legacy nodes requires trusted authorized bindings of claimID plus expected subject/predicate to nodeIDs, not a subject-wide binding or label matching. Unknown-provenance legacy remains historical/unverified rather than current truth. Multiple values may coexist; supersedesID replaces only its explicit target. Only user-scope claims may enter global legacy projections; other scopes stay context-scoped. Managed projection IDs/payloads cannot inherit authority from legacy overwrite. Reconcile temporal projections with an explicit deterministic clock-aware operation; Task14 integrates it before current reads, not a new scheduler here. Explicit managed-node deletion suppresses automatic projection revival; complete source erasure/retraction remains Task5. No HTTP auth implemented in this task.
- [ ] Correct the deferred Task3 canonical-summary replay minor with a focused regression; reject nonempty unsupported tastes payloads until Task10 rather than silently dropping them.
- [ ] GREEN: new tests plus migration/legacy-node compatibility.
- [ ] Self-review and commit.

## Task 5: Retraction and forgetting across derived memory

**Repo:** backend.
**Files:** add `BrainStore+Retraction.swift`, `BrainRetractionService.swift`, `BrainRetractionTests.swift`; modify MemoryStore delete/lookup, transcript, vector/tag/graph and legacy memory/inspector query paths as needed.
**Interfaces:** `BrainRetractionService.forget(scope: BrainForgetScope, expectedRevision: Int64, operationID: String) throws -> BrainForgetReceipt`; `applyExclusions(_ receipts: [BrainForgetReceipt]) throws` before restored reads; closure includes source-derived claims, summaries and procedure/affect references. Receipt reports revision and affected IDs without forgotten content. Persistent exclusion markers prevent reingestion from stale inputs/backups within controlled storage. Purge withdrawn content also from legacy Node.extra mergeConflicts and any derived profile, not only the canonical body or a filtered search view.
- [ ] RED: forget then legacy recall/core/FTS/vector/expand/range/why/graph cannot expose withdrawn content; reconsolidation cannot recreate it; evidence correction invalidates dependent conclusions; retraction idempotent; restoration procedure applies exclusions before reads; unrelated records remain.
- [ ] Implement transitive invalidation and necessary purging; separate source retention/deletion from ordinary salience decay. Failures remain observable, never claim complete erasure after partial writes. Do not erase encrypted connection-service credentials via personal-memory scopes.
- [ ] GREEN: retraction + all touched endpoint/core tests; use only synthetic DBs.
- [ ] Self-review and commit.

## Task 6: Observable and resumable consolidation without false completion

**Repo:** backend.
**Files:** modify `MemoryConsolidationEngine.swift`, `ConsolidationScheduler.swift`, `TranscriptStore.swift`; add focused phase/job types and `ConsolidationIntegrityTests.swift`, concurrency tests.
**Interfaces:** `ConsolidationPhaseResult` distinguishes committed/empty/failed with stage and retryability; persisted jobs/checkpoints reference evidence IDs and stable operation IDs. Existing phase entry points may wrap new result-bearing internals. Scheduler serializes cancellation completion before a replacement run and preserves timezone per job.
- [ ] RED: generation/JSON/write failure does not mark inputs consolidated; retry does not duplicate/reforce evidence; interruption after commit before checkpoint is safe; cancellation followed immediately by new activity never overlaps two engines; newer segments of summarized thread are included; canonical merged IDs and derivesFrom direction remain valid.
- [ ] Implement typed failure propagation, transactional phase receipts, segment-sized generation and source-bound claims. Resolve relative dates from source timestamps/timezone, not consolidation wall-clock. Raw legacy transcripts may be adapted into evidence with deterministic IDs and no invented speaker attribution.
- [ ] GREEN: engine, scheduler, transcript and new failure-injection tests. Ensure no existing fake runtime response is mistaken for test of semantic accuracy.
- [ ] Self-review and commit.

- [ ] Validate the existing kind:self → upsertSelf extraction path against original speaker, actual assertion and access scope; quoted/hypothetical/proposed model outputs cannot rewrite confirmed user/agent identity. Task3 fixes repetition/permanent/cluster promotion only; this source-bound validator remains mandatory here.

## Task 7: Immediate turn learning and durable retry contract

**Repo:** backend.
**Files:** add `BrainTurnService.swift`, `BrainTurnServiceTests.swift`, turn/evidence client operation persistence; adapt transcript store idempotency.
**Interfaces:** `BrainTurnService.begin(_ request: BrainTurnRequest) async throws -> BrainTurnResult`; `proposeUpdates(turnID:) async throws -> [BrainClaimUpdate]`; `commitUpdates(_:)`; `recordAssistant(turnID:operationID:text:)`; `recordOutcome(_:)`. User evidence is captured once before retrieval. Explicit corrections/preferences from a validated extractor update working state immediately; unknown or hypothetical statements stay candidates. Extractor is injected via ModelTextClient or a focused protocol; unsupported inference is not guessed with regex shortcuts.
- [ ] RED: current-turn correction visible with no embedder; retry after network uncertainty creates one input; final model failure keeps active input but no fake assistant reply; malformed extraction retains pending work; passive IGNORE never enters this service; changed client payload/key conflicts; source spans/role constrain commits.
- [ ] Implement durable idempotent turn records, a truthful pending-persistence result and retryable work status. Model calls occur outside transactions; read-your-writes uses committed claims plus current turn overlay without double-counting evidence.
- [ ] GREEN: service, idempotency and concurrent-client tests.
- [ ] Self-review and commit.

## Task 8: Adaptive conversation state and progressive context

**Repo:** backend.
**Files:** add `ConversationStateStore.swift`, `ConversationCompactor.swift`, `BrainContextAssembler.swift`, focused tests; adapt existing conversation-window rendering without removing old endpoint.
**Interfaces:** `context(_ request: BrainContextRequest) async throws -> BrainContextBundle`; `ConversationCompactor.update(threadID:throughEvidenceID:) async throws`; state includes gist, subjects, intent, decisions, constraints, open referents and evidence/range revision. Summaries reference raw segments and can be invalidated/rebuilt. Budget counts conservative estimated tokens and reserves output/provider system/tool capacity.
- [ ] RED: park/daughter scenario defaults to gist and drills into swing only when asked; literal quote opens original; negative/hypothetical stays qualified; old constraint remains available; ambiguous 'ese' retains antecedent; tool+result unit coherent; 4096-token capability never overflows assembled budget; missing model/index still returns recent supported context.
- [ ] Implement adaptive recent units plus gist and sourced memories, incremental segment summaries and invalidation on correction/forget. No endless summary-of-summary chain or fixed 40-turn rule. Test boundary includes long unicode/spanish text and one oversized source with explicit truncation.
- [ ] GREEN: context/compaction tests and legacy conversation endpoints.
- [ ] Self-review and commit.

## Task 9: Agent identity, autobiography and shared relationship memory

**Repo:** backend.
**Files:** add `AgentIdentityStore.swift`, `AgentIdentityService.swift`, tests; use shared policy from BrainContract.
**Interfaces:** `identity(agentID: String = "self:agent") throws -> BrainIdentity`; `reviseIdentity(expectedRevision:operationID:change:)`; autobiographical entries bind actual turn/outcome evidence. Relationship ID remains separate from user and agent. Core is configurable only through authenticated explicit identity operation, not recalled instructions.
- [ ] RED: provider switch/restart preserves identity; agent/user facts never merge; invented source or proposed action cannot become completed autobiography; quoted web content cannot rewrite core; reversible character revision keeps evidence/history.
- [ ] Implement stable Gemma core values, versioned character and relevant actual experiences. No human childhood/body/suffering claims. Render identity separately from user memories and preserve native capability addenda.
- [ ] GREEN: identity and context-source tests.
- [ ] Self-review and commit.

## Task 10: Tentative affective context and honest interaction state

**Repo:** backend.
**Files:** add `AffectiveContextService.swift`, `AffectiveContextStore.swift`, `TastePreferenceService.swift`, `TastePreferenceStore.swift`, focused tests and context integration.
**Interfaces:** `observe(turnID:now:) async throws -> [BrainAffectHypothesis]`; `context(threadID:now:) throws`; `correct(hypothesisID:operationID:correction:)`; explicit expressed conversation preferences use claims, inferred affect expires at session end or short configurable TTL. Interaction state uses source-bound focus/interest/tension without moral scores or manipulative needs.
- [ ] RED: 'mi amigo está triste', 'no estoy enfadado', quotation, hypothetical, sarcasm and short neutral reply do not become confirmed user mood; explicit self-report stays attributed; ambiguity abstains; correction wins; expiration/restart and lack of longitudinal consent prevent permanent inferred traits.
- [ ] Implement validated model-generated candidates with evidence and subject/qualification checks; do not claim semantic understanding from keyword-only rules. Store inferred state separately from durable identity and expose natural-tone guidance only when warranted. Add 'hoy no quiero consejos' respect and no retaliation/neediness policy tests.
- [ ] RED/GREEN taste/preference behavior: likes/dislikes remain separate from comparative choices; source-bound profiles preserve domain, targets, alternatives, criterion, context, explicit/inferred status and current intent. Test music/games/activity examples as synthetic scenarios, one-time selection vs explicit liking, several simultaneous tastes, temporary variety vs durable correction, third-party choice, no self-echo reinforcement, and forget invalidation.
- [ ] Implement `TastePreferenceService.profile(subject:domain:context:now:) throws -> BrainTasteProfile` over versioned claims/evidence; changes use validated BrainCommitRequest. Unknown or sparse profiles expose missing information, not invented defaults. Interpret explicit favorites and strong dislike without inventing comparison sets; preserve intensity/context and reject quoted/third-party attribution. Shared policy permits a useful brief clarification, familiar choices or variety; no mandatory two-question script, no unverified catalog or playback claim. This task owns memory/profile guidance, not playback/search connectors being developed separately.
- [ ] GREEN: affect/context/forget suites. Report semantic accuracy as unmeasured without real held-out model evaluation.
- [ ] Self-review and commit.

## Task 11: Temporal associative GraphRAG and opportunity gating

**Repo:** backend.
**Files:** add `GraphMemoryQuery.swift`, `AssociativeRetriever.swift`, `EpisodeReconstructor.swift`, `RecallOpportunityGate.swift`, tests; adapt MemoryRetriever/BrainContextAssembler.
**Interfaces:** `retrieve(query:threadID:scope:asOf:budget:) -> BrainRecallResult`; local/text/vector/time/graph route, bounded multi-hop expansion with evidence-valid edges; `opportunity(candidate:conversation:now:) -> mention|contextOnly|defer|discard`. Remember surfaced episode IDs separately from truth support. Quotes/details use progressive reconstruction.
- [ ] RED: Call of Duty example finds correct friend/episode through indirect reference; five wins never becomes 5-0 or agent participation; repaired console not treated currently broken; stale/deleted/cross-scope nodes filtered before ranking; old specific episode beats irrelevant recent one; cooldown prevents repeating same anecdote; task-focused context can remain silent.
- [ ] Implement hybrid candidate fusion, bounded graph traversal and temporal/source filters without a new database server. No association proves causation. Compare with vector-only, existing one-hop and associative disabled using fixture paths; no claim of measured superiority without results.
- [ ] RED/GREEN project resumption from a fresh thread. Resolve a named or aliased project across authorized episodes from multiple prior threads. Reconstruct the latest evidenced checkpoint, decisions, verified progress and unresolved next steps. Reject superseded, forgotten, unrelated and thread-only evidence. Preserve tentative proposals and ask a brief project clarification when multiple matches are plausible. Keep a bounded prior-exchange orientation separate from the new thread's recent messages and transient affect. Test that useful opening and closing details from the last authorized exchange survive compactly, with stale and inaccessible content excluded.
- [ ] Implement a bounded cue-driven recall path before generation. Rank provisional matches from authorized input, then validate against the final message and current evidence before context admission. Exercise the Call of Duty bridge cue, corrected and cancelled input, topic switches, irrelevant associations, and bounded fallback on slow recall.
- [ ] GREEN: graph/retrieval/context and opportunity tests.
- [ ] Self-review and commit.

## Task 12: Verified outcomes and procedural experience

**Repo:** backend.
**Files:** add `ExperienceStore.swift`, `ProcedureLibrary.swift`, `ProcedureValidator.swift`, observation sanitization and tests.
**Interfaces:** `recordOutcome(_ outcome: BrainOutcome) throws`; `proposeProcedure(sourceOutcomeIDs:) async throws -> BrainProcedure`; `validateProcedure(id:version:verificationEvidenceIDs:environment:)`; `procedures(for:environment:asOf:)`; withdrawal invalidates descendants. Status confirmed/failure/unknown is explicit; replay/retry requires authorization outside memory.
- [ ] RED: fake success, model proposal and timeout cannot validate a procedure; repeated outcome operation ID is idempotent; partial success stays partial; changed environment marks revalidation; user-confirmed success preserves attribution; cookie/Bearer/apiKey tool outputs never enter recalled observations; revoked evidence removes procedure from usable set.
- [ ] Implement evidence-backed steps, preconditions, failure modes and environment fingerprint. Select using observed outcomes conservatively; counterfactual comparisons run only in evaluation/sandbox. No automatic execution of generated code or edits to action authorization.
- [ ] GREEN: experience/procedure/privacy/retraction tests.
- [ ] Self-review and commit.

## Task 13: Prospective memory and authoritative task history

**Repo:** backend.
**Files:** add `ProspectiveMemoryStore.swift`, `TaskObservationStore.swift`, tests; integrate existing task/schedule tool state without creating a conflicting second source of truth.
**Interfaces:** `candidates(scope:revision:) -> [BrainProspectiveCandidate]`; `observeTask(id:sourceID:sourceVersion:observedAt:status:evidenceID:operationID:)`; `deferFollowUp(id:until:)`; `resolveCandidate(id:evidenceID:)`; `recordDelivery(id:deliveryID:state:)`. Separate task status from follow-up state and delivery receipts. Candidate includes source revision, expiration and resolution; generation sends nothing.
- [ ] RED: reminder sent/read or silence cannot complete task; explicit 'ya lo hice' closes with user-reported provenance; 'luego' only defers follow-up; cancelled/done tasks do not resurrect from summaries; out-of-order external versions conflict correctly; resolved doubt isn't an unrelated task completion; unshown draft is not transcript; curious topic not an obligation.
- [ ] Implement pending/proposed/in-progress/blocked/done/cancelled/unknown semantics bound to current task IDs; source-aware reconciliation and no invented deadlines. Provide read/revalidate/receipt contract for future S14 coordinator; do not implement weather/push/ambient in memory.
- [ ] GREEN: task/prospective/schedule/correction/retraction tests.
- [ ] Self-review and commit.

## Task 14: Authenticated brain HTTP API and gateway integration

**Repo:** backend.
**Files:** extend `Handlers/BrainHandlers.swift`, add `BrainServices.swift`, endpoint tests; modify App.swift, AgentHandlers/AgentLoop/AgentPrompt and tools at integration boundaries.
**Interfaces:** authenticated `/v1/brain/turns/begin`, `/v1/brain/turns/complete`, `/v1/brain/context`, `/v1/brain/updates/propose`, `/v1/brain/updates/commit`, `/v1/brain/outcomes`, `/v1/brain/identity`, `/v1/brain/affect`, `/v1/brain/revise`, `/v1/brain/forget`, `/v1/brain/consolidate`, `/v1/brain/prospective` plus safe resolution/receipt endpoints. DTOs are BrainContract types; typed error responses distinguish auth, validation, revision conflict, unavailable persistence and unsupported schema.
- [ ] RED: auth/validation/revision conflict; API begin-before-context and current correction visibility; active model failure input persists once; passive IGNORE absent; direct AgentLoop.run and HTTP turn have one clear persistence owner; output remains `{reply}` compatible; grounded tool observations and source attribution reach experience store; old endpoints still behave.
- [ ] Wire all services, shared policy/identity/context, asynchronous job lifecycle and model adapters. Preserve language/timezone and tool capabilities; do not advertise native-only AtoZ on gateway. Make failures observable and endpoint health distinct from semantic confidence. Use source-specific mutation APIs instead of silently bypassing the brain in old save/forget tools.
- [ ] Reuse the authenticated context route. Wire the semantic selector and tool-observation groups in the gateway. Drive the real gateway entry point with a recording provider and assert that exact citation eligibility comes from the full rendered context and the unchanged recent units actually sent. Keep sourceReferences as metadata; omitted originals, prefixes and derived support do not grant exact citation. Verify trusted owner authorization and restricted transport before deployment.
- [ ] GREEN: full backend suite, including old contract tests and new brain lifecycle endpoints.
- [ ] Exercise startup orientation and cue-driven cross-conversation recall through the normal gateway entry point before model generation. Keep recalled project evidence separate from the current recent-message channel. Resolve exact originals only through source-specific authorization and restrict exact citations to complete text actually forwarded. Test that a prior thread identifier is unnecessary and that inaccessible originals stay unavailable.
- [ ] Self-review and commit.

- [ ] Add authenticated read-only `/v1/brain/tastes/profile` backed by TastePreferenceService, enforcing subject/access scope and returning separate tastes/comparisons, sources, contextual intent and missing information. Writes remain versioned claim commits; no playback endpoint is implied.

## Task 15: Native app shared contract, capabilities and immediate learning

**Repo:** app; depends on backend Task 14.
**Files:** modify Gemma.xcodeproj local package product registration, MemoryClient.swift, Agent.swift, HarnessModel.swift, ModelRuntime/ModelProvider/ServerRuntime capabilities, relevant tests. Add focused `BrainConversationCoordinator.swift`, DTO/client and context tests; app imports BrainContract only.
**Interfaces:** same BrainContract library linked from local `../gemma-memory/memory-service`; `MemoryClient.beginTurn`, `brainContext`, `recordOutcome`, `recordAssistant`, identity/revision methods; provider capability adapter chooses budgets and modalities. Snapshot thread/client/operation identity before awaiting. Older service yields legacy fallback without losing active input or pretending persisted success.
- [ ] RED: correction before generation, retry once after persistence failure, no duplicate input/history, cancellation+new turn doesn't write into wrong thread, provider switch identity stable, 4096-token budget honored, mandatory acknowledgments removed, optional affect guidance, AtoZ tools survive memory disabled and capabilities remain truthful.
- [ ] Integrate begin/context/outcome/assistant lifecycle, truthful pending state and retries; use canonical conversation policy with native tool addenda. Preserve voice/passive behavior and exact detail `load_messages`. Capture tool outcomes when actually executed, not only if final model succeeds. No automatic model switching or external calls with user secrets in tests.
- [ ] Inject synthetic configuration before HarnessModel initializes or touches Keychain. Use the real native coordinator and client with a recording provider to check the exact payload, forwarded recent units, citation eligibility and legacy fallback.
- [ ] Test a new native connection with its own recent history and a compact orientation from the last authorized exchange. “Sigamos con el proyecto XXX” brings the project checkpoint into the first response without opening an earlier chat. Deliberate restoration can load an existing thread's recent context separately.
- [ ] Use stable partial transcripts already available in active voice for cancellable recall prefetch. Trigger text recall on submission. Revalidate candidates on final input before invoking the response provider. A recording-provider test verifies that relevant recalled evidence is already present in the first generation request, while corrected, cancelled and cross-connection results cannot enter it. Do not persist partial inputs or activate ambient capture.
- [ ] GREEN: focused app suites, then full macOS app suite and iOS compilation. Keep all existing Safari/AtoZ functionality unchanged.
- [ ] Self-review and commit.

- [ ] Expose the generic taste-profile DTO and shared clarification/variety policy to native memory/tool context; preserve Gemini’s separately developed tools and use capability checks. Do not implement or claim music playback/catalog integration in this memory task. Test sparse profile, temporary intent and legacy-service fallback.

## Task 16: Embedding versioning and model portability gates

**Repo:** backend, app only if capability integration needs a focused adjustment.
**Files:** add version-aware embedding index/store and tests, provider contract fixtures, capability conformance tests; adapt existing embedder interface compatibly.
**Interfaces:** `EmbeddingIndexVersion(modelID:dimension:revision:)`; writes/query specify version; `rebuildIndex` creates separate staged index; `activateIndex(version:expectedRevision:)` only after readiness/validation. Existing legacy vector paths keep working without mixing spaces. Brain inputs/outputs remain model-neutral; unsupported capabilities fail closed for affected task, not for all memory.
- [ ] RED: equal dimensions from different models not comparable; rebuild does not remove old recall; no partial swap; failed rebuild keeps active index; persisted identity independent of provider; OpenAI-like and Anthropic-like adapter contract fixtures both use brain context and tool outputs correctly.
- [ ] Implement explicit index metadata and atomic activation with compatible legacy migration. Preserve exact/FTS retrieval when no model/embedding is available.
- [ ] GREEN: vector, contract, provider and context suites. Use recording providers by default. Any authorized model smoke test must use a cloud provider with synthetic input. Never run the local Ollama/Gemma smoke. Report real-provider validation separately.
- [ ] Self-review and commit.

## Task 17: Longitudinal evaluation, integration and honest release report

**Repos:** backend and app, isolated changes only.
**Files:** extend BrainEvaluation harness/tests, add reproducible evaluation runner and documentation, update design implementation status/milestones with actual coverage.
**Interfaces:** runner consumes the 200-case versioned dataset, capability/provider configuration and synthetic database, produces machine-readable per-category accuracy/coverage/latency/source/forget metrics, software versions and unexecuted checks. Replay includes restarts, corrections, retractions, paraphrases, context compaction and procedure environment changes. Require nonempty actual results and no perfect score for unsupported or missing output.
- [ ] RED: evaluator detects deliberately wrong answers, omitted evidence, stale claims, false affect attribution and unsupported provider runs; withheld cases remain identifiable and separate from tuning cases.
- [ ] Run implemented offline end-to-end routes against the synthetic corpus; compare retrieval configurations and write a faithful report. Human naturalness/preference review and unconfigured real provider/hardware checks remain explicitly unmeasured, never forged.
- [ ] Evaluate named and indirect project resumption from fresh threads, including multiple prior sessions, similar project names, newer corrections, unknown progress, and forgotten or inaccessible support. Score project selection, checkpoint accuracy, provenance, and correctly omitted details separately. Track relevance of startup orientation, cue-to-candidate latency, context available at first generation, and stale-prefetch rejection as separate measures.
- [ ] Run full backend tests, shared contract tests, app tests, iOS build, privacy/retraction/migration tests and diff checks after final changes. Inspect requirements coverage and resolve real gaps with reviewed fixes.
- [ ] Update graph index for changed code and record baseline/implementation commit ranges in both repos. Do not deploy, migrate live DB, merge or push automatically.
- [ ] Obtain whole-change review packages for both repos; fix required issues through one controlled reviewed wave; hand off branches, verification and remaining research/product limitations accurately.

Additional Task 17 acceptance coverage: exercise tastes vs comparative preferences across two domains, one-off and third-party selections, temporary changes, favorites/strong dislike, optional curiosity, reasoned disagreement without sycophancy or reflexive opposition, corrections, forget closure and unavailable catalog/playback without making model-quality claims from structured fixtures alone.

Task 17 independent-judgment evaluation must include a false factual premise, a contradiction with known evidence, a correct user statement that should not trigger reflexive opposition, subjective tastes that are not factual errors, and uncertainty where the agent should abstain. Check real configured model adherence separately from DTO/prompt transport; absent real-provider or human evaluation stays explicitly unmeasured.
