#!/usr/bin/env python3
"""Validate Phase 3B content and generate its clinical traceability documents."""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parents[1]
COURSE_PATH = ROOT / "Resources" / "Courses" / "course_v1.json"
QUESTIONS_PATH = ROOT / "Resources" / "Questions" / "theory_questions_v1.json"
SCENARIOS_PATH = ROOT / "Resources" / "Courses" / "scenarios_v1.json"
FACTS_PATH = ROOT / "Docs" / "CLINICAL_FACTS_EXTRACT.json"
MATRIX_PATH = ROOT / "Docs" / "COURSE_TRACEABILITY_MATRIX.md"
REVIEW_PATH = ROOT / "Docs" / "MEDICAL_REVIEW_REQUIRED.md"
CHECKLIST_PATH = ROOT / "Docs" / "CLINICAL_APPROVAL_CHECKLIST.md"

ALLOWED_SCORED_STATUSES = {"source_checked", "clinically_approved"}
EXPECTED_MODULE_IDS = [f"M{index}" for index in range(11)]
EXPECTED_PATTERNS = {
    "S-N-N": ["shock", "noShock", "noShock"],
    "N-S-N": ["noShock", "shock", "noShock"],
    "S-S-N": ["shock", "shock", "noShock"],
    "N-N-S": ["noShock", "noShock", "shock"],
    "N-N-N": ["noShock", "noShock", "noShock"],
}


@dataclass(frozen=True)
class TraceRow:
    kind: str
    identifier: str
    scope: str
    scored: str
    review_status: str
    text: str
    references: tuple[dict[str, Any], ...]


def load_json(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def normalise_page(value: Any) -> str:
    return str(value)


def validate_reference(
    reference: dict[str, Any],
    *,
    item_id: str,
    content_version: str,
    facts: dict[str, dict[str, Any]],
    scored: bool,
) -> None:
    for key in (
        "id",
        "document",
        "edition",
        "section",
        "page",
        "reviewStatus",
        "contentVersion",
    ):
        require(key in reference, f"{item_id}: SourceReference is missing {key}")
        require(str(reference[key]).strip() != "", f"{item_id}: SourceReference {key} is empty")
    require(
        reference["contentVersion"] == content_version,
        f"{item_id}: reference {reference['id']} has mismatched contentVersion",
    )

    fact_id = reference.get("clinicalFactID")
    if scored:
        require(fact_id, f"{item_id}: scored item has a non-fact reference")
        require(
            reference["reviewStatus"] in ALLOWED_SCORED_STATUSES,
            f"{item_id}: scored reference {reference['id']} has blocked status {reference['reviewStatus']}",
        )
    if not fact_id:
        return

    require(fact_id in facts, f"{item_id}: unknown clinical fact ID {fact_id}")
    fact = facts[fact_id]
    require(
        reference["reviewStatus"] == fact["reviewStatus"],
        f"{item_id}: {fact_id} review status was changed from the extract",
    )
    source_tuple = (
        reference["document"],
        reference["edition"],
        reference["section"],
        normalise_page(reference["page"]),
    )
    approved_sources = {
        (source["doc"], source["edition"], source["section"], normalise_page(source["page"]))
        for source in fact["sources"]
    }
    require(
        source_tuple in approved_sources,
        f"{item_id}: citation does not match an extract source for {fact_id}: {source_tuple}",
    )
    if scored:
        require(
            fact["reviewStatus"] in ALLOWED_SCORED_STATUSES,
            f"{item_id}: scored item reaches blocked fact {fact_id}",
        )


def add_row(
    rows: list[TraceRow],
    *,
    kind: str,
    identifier: str,
    scope: str,
    scored: bool,
    review_status: str,
    text: str,
    references: list[dict[str, Any]],
    content_version: str,
    facts: dict[str, dict[str, Any]],
) -> None:
    require(references, f"{identifier}: unmapped {kind}")
    for reference in references:
        validate_reference(
            reference,
            item_id=identifier,
            content_version=content_version,
            facts=facts,
            scored=scored,
        )
    rows.append(
        TraceRow(
            kind=kind,
            identifier=identifier,
            scope=scope,
            scored="yes" if scored else "no",
            review_status=review_status,
            text=text,
            references=tuple(references),
        )
    )


def status_for_references(references: Iterable[dict[str, Any]]) -> str:
    statuses = {reference["reviewStatus"] for reference in references}
    if "requires_sme_review" in statuses:
        return "clinicalReviewRequired"
    if "clinically_approved" in statuses:
        return "clinicallyApproved"
    return "sourceChecked"


def review_reason_for_references(
    references: Iterable[dict[str, Any]],
    facts: dict[str, dict[str, Any]],
) -> str:
    reference_list = list(references)
    blocked_references = [
        reference
        for reference in reference_list
        if reference["reviewStatus"] == "requires_sme_review"
    ]
    reason_references = blocked_references or reference_list
    fact_ids = sorted(
        {
            reference["clinicalFactID"]
            for reference in reason_references
            if reference.get("clinicalFactID") in facts
        }
    )
    notes = list(
        dict.fromkeys(
            facts[fact_id]["notes"].strip()
            for fact_id in fact_ids
            if facts[fact_id].get("notes", "").strip()
        )
    )
    if notes:
        return " ".join(notes)
    if any(
        reference["document"] == "Docs/COURSE_SOURCE_DIFFERENCES.md"
        for reference in reason_references
    ):
        return "The cited course-source reconciliation item requires a qualified decision before release."
    return "The approved extract contains no supporting clinical fact for this requested topic, or the item is an explicit access/release gate."


def collect_course_rows(
    course: dict[str, Any],
    facts: dict[str, dict[str, Any]],
) -> tuple[list[TraceRow], list[dict[str, str]]]:
    rows: list[TraceRow] = []
    review_items: list[dict[str, str]] = []
    content_version = course["version"]["contentVersion"]
    module_ids = [module["id"] for module in course["modules"]]
    require(module_ids == EXPECTED_MODULE_IDS, f"Expected M0-M10 in order; found {module_ids}")

    for module in course["modules"]:
        module_id = module["id"]
        descendant_items = [
            item
            for lesson in module["lessons"]
            for collection in ("learningObjectives", "contentBlocks", "interactiveActivities")
            for item in lesson[collection]
        ]
        has_review_descendant = any(
            item.get("reviewStatus") == "clinicalReviewRequired"
            or any(
                reference["reviewStatus"] == "requires_sme_review"
                for reference in item["sourceReferences"]
            )
            for item in descendant_items
        )
        require(
            module.get("reviewStatus")
            == ("clinicalReviewRequired" if has_review_descendant else "sourceChecked"),
            f"{module_id}: aggregate reviewStatus does not match its descendants",
        )
        if module_id == "M9":
            require(
                module.get("accessRequirements")
                == {
                    "requiredCompletedModuleIDs": [f"M{index}" for index in range(9)],
                    "requiresInstructorApproval": True,
                    "requiresClinicallyApprovedContent": True,
                },
                "M9: access requirements do not enforce adult core, instructor and clinical approval",
            )
        if module.get("reviewStatus") == "clinicalReviewRequired":
            access = module.get("accessRequirements") or {}
            is_access_locked = bool(
                access.get("requiresInstructorApproval")
                or access.get("requiresClinicallyApprovedContent")
                or access.get("requiredCompletedModuleIDs")
            )
            blocked_references = [
                reference
                for reference in module["sourceReferences"]
                if reference["reviewStatus"] == "requires_sme_review"
            ]
            review_items.append(
                {
                    "id": module_id,
                    "title": module["title"],
                    "why": (
                        "The module contains unresolved clinical facts and remains access-locked."
                        if is_access_locked
                        else review_reason_for_references(module["sourceReferences"], facts)
                    ),
                    "approval": (
                        "Approve every cited SME item, then release a new clinically approved content version before unlocking."
                        if is_access_locked
                        else "Approve, revise or remove each review-required descendant before clinical release. Module access is separate from this aggregate lifecycle."
                    ),
                    "sources": source_summary(blocked_references or module["sourceReferences"]),
                }
            )
        for lesson in module["lessons"]:
            add_row(
                rows,
                kind="Lesson",
                identifier=lesson["id"],
                scope=module_id,
                scored=False,
                review_status=status_for_references(lesson["sourceReferences"]),
                text=f"{lesson['title']}: {lesson['summary']}",
                references=lesson["sourceReferences"],
                content_version=content_version,
                facts=facts,
            )
            for item in lesson["learningObjectives"]:
                add_row(
                    rows,
                    kind="Learning objective",
                    identifier=item["id"],
                    scope=module_id,
                    scored=False,
                    review_status=status_for_references(item["sourceReferences"]),
                    text=item["statement"],
                    references=item["sourceReferences"],
                    content_version=content_version,
                    facts=facts,
                )
            for item in lesson["contentBlocks"]:
                add_row(
                    rows,
                    kind="Content block",
                    identifier=item["id"],
                    scope=module_id,
                    scored=False,
                    review_status=item["reviewStatus"],
                    text=f"{item['title']}: {item['body']}",
                    references=item["sourceReferences"],
                    content_version=content_version,
                    facts=facts,
                )
                has_blocked_reference = any(
                    reference["reviewStatus"] == "requires_sme_review"
                    for reference in item["sourceReferences"]
                )
                if has_blocked_reference:
                    require(
                        item["reviewStatus"] == "clinicalReviewRequired",
                        f"{item['id']}: blocked fact is not marked clinicalReviewRequired",
                    )
                if item["reviewStatus"] == "clinicalReviewRequired":
                    review_items.append(
                        {
                            "id": item["id"],
                            "title": item["title"],
                            "why": review_reason_for_references(item["sourceReferences"], facts),
                            "approval": "A qualified SRFAC instructor or clinical SME must approve, revise or reject the learner-facing wording.",
                            "sources": source_summary(item["sourceReferences"]),
                        }
                    )
            for item in lesson["interactiveActivities"]:
                add_row(
                    rows,
                    kind="Interactive activity",
                    identifier=item["id"],
                    scope=module_id,
                    scored=False,
                    review_status=status_for_references(item["sourceReferences"]),
                    text=f"{item['title']}: {item['instructions']}",
                    references=item["sourceReferences"],
                    content_version=content_version,
                    facts=facts,
                )
    return rows, review_items


def collect_question_rows(
    course: dict[str, Any],
    question_bank: dict[str, Any],
    facts: dict[str, dict[str, Any]],
) -> list[TraceRow]:
    rows: list[TraceRow] = []
    version = course["version"]["contentVersion"]
    require(question_bank["courseID"] == course["id"], "Question-bank course ID mismatch")
    require(question_bank["contentVersion"] == version, "Question-bank content version mismatch")
    sets = question_bank["moduleQuestionSets"]
    require([item["moduleID"] for item in sets] == EXPECTED_MODULE_IDS, "Question bank must contain M0-M10 in order")

    embedded_by_module: dict[str, dict[str, Any]] = {}
    for module in course["modules"]:
        assessments = module["lessons"][0]["assessments"]
        require(len(assessments) == 1, f"{module['id']}: expected one assessment")
        embedded_by_module[module["id"]] = assessments[0]

    for question_set in sets:
        module_id = question_set["moduleID"]
        questions = question_set["questions"]
        require(len(questions) >= 6, f"{module_id}: fewer than six questions")
        require(
            question_set["isScored"] == (module_id not in {"M0", "M9"}),
            f"{module_id}: unexpected scored/unscored setting",
        )
        embedded = embedded_by_module[module_id]
        require(embedded["id"] == question_set["assessmentID"], f"{module_id}: assessment ID mismatch")
        require(embedded["isScored"] == question_set["isScored"], f"{module_id}: embedded score flag mismatch")
        require(embedded["questions"] == questions, f"{module_id}: embedded questions differ from question bank")
        for question in questions:
            scored = question_set["isScored"]
            references = question["sourceReferences"]
            fact_ids = {reference.get("clinicalFactID") for reference in references}
            require(None not in fact_ids and "" not in fact_ids, f"{question['id']}: answer has no fact ID")
            add_row(
                rows,
                kind="Quiz question",
                identifier=question["id"],
                scope=module_id,
                scored=scored,
                review_status=status_for_references(references),
                text=question["prompt"],
                references=references,
                content_version=version,
                facts=facts,
            )
            add_row(
                rows,
                kind="Quiz feedback",
                identifier=f"{question['id']}-feedback",
                scope=module_id,
                scored=scored,
                review_status=status_for_references(references),
                text=question["explanation"],
                references=references,
                content_version=version,
                facts=facts,
            )
    return rows


def collect_scenario_rows(
    course: dict[str, Any],
    scenarios: dict[str, Any],
    facts: dict[str, dict[str, Any]],
) -> list[TraceRow]:
    rows: list[TraceRow] = []
    version = course["version"]["contentVersion"]
    require(scenarios["courseID"] == course["id"], "Scenario course ID mismatch")
    require(scenarios["contentVersion"] == version, "Scenario content version mismatch")
    require(len(scenarios["aedStateMachine"]["states"]) == 11, "AED state machine must have exactly 11 states")
    pattern_map = {
        pattern["id"]: pattern["analysisOutcomes"] for pattern in scenarios["shockPatterns"]
    }
    require(pattern_map == EXPECTED_PATTERNS, f"Unexpected shock-pattern pool: {pattern_map}")
    scenario_ids = [item["id"] for item in scenarios["scenarios"]]
    require(
        scenario_ids
        == [
            "scenario-a-home",
            "scenario-b-shopping-centre",
            "scenario-c-workplace",
            "scenario-d-community-facility",
        ],
        "Expected scenarios A-D",
    )

    def add_scenario_row(
        kind: str,
        item: dict[str, Any],
        scope: str,
        text: str,
        *,
        scored: bool,
    ) -> None:
        references = item["sourceReferences"]
        add_row(
            rows,
            kind=kind,
            identifier=item["id"],
            scope=scope,
            scored=scored,
            review_status=status_for_references(references),
            text=text,
            references=references,
            content_version=version,
            facts=facts,
        )

    state_machine = scenarios["aedStateMachine"]
    add_row(
        rows,
        kind="AED state machine",
        identifier="aed-state-machine-v1",
        scope="AED state machine",
        scored=False,
        review_status=status_for_references(state_machine["sourceReferences"]),
        text=f"Initial state: {state_machine['initialStateID']}",
        references=state_machine["sourceReferences"],
        content_version=version,
        facts=facts,
    )
    for state in state_machine["states"]:
        add_scenario_row("AED state", state, "AED state machine", f"{state['title']}: {state['stateDescription']}", scored=False)
    for transition in state_machine["transitions"]:
        condition = transition.get("condition") or "no additional condition"
        add_scenario_row(
            "AED transition",
            transition,
            transition["fromStateID"],
            f"{transition['trigger']}: {condition} → {transition['toStateID']}",
            scored=False,
        )
        for feedback in transition["feedbackStatements"]:
            add_scenario_row("AED feedback", feedback, transition["id"], feedback["statement"], scored=False)
    for pattern in scenarios["shockPatterns"]:
        add_scenario_row("Shock pattern", pattern, "Scenario pool", " → ".join(pattern["analysisOutcomes"]), scored=False)

    embedded_scenarios = {
        item["id"]: item
        for item in next(module for module in course["modules"] if module["id"] == "M8")["lessons"][0]["scenarios"]
    }
    for scenario in scenarios["scenarios"]:
        scenario_id = scenario["id"]
        require(scenario["randomisation"]["clinicalRulesInvariant"] is True, f"{scenario_id}: rules must be invariant")
        require(
            set(scenario["randomisation"]["shockPatternIDs"]) == set(EXPECTED_PATTERNS),
            f"{scenario_id}: must use only and all approved pools",
        )
        add_scenario_row("Scenario", scenario, scenario_id, f"{scenario['title']}: {scenario['summary']}", scored=True)
        add_scenario_row("Scenario initial state", scenario["initialState"], scenario_id, json.dumps(scenario["initialState"]["values"], ensure_ascii=False, sort_keys=True), scored=True)
        for branch in scenario["branchingNodes"]:
            add_scenario_row("Scenario branch", branch, scenario_id, branch["prompt"], scored=True)
            for condition in branch["conditions"]:
                add_scenario_row("Scenario branch condition", condition, scenario_id, f"{condition['condition']}: {json.dumps(condition['values'], ensure_ascii=False, sort_keys=True)}", scored=True)
                for feedback in condition["feedbackStatements"]:
                    add_scenario_row("Scenario feedback", feedback, scenario_id, feedback["statement"], scored=True)
            for feedback in branch["feedbackStatements"]:
                add_scenario_row("Scenario feedback", feedback, scenario_id, feedback["statement"], scored=True)
        action_ids = {action["id"] for action in scenario["criticalActions"]}
        condition_action_ids = {
            action_id
            for branch in scenario["branchingNodes"]
            for condition in branch["conditions"]
            for action_id in condition["requiredActionIDs"]
        }
        require(
            condition_action_ids <= action_ids,
            f"{scenario_id}: a branch requires an unknown CriticalAction",
        )
        mapping = {item["itemID"]: item["category"] for item in scenario["scoringCategoryMapping"]}
        require(set(mapping) == action_ids | {error["id"] for error in scenario["criticalErrors"]}, f"{scenario_id}: scoring map does not cover every action/error")
        require(len(action_ids) == len(scenario["criticalActions"]), f"{scenario_id}: duplicate critical action ID")
        for action in scenario["criticalActions"]:
            require(
                action["isRequired"] is True or action["id"] in condition_action_ids,
                f"{action['id']}: CriticalAction is neither globally nor conditionally required",
            )
            require(mapping[action["id"]] == action["scoringCategory"], f"{action['id']}: scoring mapping mismatch")
            add_scenario_row("Scenario action", action, scenario_id, f"{action['title']}: {action['actionDescription']}", scored=True)
            for feedback in action["feedbackStatements"]:
                add_scenario_row("Scenario feedback", feedback, scenario_id, feedback["statement"], scored=True)
        for error in scenario["criticalErrors"]:
            require(mapping[error["id"]] == error["scoringCategory"], f"{error['id']}: scoring mapping mismatch")
            add_scenario_row("Critical error", error, scenario_id, f"{error['title']}: {error['errorDescription']} Remediation: {error['remediation']}", scored=True)
            for feedback in error["feedbackStatements"]:
                add_scenario_row("Scenario feedback", feedback, scenario_id, feedback["statement"], scored=True)
        for feedback in scenario["feedbackStatements"]:
            add_scenario_row("Scenario feedback", feedback, scenario_id, feedback["statement"], scored=True)

        embedded = embedded_scenarios.get(scenario_id)
        require(embedded is not None, f"{scenario_id}: missing embedded Course scenario")
        require(
            {item["id"] for item in embedded["criticalActions"]} == action_ids,
            f"{scenario_id}: embedded action IDs differ from scenarios_v1.json",
        )
    return rows


def source_summary(references: Iterable[dict[str, Any]]) -> str:
    seen: list[str] = []
    for reference in references:
        label = f"{reference['document']} ({reference['edition']}), p. {reference['page']}"
        if label not in seen:
            seen.append(label)
    return "; ".join(seen)


def fact_summary(references: Iterable[dict[str, Any]]) -> str:
    return ", ".join(
        sorted(
            {
                reference["clinicalFactID"]
                for reference in references
                if reference.get("clinicalFactID")
            }
        )
    ) or "non-clinical project source"


def markdown_escape(value: str) -> str:
    return " ".join(value.replace("|", "\\|").split())


def write_matrix(rows: list[TraceRow], course: dict[str, Any]) -> None:
    scored_rows = sum(row.scored == "yes" for row in rows)
    lines = [
        "# Course Traceability Matrix",
        "",
        f"Generated by `Scripts/generate_traceability_matrix.py` from versioned content JSON for `{course['title']}` v{course['version']['contentVersion']}.",
        "",
        f"Validation result: **PASS — {len(rows)} mapped items, 0 unmapped; {scored_rows} scored trace rows contain only source-checked or clinically-approved facts.**",
        "",
        "`source_checked` is preserved from the supplied extract and is not represented as SME approval. Learner-facing release still requires the course lifecycle and sign-off checklist to be completed.",
        "",
        "| Type | ID | Scope | Scored | Content state | Statement | Approved source(s) | Clinical fact ID(s) |",
        "|---|---|---|---:|---|---|---|---|",
    ]
    for row in rows:
        lines.append(
            "| "
            + " | ".join(
                markdown_escape(value)
                for value in (
                    row.kind,
                    row.identifier,
                    row.scope,
                    row.scored,
                    row.review_status,
                    row.text,
                    source_summary(row.references),
                    fact_summary(row.references),
                )
            )
            + " |"
        )
    MATRIX_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")


SME_ITEMS = [
    ("S1", "Child pad-selection rule: age versus weight", "The 2022 manual uses ages 1–12; the 2021 summary uses weight below 25 kg.", "Choose and approve one canonical learner-facing selection rule."),
    ("S2", "Infant defibrillation when only adult pads exist", "The supplied sources do not clearly authorise adult pads for an infant.", "Approve an explicit rule or confirm that the app must continue withholding one."),
    ("S3", "Child/infant HCP pulse below 60/min rule", "The rule appears only in the 2021 summary slide.", "Confirm whether it belongs in the HCP-labelled awareness scope."),
    ("S4", "Depth of paediatric awareness content", "Compression depth, ratios, methods and the infant response check are summary-slide-only.", "Approve the permitted awareness depth and exact wording."),
    ("S5", "Chain of Survival five versus seven rings", "The current 2021 and 2022 sources disagree on the graphic and ring count.", "Approve the official sequence and visual for this release."),
    ("S6", "Adult depth coaching phrasing", "SRFAC gives 4–6 cm while the reproduced RCA algorithm says approximately 5 cm, no more than 6 cm.", "Approve any future single-number coaching target; depth remains Not physically assessed."),
    ("S7", "Recovery-position demonstration scope", "Current guidance removes it from cardiac-arrest post-ROSC care but retains it in other first-aid contexts.", "Confirm that this course should continue excluding the technique demonstration."),
    ("S8", "Future FBAO/choking content", "Only a summary deck is supplied and choking is outside the current course.", "Require full guideline review before any future choking content is added."),
    ("S9", "Lay stop-CPR wording", "Older lay wording mentions pulse; current lay teaching avoids a pulse assessment.", "Approve the current wake-or-normal-breathing wording."),
    ("S10", "AED battery-check cadence", "The 2018 and 2022 manuals differ, and a local site may impose another schedule.", "Confirm the 2022/vendor wording and any site-specific operational requirement."),
    ("S11", "BVM mask and bag-volume detail", "This HCP equipment detail is outside the adult hands-only core.", "Confirm that it remains excluded or approve a separately labelled HCP lesson."),
    ("S12", "2018-themed guideline-update copy", "Visual theming must not cause older clinical values to replace current instructions.", "Approve every guideline-update card for accuracy and framing."),
]


def write_review_documents(review_items: list[dict[str, str]]) -> None:
    lines = [
        "# Medical Review Required",
        "",
        "This register is generated from the v1.0.0 content lifecycle fields and the twelve reconciliation gates in `Docs/COURSE_SOURCE_DIFFERENCES.md`. Items below are not eligible for scored use or clinical release until the stated approval is recorded.",
        "",
        "## Items marked or derived as `clinicalReviewRequired`",
        "",
        "| Item | Title | Why review is required | Approval needed | Current source mapping |",
        "|---|---|---|---|---|",
    ]
    for item in review_items:
        lines.append(
            f"| {markdown_escape(item['id'])} | {markdown_escape(item['title'])} | {markdown_escape(item['why'])} | {markdown_escape(item['approval'])} | {markdown_escape(item['sources'])} |"
        )
    lines.extend(
        [
            "",
            "## Course-source reconciliation gates",
            "",
            "| Item | Decision topic | Why review is required | Approval needed |",
            "|---|---|---|---|",
        ]
    )
    for identifier, title, why, approval in SME_ITEMS:
        lines.append(
            f"| {identifier} | {markdown_escape(title)} | {markdown_escape(why)} | {markdown_escape(approval)} |"
        )
    lines.extend(
        [
            "",
            "## Release rule",
            "",
            "Approval must be recorded by a qualified SRFAC instructor or appropriate clinical SME. Update the cited content, retain the original source status in the extract, release a new content version, regenerate this register and rerun all clinical-safety tests. An internal product reviewer cannot substitute for clinical sign-off.",
        ]
    )
    REVIEW_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")

    checklist_items: list[tuple[str, str, str]] = []
    for item in review_items:
        checklist_items.append((item["id"], item["title"], item["sources"]))
    for identifier, title, _, _ in SME_ITEMS:
        checklist_items.append((identifier, title, "Docs/COURSE_SOURCE_DIFFERENCES.md, section 3"))
    checklist_lines = [
        "# Clinical Approval Checklist",
        "",
        "Course: **Lifesaver Vision: CPR + AED Spatial Academy**  ",
        "Content version: **1.0.0**  ",
        "Record type: **Internal content-review record — not SRFAC certification**",
        "",
        "Qualified reviewer name and credentials: ______________________________  ",
        "Organisation / appointment: __________________________________________  ",
        "Overall review date: __________________  ",
        "Overall decision: ☐ Approve ☐ Approve with revisions ☐ Reject / retain lock",
        "",
        "| Item | Source under review | Reviewer | Date | Decision | Required revision / rationale |",
        "|---|---|---|---|---|---|",
    ]
    for identifier, title, sources in checklist_items:
        checklist_lines.append(
            f"| {markdown_escape(identifier)} — {markdown_escape(title)} | {markdown_escape(sources)} |  |  | ☐ Approve ☐ Revise ☐ Reject |  |"
        )
    checklist_lines.extend(
        [
            "",
            "## Final release attestations",
            "",
            "- [ ] All `clinicalReviewRequired` learner-facing items have an item-level decision.",
            "- [ ] No unresolved or `requires_sme_review` fact is reachable through scored content.",
            "- [ ] The seven-ring Chain of Survival presentation has an explicit decision.",
            "- [ ] Module 9 remains locked unless the adult core is complete, instructor approval is recorded and the content lifecycle is clinically approved or published.",
            "- [ ] Adult depth and force are displayed as **Not physically assessed** without a verified external sensor.",
            "- [ ] Every 995 interaction is visibly labelled **SIMULATION** and cannot place a call.",
            "- [ ] Completion wording says **internal completion record**, not SRFAC certification.",
            "",
            "Reviewer signature / secure approval reference: ____________________________  ",
            "Release approver: ____________________________  Date: __________________",
        ]
    )
    CHECKLIST_PATH.write_text("\n".join(checklist_lines) + "\n", encoding="utf-8")


def main() -> None:
    course = load_json(COURSE_PATH)
    question_bank = load_json(QUESTIONS_PATH)
    scenarios = load_json(SCENARIOS_PATH)
    facts_document = load_json(FACTS_PATH)
    facts = {fact["id"]: fact for fact in facts_document["facts"]}
    require(len(facts) == 70, f"Expected 70 clinical facts, found {len(facts)}")

    course_rows, review_items = collect_course_rows(course, facts)
    question_rows = collect_question_rows(course, question_bank, facts)
    scenario_rows = collect_scenario_rows(course, scenarios, facts)
    rows = course_rows + question_rows + scenario_rows
    identifiers = [(row.kind, row.identifier) for row in rows]
    require(len(identifiers) == len(set(identifiers)), "Duplicate traceability row kind/identifier")

    existing_review_ids = {item["id"] for item in review_items}
    for row in rows:
        if row.review_status != "clinicalReviewRequired" or row.identifier in existing_review_ids:
            continue
        title = row.text.split(": ", maxsplit=1)[0]
        if len(title) > 120:
            title = f"{row.kind} in {row.scope}"
        review_items.append(
            {
                "id": row.identifier,
                "title": title,
                "why": review_reason_for_references(row.references, facts),
                "approval": "A qualified SRFAC instructor or clinical SME must approve, revise or reject this item before clinical release; it must remain outside scoring while unresolved.",
                "sources": source_summary(row.references),
            }
        )
        existing_review_ids.add(row.identifier)

    write_matrix(rows, course)
    write_review_documents(review_items)
    print(
        f"PASS: {len(rows)} mapped trace rows, 0 unmapped; "
        f"wrote {MATRIX_PATH.relative_to(ROOT)}, {REVIEW_PATH.relative_to(ROOT)} "
        f"and {CHECKLIST_PATH.relative_to(ROOT)}"
    )


if __name__ == "__main__":
    main()
