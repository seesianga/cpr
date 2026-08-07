# Adversarial Clinical Content Audit — course content v1.0.0

Audit performed 2026-08-07 by an independent adversarial reviewer against
`Docs/CLINICAL_FACTS_EXTRACT.json`, the three content files, the traceability matrix,
the enforcement code, and 12+ citations spot-checked against the source PDFs.

## Verdicts (attack areas)
1. Invented medical instruction — **CONFIRMED-SAFE** (one borderline, Finding 1)
2. 2018 guidance taught as current — **CONFIRMED-SAFE**
3. `requires_sme_review` facts in scored items — **CONFIRMED-SAFE** at fact level (Finding 4 caveat)
4. Clinical numbers — **CONFIRMED-SAFE** (verified against source PDFs incl. page-offset conventions)
5. Unsafe-behaviour rewards — **CONFIRMED-SAFE** (Finding 5 is consistency, not hazard)
6. Module 9 gating — content SAFE; enforcement wiring gap (Finding 2)
7. Verbatim copy / branding — **CONFIRMED-SAFE** (clause-level echoes, Finding 6)
8. Traceability — **CONFIRMED-SAFE** (informational, Finding 7)

## Remediation list (MANDATORY before final release; fix in Phase 4R/5)

1. **M3 995-dialogue beats exceed their cited fact.**
   `Resources/Courses/course_v1.json` `modules[3].lessons[0].contentBlocks[3]` (M3-B4) and
   `interactiveActivities[1]` (M3-A2): "state the location, confirm a callback number,
   describe the incident and give the casualty count" derives only from the *notes* of
   `fact.drsabc.call995`, not its statement. Fix: add a dedicated fact citing M18 B2
   Step 3 (p.15) with `requires_sme_review` OR reduce beats to "answer the dispatcher's
   questions and hang up only when told".

2. **`ModuleAccessEvaluator` has no production caller.**
   `Core/Models/Phase3BContentModels.swift:41` is exercised only by tests. All module
   presentation UI (Phase 5) MUST route through `ModuleAccessEvaluator`; add a UI/unit
   test asserting M9 stays locked without instructor approval + clinicallyApproved lifecycle.

3. **Scored-scenario validation skips sub-elements.**
   `Core/Services/ClinicalSafetyValidator.swift:53–54` validates only
   `scenario.sourceReferences` + `criticalActions`. Extend to collect references from
   `criticalErrors`, `branchingNodes`, `feedbackStatements`, `initialState`.

4. **Scored assessments inside review-required lessons.**
   `assessment-m2-theory-v1` / `assessment-m10-theory-v1` are `isScored: true` while
   `MEDICAL_REVIEW_REQUIRED.md` rows M2-L1/M10-L1 say they must remain outside scoring
   while unresolved. Propagate container `reviewStatus` downward in the validator or
   record an explicit rationale; consider holding q-m2-01/q-m2-05 (Prevention/Recovery
   rings) unscored until the 5-vs-7-ring SME item resolves.

5. **`noShockOutcome` branches omit the clear action.**
   All four scenarios (e.g. `scenarios[0].branchingNodes[4].conditions[1].requiredActionIDs`)
   require only `…resume-cpr` where the shock branch also requires `…clear-for-aed`.
   Analysis precedes both outcomes; add the clear action to every `noShockOutcome` condition.

6. **Clause-level verbatim echoes.** M3-B2 "…safe, flat and open space as soon as
   possible" and criticalActions[1] "Tap the casualty's shoulders firmly and ask loudly…"
   match M22 p.18 phrasing. Lightly rephrase to honour the strict-paraphrase policy.

7. **Informational.** (a) Assessment-container and question-choice IDs have no matrix
   rows of their own (parents are rowed) — note this convention in the matrix header.
   (b) Four deliberately excluded ventilation facts (`fact.ventilation.*`) are cited
   nowhere — state the S11 exclusion explicitly in the matrix.

## Residual limitation
Runtime behaviour is unverifiable until the learner UI exists: gating/scoring guarantees
currently live in data, engine code and tests, not in an auditable running product.
Finding 2 closes this for module access; Phase 5 scenario UI must keep engines authoritative.
