#!/usr/bin/env python3
"""Build the versioned Phase 3B course JSON from reviewed source metadata.

Learner-facing copy is authored here, while citations are copied directly from
Docs/CLINICAL_FACTS_EXTRACT.json. The script never promotes review status and
fails if an authored fact identifier is absent from the extract.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parents[1]
FACTS_PATH = ROOT / "Docs" / "CLINICAL_FACTS_EXTRACT.json"
QUESTIONS_PATH = ROOT / "Resources" / "Questions" / "theory_questions_v1.json"
SCENARIOS_PATH = ROOT / "Resources" / "Courses" / "scenarios_v1.json"
OUTPUT_PATH = ROOT / "Resources" / "Courses" / "course_v1.json"
CONTENT_VERSION = "1.0.0"


def load_json(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


FACT_DOCUMENT = load_json(FACTS_PATH)
FACTS = {fact["id"]: fact for fact in FACT_DOCUMENT["facts"]}


def fact_references(item_id: str, *fact_ids: str) -> list[dict[str, Any]]:
    references: list[dict[str, Any]] = []
    for fact_id in fact_ids:
        if fact_id not in FACTS:
            raise ValueError(f"Unknown clinical fact ID: {fact_id}")
        fact = FACTS[fact_id]
        for source_index, source in enumerate(fact["sources"], start=1):
            references.append(
                {
                    "id": f"{item_id}-ref-{fact_id.removeprefix('fact.').replace('.', '-')}-{source_index}",
                    "document": source["doc"],
                    "edition": source["edition"],
                    "section": source["section"],
                    "page": str(source["page"]),
                    "reviewStatus": fact["reviewStatus"],
                    "reviewer": None,
                    "lastClinicalReviewDate": None,
                    "contentVersion": CONTENT_VERSION,
                    "clinicalFactID": fact_id,
                }
            )
    return references


def policy_reference(
    item_id: str,
    section: str,
    *,
    document: str = "Docs/PHASE3B_CONTENT_POLICY.md",
    edition: str = "1.0 (2026-08-07)",
    page: str = "n/a (Markdown)",
    review_status: str = "source_checked",
) -> dict[str, Any]:
    return {
        "id": f"{item_id}-policy-ref",
        "document": document,
        "edition": edition,
        "section": section,
        "page": page,
        "reviewStatus": review_status,
        "reviewer": None,
        "lastClinicalReviewDate": None,
        "contentVersion": CONTENT_VERSION,
        "clinicalFactID": None,
    }


def supplemental_source_reference(
    item_id: str,
    suffix: str,
    *,
    document: str,
    edition: str,
    section: str,
    page: str,
    review_status: str = "source_checked",
) -> dict[str, Any]:
    """Cite an exact source named in an extract note or reconciliation record.

    These historical comparison citations intentionally do not claim a separate
    clinical fact ID. The learner-facing statement remains backed by the
    accompanying extract fact; this reference makes the edition comparison
    independently auditable.
    """
    return {
        "id": f"{item_id}-supplemental-{suffix}",
        "document": document,
        "edition": edition,
        "section": section,
        "page": page,
        "reviewStatus": review_status,
        "reviewer": None,
        "lastClinicalReviewDate": None,
        "contentVersion": CONTENT_VERSION,
        "clinicalFactID": None,
    }


def missing_fact_reference(item_id: str, topic: str) -> dict[str, Any]:
    return policy_reference(
        item_id,
        f"Phase 3B requested topic with no supporting clinical fact: {topic}",
        document="Docs/CLINICAL_FACTS_EXTRACT.json",
        edition="2026-08-07 extract",
        page="unresolved evidence gap",
        review_status="requires_sme_review",
    )


def objective(
    identifier: str,
    statement: str,
    *fact_ids: str,
    policy_section: str | None = None,
    additional_references: Iterable[dict[str, Any]] = (),
) -> dict[str, Any]:
    references = fact_references(identifier, *fact_ids) if fact_ids else [
        policy_reference(identifier, policy_section or "Phase 3B learning objective")
    ]
    references.extend(additional_references)
    return {"id": identifier, "statement": statement, "sourceReferences": references}


def block(
    identifier: str,
    title: str,
    body: str,
    *fact_ids: str,
    kind: str = "text",
    review_status: str | None = None,
    policy_section: str | None = None,
    missing_topic: str | None = None,
    additional_references: Iterable[dict[str, Any]] = (),
) -> dict[str, Any]:
    if missing_topic:
        references = [missing_fact_reference(identifier, missing_topic)]
    elif fact_ids:
        references = fact_references(identifier, *fact_ids)
    else:
        references = [policy_reference(identifier, policy_section or "Phase 3B course content")]
    references.extend(additional_references)
    if review_status is None:
        review_status = (
            "clinicalReviewRequired"
            if any(reference["reviewStatus"] == "requires_sme_review" for reference in references)
            else "sourceChecked"
        )
    return {
        "id": identifier,
        "kind": kind,
        "title": title,
        "body": body,
        "reviewStatus": review_status,
        "sourceReferences": references,
    }


def activity(
    identifier: str,
    title: str,
    activity_type: str,
    instructions: str,
    *fact_ids: str,
    policy_section: str | None = None,
    additional_references: Iterable[dict[str, Any]] = (),
) -> dict[str, Any]:
    references = fact_references(identifier, *fact_ids) if fact_ids else [
        policy_reference(identifier, policy_section or "Phase 3B interaction design")
    ]
    references.extend(additional_references)
    return {
        "id": identifier,
        "title": title,
        "activityType": activity_type,
        "instructions": instructions,
        "sourceReferences": references,
    }


def unique_references(items: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    seen: set[tuple[str, str | None]] = set()
    result: list[dict[str, Any]] = []
    for item in items:
        for reference in item.get("sourceReferences", []):
            key = (reference["id"], reference.get("clinicalFactID"))
            if key not in seen:
                seen.add(key)
                result.append(reference)
    return result


def module(
    identifier: str,
    title: str,
    summary: str,
    order: int,
    objectives: list[dict[str, Any]],
    blocks: list[dict[str, Any]],
    activities: list[dict[str, Any]],
    *,
    review_status: str = "sourceChecked",
    access_requirements: dict[str, Any] | None = None,
) -> dict[str, Any]:
    lesson_id = f"{identifier}-L1"
    lesson_items = objectives + blocks + activities
    lesson_refs = unique_references(lesson_items)
    lesson = {
        "id": lesson_id,
        "title": title,
        "summary": summary,
        "order": 1,
        "learningObjectives": objectives,
        "contentBlocks": blocks,
        "interactiveActivities": activities,
        "scenarios": [],
        "assessments": [],
        "sourceReferences": lesson_refs,
    }
    result = {
        "id": identifier,
        "title": title,
        "summary": summary,
        "order": order,
        "reviewStatus": review_status,
        "accessRequirements": access_requirements,
        "lessons": [lesson],
        "sourceReferences": lesson_refs,
    }
    return result


def build_m0() -> dict[str, Any]:
    objectives = [
        objective("M0-O1", "Set up a comfortable and accessible practice session before entering immersive learning.", policy_section="Orientation content requirements"),
        objective("M0-O2", "Describe the app's hand-tracking, emergency-call and completion-record limits.", policy_section="Simulation and completion boundaries"),
        objective("M0-O3", "Choose a dominant hand and input method, then complete an unscored knowledge check.", policy_section="Orientation content requirements"),
    ]
    blocks = [
        block("M0-B1", "Training scope", "Lifesaver Vision is a practice academy. Where an activity offers practice feedback, it is limited to sequence, hand-placement zone, rhythm, interruptions and posture heuristics. Hand tracking does not measure physical compression depth or force; those fields remain labelled ‘Not physically assessed’ unless a verified external CPR sensor is connected.", policy_section="Medical and sensing boundaries"),
        block("M0-B2", "SIMULATION — 995", "Every 995 interaction in the academy is clearly labelled SIMULATION. It rehearses communication only and never places a telephone call.", kind="callout", policy_section="Simulation and completion boundaries"),
        block("M0-B3", "Leave immersion at any time", "Use the persistent Exit Simulation control whenever you feel uncomfortable or want to return to the shared-space dashboard. Learning progress is not treated as clinical performance merely because an immersive session was opened or closed.", policy_section="Verified runtime boundaries"),
        block("M0-B4", "Comfort calibration", "Before practice, position the learning volume comfortably with the available system controls, confirm that the floor and nearby space are clear, and use a seated or standing presentation only where the activity allows it. These are learner comfort checks rather than stored calibration measurements. Stop the immersive session whenever comfort changes.", policy_section="Orientation content requirements"),
        block("M0-B5", "Dominant hand and input", "Confirm your dominant hand and preferred supported input method in the device's accessibility and input settings before practice. This release does not store a separate in-app dominant-hand profile. Input choices do not change the clinical sequence being taught.", policy_section="Orientation content requirements"),
        block("M0-B6", "Accessibility setup", "Use device text-accessibility settings as needed. In the app, set captions, audio level, increased contrast and reduced motion before starting. Knowledge checks are untimed and can be reopened for review without penalty.", policy_section="Verified runtime boundaries"),
        block("M0-B7", "Hand-data handling", "Hand-tracking permission is optional. When a supported practice activity requests it, hand position and motion are processed on the device; the declared hand-tracking purpose states that this data is not stored. The current permission service alone does not provide CPR-quality measurements.", policy_section="Medical and sensing boundaries"),
        block("M0-B8", "Learning records and privacy", "The local-first LMS may retain progress, attempts, feedback, sign-off and learning-event records. Learners can export their local record and request local deletion through the privacy controls. The privacy manifest declares no tracking and no collected-data categories.", policy_section="Data handling"),
        block("M0-B9", "Completion is not accreditation", "Course completion produces an internal completion record only. It is not SRFAC certification. Practical competency requires a qualified instructor's recorded sign-off.", kind="callout", policy_section="Simulation and completion boundaries"),
        block("M0-B10", "Request instructor assessment", "After completing the adult core and practice activities, ask a qualified instructor to schedule a practical assessment. The current learner interface does not submit that request automatically. An instructor may approve the practical sign-off or return focused remediation; self-completion cannot replace that decision.", policy_section="Verified runtime boundaries"),
        block("M0-B11", "Pre-course knowledge check", "The six-question check establishes a starting point. It is unscored, untimed and does not block learning; every answer review links to a source-checked clinical fact.", policy_section="Orientation content requirements"),
    ]
    activities = [
        activity("M0-A1", "Comfort and access calibration", "onboardingCalibration", "Use the available device and app settings to confirm comfort, dominant hand, input method, captions, text accessibility, contrast and motion preferences before continuing.", policy_section="Orientation content requirements"),
        activity("M0-A2", "Pre-course knowledge check", "diagnosticAssessment", "Answer six untimed, unscored source-backed questions. Review the explanation for every choice.", policy_section="Orientation content requirements"),
    ]
    return module("M0", "Orientation & Safety", "App boundaries, comfort, access, privacy and the unscored starting check.", 0, objectives, blocks, activities)


def build_m1() -> dict[str, Any]:
    objectives = [
        objective("M1-O1", "Distinguish cardiac arrest from a heart attack using the supported warning and recognition facts.", "fact.recognition.cardiacArrestDefinition", "fact.recognition.heartAttackVsArrest"),
        objective("M1-O2", "Explain why recognition, compressions and defibrillation are time-critical.", "fact.recognition.timeCriticality", "fact.recognition.vfSurvivalDecay"),
        objective("M1-O3", "Recognise gasping as abnormal breathing and interpret the supplied 2019 Singapore OHCA figures.", "fact.recognition.gaspingAbnormal", "fact.recognition.ohcaStatistics2019"),
    ]
    blocks = [
        block("M1-B1", "What cardiac arrest means", "During cardiac arrest the heart is no longer pumping blood. The casualty becomes unresponsive and does not breathe normally; ventricular fibrillation develops in many arrests.", "fact.recognition.cardiacArrestDefinition"),
        block("M1-B2", "Heart attack and cardiac arrest are different", "A heart attack begins with a blocked coronary artery and can progress to cardiac arrest if untreated. Warning signs supported by the source include chest or upper-abdominal tightness or discomfort, possible spread towards the left shoulder or arm, neck or lower jaw, sudden breathlessness, sweating, nausea, vomiting or dizziness. The source directs calling 995 and going to an Emergency Department.", "fact.recognition.heartAttackVsArrest"),
        block("M1-B3", "Minutes matter", "Brain cells begin to die within about four to six minutes after cardiac arrest, and irreversible injury may begin at roughly four minutes without restored circulation. The supplied manuals report survival near 90% with immediate reversal, around 40–50% at six minutes and about 10% by nine minutes.", "fact.recognition.timeCriticality"),
        block("M1-B4", "Shockable rhythms", "Ventricular fibrillation and pulseless ventricular tachycardia are shockable rhythms. The supplied sources report that survival from VF falls by about 7–10% for each minute treatment is delayed; untreated VF can deteriorate to asystole, which is not shockable and is managed with CPR.", "fact.recognition.vfSurvivalDecay"),
        block("M1-B5", "Gasping is not normal breathing", "Agonal gasps do not count as normal breathing. If breathing is absent or abnormal, or you are unsure, begin chest compressions immediately.", kind="callout", *["fact.recognition.gaspingAbnormal"]),
        block("M1-B6", "Singapore OHCA snapshot", "The 2019 registry recorded 3,233 out-of-hospital cardiac arrests in Singapore. About 74% occurred at home; bystander CPR occurred in 60%, bystander defibrillation in 10.5%, overall survival was 6.2%, and 4.8% were discharged with good-to-moderate neurological function.", "fact.recognition.ohcaStatistics2019"),
        block(
            "M1-B7",
            "Guideline update: use the 2019 registry",
            "The 2018 manual presented older 2015 registry figures. This course uses the later 2019 figures contained in the 2022 manual; the older values appear only as historical context.",
            "fact.recognition.ohcaStatistics2019",
            kind="callout",
            additional_references=[
                supplemental_source_reference(
                    "M1-B7",
                    "m18",
                    document="SRFAC-CPRHOAED-Manual-2018-2.pdf",
                    edition="2018",
                    section="A-1",
                    page="3",
                )
            ],
        ),
        block("M1-B8", "Anatomy scope", "This release does not add detailed heart or lung anatomy beyond the circulation, breathing and rhythm facts in the approved extract. Any spatial visual used with this lesson is an orientation aid, not a diagnostic or anatomical reference.", policy_section="Medical and sensing boundaries"),
    ]
    activities = [
        activity("M1-A1", "Recognition sort", "conceptSort", "Sort source-backed cues into heart-attack warning signs, cardiac-arrest recognition and unsupported cues; then review the citations.", "fact.recognition.cardiacArrestDefinition", "fact.recognition.heartAttackVsArrest", "fact.recognition.gaspingAbnormal"),
    ]
    return module("M1", "Cardiac Arrest & the Body", "Recognition, circulation, breathing, rhythm and time-critical response.", 1, objectives, blocks, activities)


def build_m2() -> dict[str, Any]:
    objectives = [
        objective(
            "M2-O1",
            "Describe the meaning of each current Chain of Survival ring while recognising that the preferred ring count and graphic await SME confirmation.",
            "fact.chain.sevenRings",
            "fact.chain.ringDefinitions",
            additional_references=[
                supplemental_source_reference(
                    "M2-O1", "g21", document="03-SG-BCLSAED-Guidelines-2021.pdf", edition="2021", section="Chain of Survival graphic", page="5", review_status="requires_sme_review"
                )
            ],
        ),
        objective("M2-O2", "Explain why early CPR and early defibrillation work together.", "fact.chain.earlyCprPlusDefib"),
        objective(
            "M2-O3",
            "Identify what changed from the five-ring 2018 presentation to the seven-ring 2022 presentation.",
            "fact.chain.sevenRings",
            additional_references=[
                supplemental_source_reference(
                    "M2-O3", "m18", document="SRFAC-CPRHOAED-Manual-2018-2.pdf", edition="2018", section="A-7 Chain of Survival", page="11", review_status="requires_sme_review"
                ),
                supplemental_source_reference(
                    "M2-O3", "g21", document="03-SG-BCLSAED-Guidelines-2021.pdf", edition="2021", section="Chain of Survival graphic", page="5", review_status="requires_sme_review"
                ),
            ],
        ),
    ]
    blocks = [
        block(
            "M2-B1",
            "Current learning sequence — seven rings",
            "The active learning sequence follows the 2022 provider manual: Prevention; Early Activation and AED Access; Early CPR; Early Defibrillation; Emergency Medical Services (Ambulance); Advanced Cardiac Life Support; Recovery. The two current supplied sources differ on the graphic and ring count, so this card is excluded from scoring until a qualified SME approves the presentation.",
            "fact.chain.sevenRings",
            kind="callout",
            additional_references=[
                supplemental_source_reference(
                    "M2-B1", "g21", document="03-SG-BCLSAED-Guidelines-2021.pdf", edition="2021", section="Chain of Survival graphic", page="5", review_status="requires_sme_review"
                )
            ],
        ),
        block("M2-B2", "What the rings mean", "Prevention covers reducing risk through a healthy lifestyle and regular checks. Activation means calling 995, following the dispatcher and arranging a nearby visible AED through another person; a lone rescuer stays with the casualty. Early CPR means starting promptly because brain cells can begin dying within four to six minutes. Early Defibrillation means applying a community AED and being ready to shock. EMS and advanced hospital care continue treatment, and Recovery represents rehabilitation and community support.", "fact.chain.ringDefinitions", "fact.drsabc.getAed"),
        block("M2-B3", "CPR and defibrillation belong together", "The supplied historic outcome chart shows the strongest survival when CPR, defibrillation and advanced care begin very early, compared with no CPR and a delayed shock.", "fact.chain.earlyCprPlusDefib"),
        block(
            "M2-B4",
            "What changed since the 2018 manual?",
            "The 2018 manual taught five rings. The 2022 manual adds Prevention and Recovery to form seven, while the 2021 update deck still shows five. Lifesaver Vision follows the 2022 sequence for learning, labels the disagreement, and keeps ring-count questions out of scored assessment pending SME approval.",
            "fact.chain.sevenRings",
            kind="callout",
            additional_references=[
                supplemental_source_reference(
                    "M2-B4", "m18", document="SRFAC-CPRHOAED-Manual-2018-2.pdf", edition="2018", section="A-7 Chain of Survival", page="11", review_status="requires_sme_review"
                ),
                supplemental_source_reference(
                    "M2-B4", "g21", document="03-SG-BCLSAED-Guidelines-2021.pdf", edition="2021", section="Chain of Survival graphic", page="5", review_status="requires_sme_review"
                ),
            ],
        ),
    ]
    activities = [
        activity("M2-A1", "Chain learning gallery", "spatialSequenceGallery", "Explore each ring meaning. The seven-ring visual remains labelled clinical review required and contributes no score.", "fact.chain.sevenRings", "fact.chain.ringDefinitions"),
    ]
    return module("M2", "Chain of Survival", "The current seven-ring learning sequence, its meanings and the documented source disagreement.", 2, objectives, blocks, activities)


def build_m3() -> dict[str, Any]:
    objectives = [
        objective("M3-O1", "Apply DRSABC in order and branch safely for unsafe scenes, responsiveness and breathing.", "fact.drsabc.mnemonic", "fact.drsabc.danger", "fact.drsabc.responsiveness", "fact.drsabc.breathingCheck", "fact.drsabc.monitorIfBreathingNormally"),
        objective("M3-O2", "Rehearse a clearly labelled simulated 995 call using speaker mode and dispatcher guidance.", "fact.drsabc.call995", "fact.drsabc.dispatcherCapabilities"),
        objective("M3-O3", "Choose correct AED retrieval behaviour when a bystander is present or the rescuer is alone.", "fact.drsabc.getAed"),
    ]
    blocks = [
        block("M3-B1", "DRSABC", "D: check Danger. R: check Responsiveness. S: Shout for help and call 995 for SCDF. A: Ask someone to get an AED. B: check for normal Breathing. C: begin continuous Chest Compressions when normal breathing is absent or uncertain. Pulse checks belong only to the clearly labelled trained-healthcare-provider path.", "fact.drsabc.mnemonic"),
        block("M3-B2", "Danger comes first", "Work only in a safe environment. Begin where the casualty is found unless traffic, fire, a wet floor, falling objects or another condition makes that place unsafe or unsuitable; then move the casualty to a safe, flat and open space as soon as possible.", "fact.drsabc.danger"),
        block("M3-B3", "Responsiveness and position", "Tap the shoulders firmly and ask loudly whether the casualty is okay. Do not shake violently or move the neck unnecessarily. Effective CPR needs the casualty on their back on a firm, flat surface; if turning is required, support and turn the head, neck and body together.", "fact.drsabc.responsiveness", "fact.drsabc.positionCasualty"),
        block(
            "M3-B4",
            "SIMULATION — 995 call rehearsal",
            "This rehearsal never dials. Call 995 in the scenario, use speaker mode and stay on the line. Dialogue beats ask the learner to state the location, confirm a callback number, describe the incident and give the casualty count, then follow the simulated dispatcher's coaching.",
            "fact.drsabc.call995",
            kind="callout",
            additional_references=[
                supplemental_source_reference(
                    "M3-B4", "m18-dialogue", document="SRFAC-CPRHOAED-Manual-2018-2.pdf", edition="2018", section="B2 Step 3", page="15"
                )
            ],
        ),
        block("M3-B5", "Dispatcher support", "The supplied sources state that a 995 dispatcher can locate a nearby AED, summon trained volunteers in the vicinity and coach chest compressions. Volunteer myResponder participation is voluntary.", "fact.drsabc.dispatcherCapabilities"),
        block("M3-B6", "Bystander available or alone", "When another person is available, ask them to fetch an AED that is within about a 60-second walk. When you are the lone rescuer, stay with the casualty and begin compressions rather than leaving to search for an AED.", "fact.drsabc.getAed"),
        block(
            "M3-B7",
            "Guideline update: the lone rescuer stays",
            "The 2018 manual allowed a lone rescuer to fetch an AED when it was visible and nearby. Current supplied guidance says the lone rescuer must not leave the casualty; another person should retrieve an AED within the stated walking-distance rule.",
            "fact.drsabc.getAed",
            kind="callout",
            additional_references=[
                supplemental_source_reference(
                    "M3-B7", "m18-b2", document="SRFAC-CPRHOAED-Manual-2018-2.pdf", edition="2018", section="B2", page="14"
                ),
                supplemental_source_reference(
                    "M3-B7", "m18-c1", document="SRFAC-CPRHOAED-Manual-2018-2.pdf", edition="2018", section="C-1", page="24"
                ),
            ],
        ),
        block("M3-B8", "Breathing branch", "Look for chest rise and fall for no more than 10 seconds. Gasping is not normal breathing. If breathing is absent or abnormal, or you are unsure, begin CPR. If breathing is normal, do not compress; keep monitoring while waiting for EMS.", "fact.drsabc.breathingCheck", "fact.recognition.gaspingAbnormal", "fact.drsabc.monitorIfBreathingNormally"),
        block("M3-B9", "Remote-area exception", "If a lone rescuer in a remote area has no way to activate EMS, assess responsiveness and breathing, start compressions immediately when normal breathing is absent, and continue for at least two minutes before leaving to seek help. This is an edge case, not the main flow.", "fact.drsabc.remoteAreaException", kind="callout"),
        block("M3-B10", "Healthcare-provider path", "Only the HCP-labelled path includes a carotid pulse check together with breathing for no more than 10 seconds. If there is no definite pulse or there is doubt, the trained provider assumes arrest and starts compressions. The lay path does not ask learners to check a pulse.", "fact.drsabc.pulseCheckHcpOnly"),
        block("M3-B11", "Guideline update: speaker mode and connected response", "Current sources emphasise speaker-phone dispatcher-assisted CPR and describe dispatcher support for AED location and nearby volunteer responders. The app rehearses that current flow while keeping every call simulated.", "fact.drsabc.call995", "fact.drsabc.dispatcherCapabilities", "fact.aed.myResponder", kind="callout"),
    ]
    activities = [
        activity("M3-A1", "DRSABC branching rehearsal", "branchingDialogue", "Work through all supplied conditions: scene safe or unsafe; bystander available or alone; AED near or far; casualty gasping, not breathing normally, or breathing normally. The clinical rule attached to each branch never changes.", "fact.drsabc.danger", "fact.drsabc.getAed", "fact.recognition.gaspingAbnormal", "fact.drsabc.monitorIfBreathingNormally"),
        activity(
            "M3-A2",
            "SIMULATION — 995 dialogue",
            "simulatedEmergencyCall",
            "Practise the location, callback, incident and casualty-count dialogue beats, keep the simulated phone on speaker, and follow the on-screen dispatcher. No call is placed.",
            "fact.drsabc.call995",
            additional_references=[
                supplemental_source_reference(
                    "M3-A2", "m18-dialogue", document="SRFAC-CPRHOAED-Manual-2018-2.pdf", edition="2018", section="B2 Step 3", page="15"
                )
            ],
        ),
    ]
    return module("M3", "DRSABC", "A source-backed recognition and activation state sequence with explicit branches.", 3, objectives, blocks, activities)


def build_m4() -> dict[str, Any]:
    objectives = [
        objective("M4-O1", "Set up the casualty and adult hand position on the supported compression landmark.", "fact.drsabc.positionCasualty", "fact.compression.site", "fact.compression.handMethodAdult"),
        objective("M4-O2", "Practise a 100–120-per-minute rhythm with full recoil and minimal interruption.", "fact.compression.rate", "fact.compression.recoil", "fact.compression.minimiseInterruptions"),
        objective("M4-O3", "State the stop conditions and the app's depth-assessment limitation.", "fact.compression.depthAdult", "fact.compression.stopCriteria"),
    ]
    blocks = [
        block("M4-B1", "Firm, flat surface", "Place the casualty on their back on a firm, flat surface before compressions. If the casualty must be rolled, support and turn the head, neck and body together.", "fact.drsabc.positionCasualty"),
        block("M4-B2", "Landmark and xiphoid avoidance", "Use the centre of the chest over the lower half of the sternum. Expose the chest adequately and do not compress on the xiphoid process at the lower tip of the breastbone.", "fact.compression.site", kind="callout"),
        block("M4-B3", "Adult hand position and posture", "Kneel beside the casualty. Put one hand heel on the lower half of the sternum and the other on top, interlace and lift the fingers away from the chest wall, lock both elbows, bring the shoulders above the chest and use body weight.", "fact.compression.handMethodAdult"),
        block("M4-B4", "Rate and the 110 practice tempo", "The sourced adult compression rate is 100–120 per minute. The authored rhythm exercise uses 110 beats per minute as a practice tempo inside that approved band; 110 is not a separate guideline target. A live metronome remains dependent on the practice-view implementation.", "fact.compression.rate"),
        block("M4-B5", "Full recoil", "Let the chest recoil completely after each compression while keeping the heels of the hands in contact with the chest.", "fact.compression.recoil"),
        block("M4-B6", "Count and control interruptions", "Count aloud in cycles of five up to 100 to support rhythm and tracking. Keep compressions continuous. If a lone rescuer becomes tired, any rest should be no longer than 10 seconds and preferably only after about 100 compressions, followed by an immediate restart.", "fact.compression.counting", "fact.compression.restRule", "fact.compression.minimiseInterruptions"),
        block("M4-B7", "Depth — Not physically assessed", "The supplied sources teach an adult depth of 4–6 cm. Lifesaver Vision hand tracking cannot measure real depth or force, so the course labels depth and force ‘Not physically assessed’. No score may use a fabricated depth value; only supported placement, rhythm, interruption and posture signals are eligible.", "fact.compression.depthAdult", kind="callout"),
        block("M4-B8", "When to stop compressions", "Continue until paramedics or an in-facility emergency team take over, the AED says it is analysing, charging or about to shock, or the casualty wakes or resumes normal breathing. The lay path does not add a pulse check.", "fact.compression.stopCriteria"),
        block("M4-B9", "Hands-only default", "A rescuer who is untrained, unable or unwilling to give ventilations should provide continuous high-quality chest compressions. A trained, able and willing rescuer may use 30 compressions to 2 breaths, with each breath over one second while watching for chest rise.", "fact.ventilation.handsOnlyDefault", "fact.ventilation.thirtyToTwoIfTrained"),
    ]
    activities = [
        activity("M4-A1", "110 BPM rhythm practice", "cprRhythmPractice", "Use a 110 BPM reference tempo to practise inside the approved 100–120 range. Review only supported rhythm, hand-placement, interruption and posture signals; depth and force remain Not physically assessed.", "fact.compression.rate", "fact.compression.site", "fact.compression.minimiseInterruptions", "fact.compression.handMethodAdult"),
    ]
    return module("M4", "Hands-only CPR", "Adult positioning, hand placement, rhythm, recoil, interruptions and honest sensing limits.", 4, objectives, blocks, activities)


def build_m5() -> dict[str, Any]:
    objectives = [
        objective("M5-O1", "Explain what an AED does and power it on while compressions continue where possible.", "fact.aed.purpose", "fact.aed.applyDuringCpr"),
        objective("M5-O2", "Prepare a bare, dry chest and respond correctly to hair, jewellery, implanted devices and patches.", "fact.aed.chestPrepHairyChest", "fact.aed.chestPrepJewellery", "fact.aed.chestPrepImplantedDevices", "fact.aed.chestPrepPatches", "fact.aed.chestPrepWet"),
        objective("M5-O3", "Identify metal, water and flammable-gas hazards before AED use.", "fact.aed.hazards"),
    ]
    blocks = [
        block("M5-B1", "What the AED does", "An AED reads the heart rhythm through its pads, decides whether a shock is needed, charges only for a shockable rhythm and guides the rescuer with voice prompts. Some devices also provide a compression-tempo count.", "fact.aed.purpose"),
        block("M5-B2", "Bring an AED to every arrest", "When 995 is activated, direct an available bystander to get an AED. Early compressions combined with early defibrillation provide the best chance described by the supplied sources; a lone rescuer still stays with the casualty rather than leaving to search.", "fact.aed.bringToEveryArrest", "fact.drsabc.getAed"),
        block("M5-B3", "Power on and follow prompts", "Continue compressions while the AED arrives. Open the AED, switch it on—some models start when the lid opens—and follow its prompts while preparing the chest and pads.", "fact.aed.applyDuringCpr", "fact.aed.padPlacementAdult"),
        block("M5-B4", "Environmental hazards", "Move the casualty away from metal contact, wet surfaces and flammable-gas or oxygen sources. Move to a dry area and wipe the chest quickly before applying the pads.", "fact.aed.hazards", "fact.aed.chestPrepWet", kind="callout"),
        block("M5-B5", "Expose and prepare the chest", "Expose the chest, cutting clothing away if necessary. Prepare only what is needed for fast, secure pad contact while compressions continue wherever possible.", "fact.aed.chestPrepJewellery", "fact.aed.applyDuringCpr"),
        block("M5-B6", "Hair at a pad site", "If chest hair prevents pad contact, shave the required pad sites promptly using the shaver supplied with the AED kit.", "fact.aed.chestPrepHairyChest"),
        block("M5-B7", "Jewellery", "Move metallic necklaces and chains clear of the pad sites because nearby metal can spark and burn during a shock.", "fact.aed.chestPrepJewellery"),
        block("M5-B8", "Pacemaker or implanted defibrillator", "If a pacemaker or implanted defibrillator is visible as a lump or scar, place the AED pads at least four fingers' breadth away from it.", "fact.aed.chestPrepImplantedDevices"),
        block("M5-B9", "Medication patches and electrodes", "Remove medication patches and monitoring electrodes from the chest wall because they can obstruct correct pad placement.", "fact.aed.chestPrepPatches"),
        block("M5-B10", "Wet or sweaty chest", "Wipe a wet or sweaty chest dry quickly so the pads adhere, then apply them with minimal interruption to compressions.", "fact.aed.chestPrepWet"),
        block("M5-B11", "Retrieve a public-access AED safely", "Do not strike break-glass panels with bare hands or elbows. Use an object such as a phone, shoe or keys, then clear fragments from the edge before reaching for the key.", "fact.aed.retrievalSafety"),
        block("M5-B12", "myResponder context", "The SCDF myResponder app can alert voluntary Community First Responders within 400 metres and show nearby AEDs, supporting help before the ambulance arrives.", "fact.aed.myResponder"),
    ]
    activities = [
        activity("M5-A1", "Chest-preparation decision lab", "aedPreparationLab", "Choose the source-backed response for metal, water, hair, jewellery, implanted devices, medication patches and a wet chest while protecting compression continuity.", "fact.aed.hazards", "fact.aed.chestPrepHairyChest", "fact.aed.chestPrepJewellery", "fact.aed.chestPrepImplantedDevices", "fact.aed.chestPrepPatches", "fact.aed.chestPrepWet", "fact.compression.minimiseInterruptions"),
    ]
    return module("M5", "AED Preparation", "Power-on, prompt following, environmental safety and chest preparation.", 5, objectives, blocks, activities)


def build_m6() -> dict[str, Any]:
    objectives = [
        objective("M6-O1", "Complete the ten-step adult AED application sequence with correct pad placement.", "fact.aed.applyDuringCpr", "fact.aed.padPlacementAdult"),
        objective("M6-O2", "Apply the no-touch and visual clear-check rules during analysis, charging and shock.", "fact.aed.analysisNoTouch", "fact.aed.shockDelivery"),
        objective("M6-O3", "Resume compressions after shock or no-shock advice and keep the AED connected.", "fact.aed.resumeAfterShock", "fact.aed.noShockAdvised", "fact.aed.remainConnected"),
    ]
    blocks = [
        block("M6-B1", "Adult AED application — steps 1–10", "1. Keep compressions going as the AED arrives. 2. Open the case. 3. Switch on the AED. 4. Expose the chest. 5. Make the chest and surroundings ready for safe pad contact. 6. Open the pads and follow their pictures. 7. Place the right pad below the right collarbone. 8. Place the left pad below and left of the left nipple. 9. Plug in the connector if it is not pre-connected. 10. Stop contact only when the AED announces analysis, spread your arms and state ‘Stay Clear’.", "fact.aed.applyDuringCpr", "fact.aed.padPlacementAdult", "fact.aed.analysisNoTouch", "fact.aed.chestPrepJewellery", "fact.aed.hazards"),
        block("M6-B2", "Eleven AED learning states", "The academy uses eleven project-authored states to rehearse the sourced flow: Awaiting AED; Power On; Prepare Chest; Apply Right Pad; Apply Left Pad; Connect Pads; Analyse — Clear; Charge — Clear; Clear Check and Shock; No Shock Advised; Resume CPR. These labels organise interaction and do not alter the AED's own prompts.", "fact.aed.applyDuringCpr", "fact.aed.padPlacementAdult", "fact.aed.analysisNoTouch", "fact.aed.shockDelivery", "fact.aed.noShockAdvised", "fact.aed.resumeAfterShock", kind="callout"),
        block("M6-B3", "Adult pad placement", "Place the right pad on the right chest just below the collarbone and the left pad below and to the left of the left nipple. Follow the pictures printed on the pads and connect the lead when the model requires it.", "fact.aed.padPlacementAdult"),
        block("M6-B4", "Analysis means nobody touches", "When the AED announces analysis, stop compressions. Nobody touches the casualty. Spread both arms and clearly state ‘Stay Clear’.", "fact.aed.analysisNoTouch", kind="callout"),
        block("M6-B5", "Charge, clear-check and shock", "For a shockable rhythm the AED charges itself. Keep everyone clear. When the AED prompts for a shock, say ‘Stay Clear’, visually confirm that nobody is touching the casualty, then press the shock button firmly.", "fact.aed.shockDelivery", kind="callout"),
        block("M6-B6", "Resume after a shock", "Restart chest compressions immediately after the shock and continue until the AED announces its next analysis. Current guidance states that re-analysis repeats every two minutes.", "fact.aed.resumeAfterShock"),
        block("M6-B7", "Resume after no-shock advice", "If the AED advises no shock, restart continuous compressions immediately. Continue until the emergency team takes over, the AED directs that nobody touch the casualty, or the casualty resumes normal breathing.", "fact.aed.noShockAdvised"),
        block("M6-B8", "Keep the AED connected", "Leave the AED switched on and connected throughout, including after normal breathing returns and during transport.", "fact.aed.remainConnected"),
        block("M6-B9", "Guideline update: two-minute re-analysis", "The 2018 flow showed repeat analysis without naming the interval. Current supplied guidance makes the two-minute re-analysis cycle explicit.", "fact.aed.resumeAfterShock", kind="callout"),
        block("M6-B10", "Never shock while anyone is touching", "Contact during analysis, charging or shock is a critical safety error. Before choosing the simulated shock action, state the clear command, spread both arms and visually confirm that nobody is touching the casualty. The interaction implementation must fail closed unless that clear check is satisfied.", "fact.aed.analysisNoTouch", "fact.aed.shockDelivery", kind="callout"),
    ]
    activities = [
        activity("M6-A1", "Pad-placement laboratory", "aedPadPlacement", "Apply right then left adult pads to the labelled training model, connect if prompted and keep compressions interrupted only when the AED begins analysis.", "fact.aed.padPlacementAdult", "fact.aed.applyDuringCpr", "fact.aed.analysisNoTouch"),
        activity("M6-A2", "Clear-check rehearsal", "aedClearCheck", "State ‘Stay Clear’, scan the clear zone and proceed only when nobody is touching during analysis, charging or shock.", "fact.aed.analysisNoTouch", "fact.aed.shockDelivery"),
    ]
    return module("M6", "AED Pads & Defibrillation", "Adult pad placement, a ten-step application flow, eleven practice states and strict clear checks.", 6, objectives, blocks, activities)


def build_m7() -> dict[str, Any]:
    objectives = [
        objective("M7-O1", "Resolve ten short environmental and equipment variations without changing the core clinical rules.", "fact.drsabc.danger", "fact.aed.hazards", "fact.specialsettings.environments"),
        objective("M7-O2", "Protect compression continuity while adapting AED preparation and retrieval.", "fact.compression.minimiseInterruptions", "fact.aed.retrievalSafety"),
    ]
    drill_specs = [
        ("M7-B1", "Drill 1 — unsafe location", "Identify traffic, fire, a wet floor or falling objects. Move the casualty only when the found location is unsafe or unsuitable, then use a safe, flat, open space.", ("fact.drsabc.danger",)),
        ("M7-B2", "Drill 2 — remote area without phone access", "Use the documented remote exception: assess responsiveness and breathing, start compressions when normal breathing is absent, continue for at least two minutes, then leave to seek help.", ("fact.drsabc.remoteAreaException",)),
        ("M7-B3", "Drill 3 — metal surface", "Move the casualty away from metal contact before AED use because the surface can conduct current towards the rescuer.", ("fact.aed.hazards",)),
        ("M7-B4", "Drill 4 — wet chest or surface", "Move away from the wet surface and wipe the chest dry quickly so the pads can adhere.", ("fact.aed.hazards", "fact.aed.chestPrepWet")),
        ("M7-B5", "Drill 5 — flammable gas or oxygen source", "Move the casualty away from flammable gases or oxygen sources before applying the AED.", ("fact.aed.hazards",)),
        ("M7-B6", "Drill 6 — hair prevents contact", "Shave only the pad sites promptly when chest hair prevents secure adhesion.", ("fact.aed.chestPrepHairyChest",)),
        ("M7-B7", "Drill 7 — jewellery, patches and implanted device", "Move metallic chains away, remove medication patches or monitoring electrodes, and keep the pads at least four fingers' breadth from a visible implanted device.", ("fact.aed.chestPrepJewellery", "fact.aed.chestPrepPatches", "fact.aed.chestPrepImplantedDevices")),
        ("M7-B8", "Drill 8 — break-glass AED cabinet", "Use a phone, shoe, keys or another object rather than bare hands or elbows, and clear glass from the edge before reaching for the key.", ("fact.aed.retrievalSafety",)),
        ("M7-B9", "Drill 9 — trolley bed and team", "Use a step stool on a trolley bed so elbows can remain straight. With two or more rescuers, divide compressions, 995 activation and AED tasks; allocate ventilations only within the trained, able and willing pathway.", ("fact.specialsettings.environments", "fact.ventilation.thirtyToTwoIfTrained")),
        ("M7-B10", "Drill 10 — narrow space or aircraft", "In a narrow space, the sourced alternative is compressing from above the casualty's head. On an aircraft, kneel in the seat leg space unless the casualty can be moved quickly to the galley.", ("fact.specialsettings.environments",)),
    ]
    blocks = [block(identifier, title, body, *facts, kind="callout") for identifier, title, body, facts in drill_specs]
    activities = [
        activity(
            f"M7-A{index}",
            title,
            "specialCircumstanceDrill",
            body,
            *facts,
        )
        for index, (_, title, body, facts) in enumerate(drill_specs, start=1)
    ]
    return module("M7", "Special Circumstances", "Ten short, source-backed drills that preserve the adult response rules.", 7, objectives, blocks, activities)


def build_m8() -> dict[str, Any]:
    objectives = [
        objective("M8-O1", "Integrate scene safety, recognition, simulated activation, CPR and AED actions across four settings.", "fact.drsabc.danger", "fact.drsabc.mnemonic", "fact.compression.site", "fact.aed.applyDuringCpr"),
        objective("M8-O2", "Respond correctly to shock and no-shock outcomes without allowing randomisation to alter a clinical rule.", "fact.aed.practiceScenarios", "fact.aed.resumeAfterShock", "fact.aed.noShockAdvised"),
        objective("M8-O3", "Avoid the source-grounded critical errors and review feedback by scoring category.", "fact.drsabc.getAed", "fact.aed.analysisNoTouch", "fact.aed.shockDelivery"),
    ]
    blocks = [
        block("M8-B1", "Four integrated settings", "Scenario A takes place at Home, B in a Shopping centre, C in a Workplace and D in a Community facility. The setting and availability cues vary; DRSABC, CPR, AED and clear-check rules do not.", "fact.drsabc.mnemonic", "fact.aed.applyDuringCpr", "fact.aed.analysisNoTouch", "fact.aed.shockDelivery"),
        block("M8-B2", "Approved outcome pools", "Each run chooses one source-backed three-analysis pattern: Shock–No Shock–No Shock; No Shock–Shock–No Shock; Shock–Shock–No Shock; No Shock–No Shock–Shock; or No Shock–No Shock–No Shock.", "fact.aed.practiceScenarios"),
        block("M8-B3", "Randomisation boundary", "Randomisation selects only the AED outcome pattern and narrative conditions. It never changes the need to assess danger, activate help, respond to abnormal breathing, minimise compression pauses, keep everyone clear, or resume CPR when prompted.", "fact.drsabc.danger", "fact.drsabc.call995", "fact.recognition.gaspingAbnormal", "fact.compression.minimiseInterruptions", "fact.aed.analysisNoTouch", "fact.aed.resumeAfterShock", "fact.aed.noShockAdvised", kind="callout"),
        block("M8-B4", "Scenario A — Home", "Rehearse a home arrest with variable bystander availability, AED distance and breathing presentation. A lone rescuer stays with the casualty; an available bystander may be sent for a nearby AED.", "fact.drsabc.getAed", "fact.drsabc.breathingCheck"),
        block("M8-B5", "Scenario B — Shopping centre", "Coordinate a simulated 995 call, an available bystander and a public-access AED while preserving continuous compressions and safe AED analysis.", "fact.drsabc.call995", "fact.aed.bringToEveryArrest", "fact.compression.minimiseInterruptions", "fact.aed.analysisNoTouch"),
        block("M8-B6", "Scenario C — Workplace", "Use the in-facility emergency response option, allocate responder tasks and continue the same recognition, compression and AED sequence.", "fact.drsabc.call995", "fact.specialsettings.environments", "fact.drsabc.mnemonic"),
        block("M8-B7", "Scenario D — Community facility", "Resolve an initial safety condition, choose the correct breathing branch and use the AED result pool without changing the clear and restart rules.", "fact.drsabc.danger", "fact.drsabc.monitorIfBreathingNormally", "fact.aed.shockDelivery", "fact.aed.resumeAfterShock", "fact.aed.noShockAdvised"),
        block("M8-B8", "Depth remains outside scoring", "The scenario definitions limit eligible CPR scoring to sequence, supported hand-placement, rhythm, interruption and posture signals. Scenario views and hand-derived scoring remain implementation work. Physical compression depth and force stay ‘Not physically assessed’ without a verified external sensor.", "fact.compression.depthAdult", kind="callout"),
    ]
    activities = [
        activity("M8-A1", "Scenario A — Home", "integratedScenario", "Complete the Home definition from scenarios_v1.json.", "fact.aed.practiceScenarios", "fact.drsabc.mnemonic"),
        activity("M8-A2", "Scenario B — Shopping centre", "integratedScenario", "Complete the Shopping centre definition from scenarios_v1.json.", "fact.aed.practiceScenarios", "fact.drsabc.mnemonic"),
        activity("M8-A3", "Scenario C — Workplace", "integratedScenario", "Complete the Workplace definition from scenarios_v1.json.", "fact.aed.practiceScenarios", "fact.drsabc.mnemonic"),
        activity("M8-A4", "Scenario D — Community facility", "integratedScenario", "Complete the Community facility definition from scenarios_v1.json.", "fact.aed.practiceScenarios", "fact.drsabc.mnemonic"),
    ]
    return module("M8", "Integrated Scenarios A–D", "Four settings, fixed clinical rules and source-backed shock/no-shock pools.", 8, objectives, blocks, activities)


def build_m9() -> dict[str, Any]:
    objectives = [
        objective("M9-O1", "Recognise that paediatric arrest and AED use differ from the adult core without inferring a technique beyond the supplied extract.", "fact.child.aetiology", "fact.child.earlyAedAdvocated"),
        objective("M9-O2", "Review the source-checked child pad-contact facts and identify the age-versus-weight questions awaiting SME approval.", "fact.child.adultPadsOnChild", "fact.child.padSeparation", "fact.child.doseAttenuation", "fact.child.padWeightRule"),
        objective("M9-O3", "Keep infant and paediatric compression details locked as awareness-only material until instructor and clinical approval requirements are met.", "fact.child.infantDefibrillation", "fact.child.compressionValues", "fact.child.infantCompressionMethod", "fact.child.infantResponseCheck", "fact.child.hcpRatios"),
    ]
    blocks = [
        block("M9-B1", "LOCKED — awareness only", "This module requires completion of Modules 0–8, qualified instructor approval and a clinically approved course lifecycle. It is not paediatric certification, contains no scored assessment and must not be used to infer technique beyond the cited extract.", kind="callout", review_status="clinicalReviewRequired", policy_section="Module 9 access and review gating"),
        block("M9-B2", "Why paediatric arrest may differ", "The 2022 manual states that paediatric out-of-hospital arrest is usually non-cardiac and most cases begin with a non-shockable rhythm, so ventilation and oxygenation are important. It also reports shockable initial rhythms in about 5–19% of cases, particularly among school-age children and adolescents.", "fact.child.aetiology"),
        block("M9-B3", "Early AED awareness", "The supplied 2022 manual states that ILCOR supports early AED use for a child in cardiac arrest. It reports higher survival among children with shockable rhythms treated early than among children presenting with other rhythms.", "fact.child.earlyAedAdvocated"),
        block(
            "M9-B4",
            "Child pad system — SME decision required",
            "The 2022 manual uses an age-based 1–12-year paediatric dose-attenuation rule, while the 2021 summary uses a body-weight threshold below 25 kg. A qualified SME must set one canonical learner-facing rule before this content can be approved.",
            "fact.child.doseAttenuation",
            "fact.child.padWeightRule",
            kind="callout",
            additional_references=[
                supplemental_source_reference(
                    "M9-B4", "difference-s1", document="Docs/COURSE_SOURCE_DIFFERENCES.md", edition="Draft 2026-08-07", section="3 — S1", page="n/a (Markdown)", review_status="requires_sme_review"
                )
            ],
        ),
        block(
            "M9-B5",
            "Infant defibrillation — SME decision required",
            "The 2021 summary prefers a manual defibrillator for an infant and child pads when that is unavailable. The supplied sources do not clearly authorise adult pads on an infant, so the app gives no such instruction pending SME approval.",
            "fact.child.infantDefibrillation",
            kind="callout",
            additional_references=[
                supplemental_source_reference(
                    "M9-B5", "difference-s2", document="Docs/COURSE_SOURCE_DIFFERENCES.md", edition="Draft 2026-08-07", section="3 — S2", page="n/a (Markdown)", review_status="requires_sme_review"
                )
            ],
        ),
        block("M9-B6", "Adult pads on a child", "For a child, the 2022 manual permits an AED with adult pads when no paediatric system is available. Pads must not touch or overlap; with adult pads, use front-and-back placement with one pad on the central sternum and one on the upper back between the shoulder blades.", "fact.child.adultPadsOnChild"),
        block("M9-B7", "Paediatric pad separation", "For front-of-chest paediatric pad placement, follow the pad pictures and keep the pads from touching or overlapping, with at least 2 cm between them.", "fact.child.padSeparation"),
        block(
            "M9-B8",
            "Compression values and methods — SME review",
            "The supplied 2021 summary contains child and infant depth, landmark, method and full-recoil details, but neither provider manual teaches the paediatric technique. Lifesaver Vision keeps these items at awareness level and does not release technique coaching until SME approval.",
            "fact.child.compressionValues",
            "fact.child.infantCompressionMethod",
            kind="callout",
            additional_references=[
                supplemental_source_reference(
                    "M9-B8", "difference-s4", document="Docs/COURSE_SOURCE_DIFFERENCES.md", edition="Draft 2026-08-07", section="3 — S4", page="n/a (Markdown)", review_status="requires_sme_review"
                )
            ],
        ),
        block(
            "M9-B9",
            "Infant response and HCP ratios — SME review",
            "The 2021 summary alone supplies the infant response check and child/infant HCP ratios, including its pulse threshold. They remain review-required and unscored; the app does not infer additional steps.",
            "fact.child.infantResponseCheck",
            "fact.child.hcpRatios",
            kind="callout",
            additional_references=[
                supplemental_source_reference(
                    "M9-B9", "difference-s3-s4", document="Docs/COURSE_SOURCE_DIFFERENCES.md", edition="Draft 2026-08-07", section="3 — S3 and S4", page="n/a (Markdown)", review_status="requires_sme_review"
                )
            ],
        ),
        block(
            "M9-B10",
            "Guideline update: paediatric rules changed",
            "The supplied editions differ on paediatric age, weight, pad spacing and front-and-back placement conditions. The course shows the conflict for instructor review and withholds a single learner-facing rule until a qualified SME signs off.",
            "fact.child.doseAttenuation",
            "fact.child.padWeightRule",
            "fact.child.infantDefibrillation",
            "fact.child.adultPadsOnChild",
            "fact.child.padSeparation",
            kind="callout",
            additional_references=[
                supplemental_source_reference(
                    "M9-B10", "difference-s1-s4", document="Docs/COURSE_SOURCE_DIFFERENCES.md", edition="Draft 2026-08-07", section="3 — S1 to S4", page="n/a (Markdown)", review_status="requires_sme_review"
                )
            ],
        ),
    ]
    activities = [
        activity("M9-A1", "Unscored paediatric awareness review", "awarenessAssessment", "Review six untimed awareness questions. No result contributes to course scoring or practical competency.", "fact.child.aetiology", "fact.child.earlyAedAdvocated", "fact.child.adultPadsOnChild", "fact.child.padSeparation"),
    ]
    access = {
        "requiredCompletedModuleIDs": [f"M{index}" for index in range(0, 9)],
        "requiresInstructorApproval": True,
        "requiresClinicallyApprovedContent": True,
    }
    return module("M9", "Child & Infant AED Awareness", "Locked, unscored awareness content with explicit paediatric evidence gaps.", 9, objectives, blocks, activities, review_status="clinicalReviewRequired", access_requirements=access)


def build_m10() -> dict[str, Any]:
    objectives = [
        objective("M10-O1", "Give paramedics a concise source-backed handover and keep the AED connected.", "fact.postincident.handoverSummary", "fact.postincident.assistUntilLoaded", "fact.aed.remainConnected"),
        objective("M10-O2", "Use the current post-ROSC position and monitoring instruction rather than the 2018 recovery-position step.", "fact.recovery.noRecoveryPositionAfterRosc", "fact.recovery.supineMonitor"),
        objective("M10-O3", "Complete a structured after-action reflection and request appropriate instructor follow-up.", policy_section="Post-incident authoring boundaries"),
    ]
    blocks = [
        block("M10-B1", "Handover essentials", "Tell paramedics the best-estimate collapse time, whether an AED was used, how many shocks were delivered, any known medical history and medication, and whether a written event record is available.", "fact.postincident.handoverSummary"),
        block("M10-B2", "Assist and leave the AED connected", "Continue assisting until the casualty is loaded into the ambulance. Keep the AED switched on, with pads and cable attached, during transport.", "fact.postincident.assistUntilLoaded", "fact.aed.remainConnected"),
        block("M10-B3", "After normal breathing returns", "Keep the casualty lying on their back and monitor continuously until help arrives. Leave the AED pads connected.", "fact.recovery.supineMonitor"),
        block(
            "M10-B4",
            "Guideline update: no recovery position in this flow",
            "Current guidance no longer recommends the recovery position after cardiac arrest because it may conceal a re-arrest. Keep the casualty supine, monitor continuously and leave the AED attached. Recovery-position technique is outside this course flow.",
            "fact.recovery.noRecoveryPositionAfterRosc",
            "fact.recovery.supineMonitor",
            kind="callout",
            additional_references=[
                supplemental_source_reference(
                    "M10-B4", "m18-technique", document="SRFAC-CPRHOAED-Manual-2018-2.pdf", edition="2018", section="B-4", page="20–21"
                ),
                supplemental_source_reference(
                    "M10-B4", "m18-post-rosc", document="SRFAC-CPRHOAED-Manual-2018-2.pdf", edition="2018", section="C-5 step 7", page="30"
                ),
            ],
        ),
        block("M10-B5", "AED owner follow-up", "Notify the facility or safety manager. The owner or vendor replaces used consumables, checks the battery, repairs the cabinet where needed and can retrieve the AED event record for audit.", "fact.postincident.aedOwnerDuties"),
        block(
            "M10-B5A",
            "Operational update: battery cadence needs local confirmation",
            "The 2018 and 2022 manuals state different battery-check cadences. This course does not set one local operating schedule until the responsible site and a qualified reviewer confirm the applicable vendor and organisational requirement.",
            "fact.postincident.aedOwnerDuties",
            kind="callout",
            review_status="clinicalReviewRequired",
            additional_references=[
                supplemental_source_reference(
                    "M10-B5A", "difference-s10", document="Docs/COURSE_SOURCE_DIFFERENCES.md", edition="Draft 2026-08-07", section="3 — S10", page="n/a (Markdown)", review_status="requires_sme_review"
                )
            ],
        ),
        block("M10-B6", "Emotional decompression — review required", "Pause after the simulation, leave immersion if needed and choose whether to speak with an instructor or use the organisation's support route. The extract contains no clinical decompression protocol, so this supportive product flow needs qualified review before release as formal guidance.", kind="callout", missing_topic="emotional decompression protocol"),
        block("M10-B7", "Refresher recommendation — review required", "Use practice history and instructor feedback to plan another learning session. Lifesaver Vision does not prescribe a clinical refresher interval because the approved extract contains none; a qualified reviewer must approve any future cadence.", kind="callout", missing_topic="refresher interval or recommendation"),
        block("M10-B8", "Structured after-action review", "Record what you noticed first, which actions you took in sequence, where interruptions occurred, what feedback was most useful and what you want to rehearse next. Bring questions or a practical-assessment request to an instructor; this reflection is not a clinical grade.", policy_section="Post-incident authoring boundaries"),
        block("M10-B9", "Internal completion record", "Finishing the learning path records internal completion only. Practical competency still requires instructor sign-off and does not represent SRFAC certification.", kind="callout", policy_section="Simulation and completion boundaries"),
    ]
    activities = [
        activity("M10-A1", "Handover rehearsal", "handoverDialogue", "Deliver the five source-backed handover items, then confirm that the AED remains connected while the casualty is loaded.", "fact.postincident.handoverSummary", "fact.postincident.assistUntilLoaded", "fact.aed.remainConnected"),
        activity("M10-A2", "After-action review", "structuredReflection", "Complete the five reflection prompts and note whether you want to ask an instructor for feedback or a practical assessment.", policy_section="Post-incident authoring boundaries"),
    ]
    return module("M10", "Post-incident Handover & Reflection", "Handover, current post-ROSC care, AED continuity and carefully bounded reflection.", 10, objectives, blocks, activities)


def attach_question_bank(modules: list[dict[str, Any]]) -> None:
    question_document = load_json(QUESTIONS_PATH)
    if question_document["contentVersion"] != CONTENT_VERSION:
        raise ValueError("Question-bank content version does not match the course")
    sets = {item["moduleID"]: item for item in question_document["moduleQuestionSets"]}
    for course_module in modules:
        question_set = sets.get(course_module["id"])
        if question_set is None:
            raise ValueError(f"Missing question set for {course_module['id']}")
        assessment = {
            "id": question_set["assessmentID"],
            "title": question_set["title"],
            "isScored": question_set["isScored"],
            "passingScore": question_set["passingScore"],
            "questions": question_set["questions"],
            "sourceReferences": unique_references(question_set["questions"]),
        }
        course_module["lessons"][0]["assessments"] = [assessment]


def attach_scenarios(modules: list[dict[str, Any]]) -> None:
    scenario_document = load_json(SCENARIOS_PATH)
    if scenario_document["contentVersion"] != CONTENT_VERSION:
        raise ValueError("Scenario content version does not match the course")
    m8 = next(item for item in modules if item["id"] == "M8")
    embedded: list[dict[str, Any]] = []
    for definition in scenario_document["scenarios"]:
        actions = [
            {
                "id": action["id"],
                "title": action["title"],
                "actionDescription": action["actionDescription"],
                "isRequired": action["isRequired"],
                "sourceReferences": action["sourceReferences"],
            }
            for action in definition["criticalActions"]
        ]
        embedded.append(
            {
                "id": definition["id"],
                "title": definition["title"],
                "summary": definition["summary"],
                "criticalActions": actions,
                "sourceReferences": definition["sourceReferences"],
            }
        )
    m8["lessons"][0]["scenarios"] = embedded


def build_course() -> dict[str, Any]:
    modules = [
        build_m0(),
        build_m1(),
        build_m2(),
        build_m3(),
        build_m4(),
        build_m5(),
        build_m6(),
        build_m7(),
        build_m8(),
        build_m9(),
        build_m10(),
    ]
    attach_question_bank(modules)
    attach_scenarios(modules)
    required_lessons = [module_item["lessons"][0]["id"] for module_item in modules if module_item["id"] != "M9"]
    course = {
        "id": "lifesaver-vision-cpr-aed-spatial-academy",
        "title": "Lifesaver Vision: CPR + AED Spatial Academy",
        "summary": "A calm, source-traceable adult hands-only CPR and AED academy with spatial learning, integrated simulation and instructor-reviewed practical competency.",
        "version": {
            "schemaVersion": 1,
            "contentVersion": CONTENT_VERSION,
            "locale": "en-SG",
            "releasedAt": None,
        },
        "modules": modules,
        "instructorRequirement": {
            "isRequired": True,
            "requirementDescription": "Practical competency requires a qualified instructor's recorded sign-off.",
            "recordLabel": "Internal completion record",
        },
        "completionRule": {
            "requiredLessonIDs": required_lessons,
            "minimumAssessmentScore": 0.8,
            "requiresInstructorSignOff": True,
        },
        "sourceReferences": [
            policy_reference("course", "Orientation content requirements; Simulation and completion boundaries; Medical and sensing boundaries"),
            *fact_references("course-ground-truth", "fact.drsabc.mnemonic", "fact.compression.rate", "fact.aed.purpose"),
        ],
    }
    return course


def main() -> None:
    course = build_course()
    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    with OUTPUT_PATH.open("w", encoding="utf-8") as handle:
        json.dump(course, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    print(
        f"Wrote {OUTPUT_PATH.relative_to(ROOT)}: "
        f"{len(course['modules'])} modules, "
        f"{sum(len(module_item['lessons'][0]['contentBlocks']) for module_item in course['modules'])} content blocks"
    )


if __name__ == "__main__":
    main()
