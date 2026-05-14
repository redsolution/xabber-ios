# AGENTS.md

## Mission

Build, test, and maintain the Xabber iOS codebase with a strong bias toward safe, reviewable changes, test-driven implementation, and durable project memory in the knowledge base and Obsidian vault.

## Project identity

- Product: Xabber iOS XMPP client
- Repo root: `/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core`
- Knowledge base root: `/Users/igor.boldin/projects/xabber/xabber-knowledge`
- Obsidian vault root: `/Users/igor.boldin/projects/xabber/xabber`
- Obsidian project root: `/Users/igor.boldin/projects/xabber/xabber/projects/xabber`
- Main targets:
  - `xabber`
  - `xabber-push-extension`
  - `xabberTests`
- Current UI architecture: UIKit-first with limited SwiftUI bridges

## Default working agreements

- Prefer Swift over Objective-C for new code unless the surrounding module is Objective-C.
- Treat this repository as UIKit-first. Prefer existing UIKit patterns for UI changes unless the surrounding area already uses SwiftUI or interoperability requires it.
- Keep changes small, compile-oriented, and easy to review.
- Match the repository's existing architecture before introducing a new pattern.
- Do not add third-party dependencies unless the user explicitly asks or the repo already uses them.
- Use test-driven development for code-changing tasks: write or update the relevant XCTest coverage first, then implement the production change.
- Prefer a dedicated XCTest file per task when practical; if that is not practical, keep the new cases tightly scoped in the closest existing test file.
- When changing app behavior, add or update tests unless it is impossible in the current codebase, and record the reason when tests cannot be added.
- Prefer modern concurrency (`async/await`) over callback pyramids when practical.
- Use platform availability checks for APIs that may not exist on the deployment target.
- Preserve accessibility identifiers when editing UI under test.
- Never commit secrets, signing assets, private keys, or provisioning profiles.

## Repo map

- UI and navigation:
  - `xabber/controllers`
  - `xabber/Base.lproj`
- Domain and orchestration:
  - `xabber/models`
  - `xabber/common`
- Protocol and transport:
  - `xabber/xmpp`
  - `xabber/models/account/delegates`
- Push:
  - `xabber-push-extension`
  - `xabber/application/AppDelegateNotificationExtension.swift`
  - `xabber/xmpp/push_notifications`
  - `xabber/common/notify_manager`
- Calls:
  - `xabber/controllers/calls`
  - `xabber/xmpp/voip`
  - `xabber/common/audio_manager`
- Tests:
  - `xabberTests`

## Knowledge and vault workflow

The knowledge base and Obsidian project vault are not optional documentation.
The knowledge base is the product, protocol, and long-lived reference memory.
The Obsidian project vault is the shared operational memory of the agent system.
Every meaningful task, decision, handoff, blocker, and stable result must be reflected in the appropriate place.

Codex should not wait for the user to explicitly ask for knowledge or vault checks and updates.
For any non-trivial bug fix, feature, refactor, investigation, or multi-file change, knowledge-base review and vault updates are part of the work.

### Knowledge base intake

Before starting any meaningful task, check `/Users/igor.boldin/projects/xabber/xabber-knowledge/` for relevant product, architecture, protocol, testing, and operations context.

Start with these files when applicable:
- `/Users/igor.boldin/projects/xabber/xabber-knowledge/README.md`
- `/Users/igor.boldin/projects/xabber/xabber-knowledge/CONVENTIONS.md`
- `/Users/igor.boldin/projects/xabber/xabber-knowledge/GLOSSARY.md`
- `/Users/igor.boldin/projects/xabber/xabber-knowledge/architecture/README.md`
- `/Users/igor.boldin/projects/xabber/xabber-knowledge/protocols/README.md`
- `/Users/igor.boldin/projects/xabber/xabber-knowledge/ops/README.md`

Then search or read the specific `architecture/`, `protocols/`, `behavioral-specs/`, `ops/`, or `inbox/` notes that match the task area. Treat the knowledge base as reference material, and call out conflicts when it disagrees with current repository behavior or the user's latest instruction.

### Canonical vault files

Read these before major work:
- `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/README.md`
- `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/architecture.md`
- `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/shared/interfaces.md`
- `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/shared/dependencies.md`
- `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/shared/integration-map.md`

Then read the relevant agent context:
- Lead: `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/agents/lead/context.md`
- UI: `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/agents/ui/context.md`
- XMPP: `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/agents/xmpp/context.md`
- Business logic: `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/agents/business-logic/context.md`
- Push: `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/agents/push/context.md`
- Calls: `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/agents/calls/context.md`
- Tests: `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/agents/tests/context.md`

### Agent mapping

Map work to the vault agents like this:
- `xabber-lead`: intake, decomposition, shared docs, cross-agent coordination
- `xabber-ui`: `xabber/controllers`, navigation, presentation, accessibility, screen states
- `xabber-xmpp`: `xabber/xmpp`, stream lifecycle, stanzas, sync, protocol behavior
- `xabber-business`: `xabber/models`, `xabber/common`, domain rules, orchestration, session semantics
- `xabber-push`: `xabber-push-extension`, notification routing, payload handling, app reconciliation
- `xabber-calls`: `xabber/controllers/calls`, `xabber/xmpp/voip`, audio/session coordination
- `xabber-tests`: `xabberTests`, scenario coverage, regression mapping

### Required behavior during work

- Before major work, read the relevant knowledge-base notes, shared vault docs, and agent `context.md`.
- During active work, record findings and temporary reasoning in the relevant agent `notes.md`.
- For any non-trivial request, create or update a standalone task note under:
  - `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/tasks/open/`
  - `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/tasks/in-progress/`
  - `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/tasks/blocked/`
  - `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/tasks/done/`
- When work crosses agent boundaries, create or update a standalone handoff note under:
  - `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/handoffs/outgoing/`
  - `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/handoffs/incoming/`
- When a durable architectural or behavioral decision is made, record it in the relevant agent `decisions.md` and update shared docs if multiple areas are affected.
- When a topic becomes stable and broadly useful, move it out of `notes.md` into:
  - `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/docs/`
  - or an agent `decisions.md`
  - or `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/shared/` when it is a cross-agent contract

### Automatic workflow for non-trivial requests

For any bug fix, feature, refactor, or investigation that is more than a trivial one-file edit, Codex must do all of the following automatically:

1. Read the relevant knowledge-base notes, shared vault docs, and relevant agent context files.
2. Identify the owner agent and any affected secondary agents.
3. Create or update a standalone task note under `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/tasks/`.
4. Update the owner agent `inbox.md` and `tasks.md`.
5. Record investigation notes in the owner agent `notes.md` while working.
6. If another agent area owns part of the problem, create a standalone handoff note under `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/handoffs/`.
7. For code-changing tasks, write or update XCTest coverage before production code, preferably in a task-specific XCTest file.
8. Run the new or affected tests first when practical; confirm the test protects the intended behavior before implementation when the current code can expose the failure.
9. Implement the code change.
10. Run the narrowest relevant verification.
11. At the end of the task, run a build for the affected target or scheme on a connected device when available, falling back to simulator only when device execution is blocked, and check the build output for errors before closing the work.
12. Update `decisions.md`, `shared/`, or `docs/` when the result is durable.
13. Move the task note to the correct final state and record verification.

If the task is cross-cutting and no single specialist clearly owns the entire change, start from `xabber-lead` and delegate through vault task and handoff notes.

### Vault roles

- `docs/` is curated reference documentation.
- `shared/` is active coordination memory and cross-agent contracts.
- `tasks/` and `handoffs/` store one note per work item.
- Agent `README.md`, `context.md`, `inbox.md`, `tasks.md`, `handoffs.md`, `notes.md`, and `decisions.md` are dashboards plus stable memory.

### External markdown and imported documentation

When the user provides external documentation, pasted markdown, exported notes, bug reports, specs, or other `.md` content that should remain useful beyond the current chat, Codex should store it in the vault in a suitable location instead of leaving it only in conversation history.

Use these destinations:
- `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/specs/` for feature specs, requirements, and proposed behavior
- `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/research/` for exploratory or temporary imported material
- `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/docs/` for curated documentation that has been normalized for long-term use
- `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/debug/` for imported bug reports, investigation logs, or reproduction notes

Rules for imported markdown:
- Preserve the original meaning, but normalize titles, links, and structure so the note fits the vault.
- Add links to the relevant task, agent, and shared docs where useful.
- If the imported document changes project behavior or architecture, summarize the durable parts into `docs/`, `shared/`, or `decisions.md` rather than leaving the knowledge only in the imported note.
- If the user gives a one-off document that is only relevant to the current task, keep it in `research/` or `debug/` and link it from the task note.

### Minimum note updates for code changes

- UI changes:
  - update `agents/ui/notes.md`
  - update `docs/features/` or `docs/architecture/` if the flow or screen state changed materially
- XMPP or sync changes:
  - update `agents/xmpp/notes.md`
  - update `shared/interfaces.md` if behavior crosses into business, push, calls, or UI
- Business logic changes:
  - update `agents/business-logic/notes.md`
  - update `shared/interfaces.md` if exposed behavior changed
- Push changes:
  - update `agents/push/notes.md`
  - update `docs/features/push-notifications.md` when payload or reconciliation behavior changes
- Calls changes:
  - update `agents/calls/notes.md`
  - update `docs/features/calls.md` when call states or flows change
- Test strategy changes:
  - update `agents/tests/notes.md`
  - update `docs/testing/` when a scenario matrix or regression strategy changes

## Build and test policy

- After Swift or Objective-C changes, prefer running the narrowest relevant verification first.
- For code changes, follow TDD by default: add or update the focused XCTest first, then make the implementation pass.
- Prefer one dedicated XCTest file per task when practical, especially for new behavior or regressions; reuse an existing file only when that keeps the scenario clearer.
- If a package-based module exists, prefer `swift test` for package-local logic.
- For app targets, prefer `xcodebuild` with a concrete scheme and a connected physical device destination.
- Use a simulator destination only when no suitable device is connected, signing blocks device builds, the target cannot run on device, or the user explicitly asks for simulator verification.
- For any completed implementation task, run at least one build for the affected target before finishing, even if narrower tests were already run.
- Always inspect the build output for actual compiler or linker errors and report the first meaningful failure if the build does not pass.
- If a build cannot be run because of environment, signing, dependency, device, or simulator limitations, state that explicitly and record the blocker in the task note or vault notes.
- When a test fails, diagnose the first meaningful failure before making broad refactors.
- Report what was run, what passed, and what remains unverified.

## Output policy

- Summarize user-visible changes first.
- Then list files changed and verification run.
- Call out risks, assumptions, and follow-up work when relevant.
- Mention the vault notes updated when they materially affected the work.

## iOS quality bar

- UI state must be deterministic and previewable when practical.
- Networking code must separate transport, decoding, and domain mapping.
- Persistence code must define migration or fallback behavior when schema changes.
- Tests should use clear arrange-act-assert structure.
- UI tests should prefer accessibility identifiers over fragile text matching.
- Performance-sensitive code should avoid unnecessary main-thread work.

## Coordination guardrails

- Do not silently make large changes in another agent's area without recording a handoff or a shared decision.
- Do not overwrite another agent's stable context without stating why in the vault.
- Do not leave blockers only in chat when they should be durable project knowledge.
- Prefer linking related vault notes over duplicating the same context in multiple places.
