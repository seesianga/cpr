# Narrator Voice Design — Decision Record (2026-08-08)

Requirement: original ElevenLabs Voice-Design narrator (Singapore English, calm,
medically precise), ≥3 previews, evaluated, selected, id recorded outside the app.

## Previews generated (one Voice Design call → 3 variants)
Prompt: the exact voice-design prompt from the product brief (§12.2). Sample text
exercised: DRSABC, AED, "nine nine five", sternum, 100–120 rhythm wording.
Files: `Audio/VoiceDesign/voice_design_<id>_20260808_011536.mp3`

| Preview id | Duration | Integrated LUFS | LRA | STT round-trip |
|---|---|---|---|---|
| tdSKKbQweRaNBQaS1ivm | 26.75 s | −19.5 | 2.5 LU | 100% clean ("DRSABC" read as one unit) |
| **PUGMG0tgKGWJ8f778IPo** ✅ | 27.35 s | −18.1 | **2.1 LU** | 100% clean |
| rijusSeQ4SwzGvhCqUmf | 27.48 s | −17.3 | 3.3 LU | 100% clean (final word clipped in STT) |

## Objective evaluation method (honest scope)
The build environment cannot listen. Evaluation used measurable proxies:
- **Clarity** → ElevenLabs speech-to-text round-trip word accuracy (all three ≈100%).
- **Consistency / calmness for long-form** → loudness range (LRA): lower = steadier
  delivery. PUGMG0 was steadiest (2.1 LU).
- **Pace** → duration across identical text: all within 3%, moderate pace.

## Decision
Selected **PUGMG0tgKGWJ8f778IPo** → added to the voice library as **"Lifesaver
Narrator"**. Rationale: steadiest dynamics for lesson-length narration with equal
clarity. The voice id appears in generation tooling and manifests only — never in the
app bundle or Swift sources.

## Outstanding (required before release sign-off)
- **Operator listening review** of all three previews and generated narration for the
  subjective criteria (natural Singapore English pronunciation, warmth, acronym
  handling, long-form stability, accessibility for non-native listeners). Every
  manifest row carries `approvalStatus: pending_operator_listening` until then.
- Singapore-based reviewer verification of the pronunciation set (AED, CPR, SRFAC,
  SCDF, DRSABC, ventricular fibrillation, defibrillation, sternum, xiphoid, pacemaker,
  resuscitation, casualty, "nine nine five") — tracked in MEDICAL_REVIEW_REQUIRED.

## Other voice roles (differentiated settings per brief §12.3)
| Role | Voice | Model / settings |
|---|---|---|
| Academy guide (narration) | Lifesaver Narrator (original design) | eleven_multilingual_v2 · stab 0.78 · sim 0.82 · style 0.12 · speaker boost |
| System safety voice | "River" (premade library, licensed via subscription) | eleven_multilingual_v2 · stab 0.80 · sim 0.80 · style 0.05 |
| Simulated dispatcher | NOT VOICED in v1 — no approved dispatcher dialogue text exists in course data (audit finding 1 reduced the 995 beats); revisit after SME approval | — |
| Scenario bystander | NOT VOICED in v1 — same grounding rule; bystander presence is visual + captioned | — |

Grounding rule: only text present in approved course data is synthesised; no dialogue
was invented for voicing.
