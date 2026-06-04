# Self Identity (SP2) — Design Spec

**Date:** 2026-06-04
**Status:** Approved (brainstorm), pending plan
**Repos:** `gemma-memory` (i3 server) + `personal_agent` (app).

---

## 1. Motivation

The agent has no first-class concept of *who the user is*. The user's name is captured as a generic `person|Roilan` node, indistinguishable from third parties (friends, family). Diagnosed failure (`agent-behavior-failure-modes` #1): "me llamo Roilan" saved as a disconnected person; in another session "¿cómo me llamo?" → "no me lo has dicho"; the user treated as a third party. Recent recall work mitigated the *forgetting*; SP2 adds the missing *self-concept*: the system must know which record is THE USER (you), distinct from the people they mention.

## 2. Goals

1. A single, first-class **self** record for the user — their name + identity — that is impossible to confuse with a `person`.
2. The agent always knows "I'm talking to `<name>`, the user," and treats facts the user states about themselves as about *you*, never a third party.
3. Third parties (María, Ana) are `person` nodes carrying their relationship role (spouse, daughter), linked to the self.

## 3. Non-Goals

- Multi-user support (exactly one user → one self).
- Re-architecting recall/consolidation beyond routing identity to self.
- A structured per-edge "role" schema (the role lives in the person's `detail`; the edge carries the relation type).

## 4. Design

### 4.1 The `self` singleton (server, `gemma-memory`)

- New `NodeKind.selfUser` with rawValue `"self"` (+ a `hubLabel` case, e.g. "Self").
- One node, fixed id **`self:user`**, `kind="self"`, `layer=.identity`, high salience (10). `label` = the user's name; `body` = a short identity line if stated. Created lazily on first identity capture (no empty boot node).
- Store: `upsertSelf(name:detail:) -> String` (upsert by the fixed id → always exactly one; updates `label`/`body`, refreshes `lastSeenAt`, embeds the name) and `selfNode() -> Node?`.
- `coreMemories()` returns the self node **first** (prepended), then the other identity-layer nodes (excluding self) by salience. So the self is always at the head of the injected memory.

### 4.2 Capture: route the user's identity to self (server + app)

- **Consolidation extraction prompt** (`MemoryConsolidationEngine.consolidate`): teach the kind choice — the USER's own name/identity (who you're talking to) → `kind:"self"` (there is exactly one user); other people → `kind:"person"`, and for a known relationship put the role in `detail` (e.g. "esposa", "hija", "amigo"). In the entity loop, when `e.kind == "self"` → `store.upsertSelf(name: canonicalLabel, detail: e.detail)` (do not create a generic node); other kinds unchanged.
- **`save_memory`** (app tool + `/v1/memory/save` handler): allow `kind:"self"` for the user's own name/identity. The save handler routes `kind == "self"` to `store.upsertSelf(name: body.label, detail: body.body)` instead of `upsertMergingSemantic`. The tool's description notes: *for the user's own name/identity use kind "self".*
- **Third parties linked to self** (`associate` phase): the prompt already connects the user's `person` node to others. Add: link the self node to the people the user mentions with `family`/`knows`/`worksWith`. The role (spouse/daughter) is already in the person's `detail`; the edge gives the family/knows link for graph traversal + recall.

### 4.3 The agent knows "you are the user" (app)

- **Render** (`RecallBundle.injectionBlock`): a `kind == "self"` node renders first and distinctly, e.g. `You are speaking with <label> (the user).` (not as a generic `- [self] …` fact line). People recalled around it carry their `detail` role ("María: esposa"), so the agent can say "tu esposa María."
- **System prompt** (`Agent.systemPromptText`): add one line — *"The `self` record is the USER you are speaking with — their name and identity. Address them by it; treat what they say about themselves as about 'you', not a third party; never ask for something already in your memory about them. Other named people are separate persons with their own roles."*

## 5. Data Flow

The user states "me llamo Roilan, mi esposa es María" → consolidation extracts `self` (Roilan) → `upsertSelf("Roilan")`, and `person|María` with `detail:"esposa"` → `associate` links `self:user --family--> María`. Every turn, `coreMemories()` injects the self first; recall renders "You are speaking with Roilan (the user)" + María (esposa). A new chat asking "¿cómo me llamo y quién es mi esposa?" answers from the always-present self + the linked person.

## 6. Error Handling

- No name yet → no self node; the prompt's "address by name when known" already handles the unknown case (existing behavior).
- `upsertSelf` embed failure → best-effort (node still saved; just less recall-discoverable), mirroring `save`/append.

## 7. Testing

- **Server (unit):** `upsertSelf` creates exactly one `self:user` node (kind=self, layer=identity) and updates (not duplicates) on a second call; `selfNode()` returns it; `coreMemories()` lists self FIRST; `/v1/memory/save` with `kind:"self"` routes to `upsertSelf` (no generic node created); consolidating an entity with `kind:"self"` updates the self; a `person` with a relationship gets a `self→person` edge after `associate` (engine test with a canned model reply emitting a `self` entity + a person + a family edge).
- **App (unit):** `RecallBundle.injectionBlock` renders a `self` node as "You are speaking with X (the user)" first, distinct from fact lines; `SaveMemoryTool` accepts `kind:"self"`; `Agent.systemPromptText` contains the self instruction.
- **E2E manual (fresh memory):** "me llamo Roilan, mi esposa es María, mi hija Ana"; new chat → "¿cómo me llamo y quién va conmigo de viaje?" → correct, addressing the user as themselves and María/Ana as their spouse/daughter.

## 8. Implementation order

1. `NodeKind.selfUser` + `upsertSelf`/`selfNode` store methods + `coreMemories` self-first.
2. Consolidation: route `kind:"self"` → `upsertSelf`; capture relationship role in `detail`.
3. Save handler: `kind:"self"` → `upsertSelf`.
4. `associate`: link self → mentioned people.
5. App: `SaveMemoryTool` `kind:"self"`; `injectionBlock` self render; `Agent` prompt line.
6. Deploy server + manual E2E.

Server changes need a rebuild/redeploy; the app change ships in the next build.
