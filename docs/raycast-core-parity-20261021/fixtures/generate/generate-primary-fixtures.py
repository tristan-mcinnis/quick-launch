#!/usr/bin/env python3
"""Generate the PRIMARY synthetic fixtures for the Quick Launch / Raycast
matched-task protocol (docs/raycast-core-parity-20261021).

Everything here is original synthetic content. No real company, brand, person,
policy, URL, key or client record appears in any output. Outputs are
deterministic: re-running the script reproduces byte-identical files, so the
SHA256SUMS manifest is stable.

Holdout fixtures are NOT produced here. They live outside Git, in the goal
evidence directory described in ../fixture-method.md (private root, not a
repository path), and are built by a private script kept there.

Byte hashes depend on the toolchain recorded in fixture-facts.json: the Python
version, the Pillow version, and Pillow's bundled default bitmap font (no
system font file is read). A different Pillow release may change the chart
rendering and therefore the PNG hash.

Usage:
  python3 generate/generate-primary-fixtures.py                 # write in place
  python3 generate/generate-primary-fixtures.py --output-dir DIR  # rebuild in a
                                                               # scratch copy
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import platform
import textwrap
import zlib
import struct
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont
import PIL

FIXTURES = Path(__file__).resolve().parents[1]
TEXT = FIXTURES / "text"
RICH = FIXTURES / "richtext"
DOCS = FIXTURES / "documents"
IMAGES = FIXTURES / "images"
PROMPTS = FIXTURES / "prompts"
ROUTES = FIXTURES / "routes"


def set_root(root: Path) -> None:
    """Point every output path at another root (scratch rebuild, review copy)."""
    global FIXTURES, TEXT, RICH, DOCS, IMAGES, PROMPTS, ROUTES
    FIXTURES = root
    TEXT = root / "text"
    RICH = root / "richtext"
    DOCS = root / "documents"
    IMAGES = root / "images"
    PROMPTS = root / "prompts"
    ROUTES = root / "routes"

FIXED_TIME = dt.datetime(2026, 10, 21, 9, 0, 0)

SYNTHETIC_MD = (
    "<!-- SYNTHETIC SAMPLE: created for product testing. No real company, "
    "person, policy, URL or record. Not a client document. -->\n\n"
)


def write_text(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")


def write_json(path: Path, data: dict) -> None:
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


# --------------------------------------------------------------------------
# 1. English memo: ~320 words, exactly four numeric facts, two delivery dates,
#    four suppliers (two with no date), three risks in stated order.
# --------------------------------------------------------------------------

MEMO_EN_BODY = """\
MEMO: Pilot Component Order, Wave One

Purpose
This memo records the agreed position for the first wave of the pilot component order. It goes to the pilot steering group for a decision and carries no commercial commitment on its own. Nothing in it approves spend.

Order and cost
The pilot covers 1,240 units, split across four suppliers, labelled A to D. The frozen estimate was set before the second quote round. The current blended cost sits 18 percent above that estimate, driven by expedited freight and one retooling step at the supplier.

Schedule
Supplier A has committed delivery on 2026-11-14. Supplier B has committed delivery on 2026-12-03. Suppliers C and D have not confirmed a delivery date and are tracked weekly until they do. The dock plan assumes both committed dates hold. The weekly tracker is the single record of those dates, and it is the only place a date change is logged.

Audit position
The internal audit closed with 2 open findings, both about incoming inspection records for the same component family. Neither finding blocks the order, but both add checking work at goods-in.

Lead time
The longest confirmed lead time is 6 weeks from purchase order to dock. Any change to the order volume resets that clock.

Risks, in order of severity
Risk, highest: schedule slip. Suppliers C and D hold no committed date, so the wave can move without warning. Mitigation: hold a fortnight of dock buffer.
Risk, middle: cost drift. The gap against the estimate can widen if freight rates move again. Mitigation: fix freight for this wave only.
Risk, lowest: inspection load. The open findings add checking work at goods-in. Mitigation: add one inspection shift for the first month.

Decision requested
Confirm the volume and accept the dock buffer, or return the memo with a revised volume. A decision before the next steering group keeps the first date reachable. A later decision puts both committed dates at risk.

Contact
Sourcing Desk, pilot planning.
"""

# The four numeric facts and the two dates are the only digit runs allowed in
# the memo body besides the three risk ordinals (which are words, not digits).
MEMO_METRICS = {
    "word_count_target": 320,
    "numeric_facts": ["1,240 units", "18 percent", "6 weeks", "2 open findings"],
    "delivery_dates": {
        "supplier_a": "2026-11-14",
        "supplier_b": "2026-12-03",
        "supplier_c": None,
        "supplier_d": None,
    },
    "risk_order": ["schedule slip", "cost drift", "inspection load"],
    "mitigations": {
        "schedule slip": "hold a fortnight of dock buffer",
        "cost drift": "fix freight for this wave only",
        "inspection load": "add one inspection shift for the first month",
    },
}


def memo_en_words() -> int:
    return len(MEMO_EN_BODY.split())


# --------------------------------------------------------------------------
# 2. Chinese memo: glossary terms 供应链 / 复购率, two dates, one unit count.
# --------------------------------------------------------------------------

MEMO_ZH_BODY = """\
合成样本 · 供应链备忘录

目的
本备忘录记录试产订单第一批的内部共识，仅用于计划讨论，不构成商业承诺。

订单与成本
首批 800 件，由四家供应商分担，编号为 A 至 D。冻结估算是第二轮报价之前确定的。当前综合成本比冻结估算高 18%。

交期
供应商 A 的交付日期为 2026-11-14；供应商 B 的交付日期为 2026-12-03。供应商 C 与 D 尚未确认交付日期，每周跟踪一次，直到确认。

指标
上一轮试销的复购率为 34%。供应链响应时间的中位数为 6 周。

风险（按严重程度排列）
最高风险：交期滑动，因为 C 与 D 没有确认日期。中等风险：成本上浮，运费再次变动就会扩大。最低风险：来料检验负荷上升。

结论
请确认数量与两周缓冲，或退回本备忘录并给出修改后的数量。

联系人
采购计划组（虚构）。
"""

MEMO_ZH_FACTS = {
    "glossary": {"供应链": "supply chain", "复购率": "repeat purchase rate"},
    "dates": ["2026-11-14", "2026-12-03"],
    "unit_count": "800",
    "other_numbers": ["18%", "34%", "6 周"],
}


# --------------------------------------------------------------------------
# 3. URL paragraph with the literal CANARY_URL placeholder and a
#    non-resolving .invalid host. Never a real or private URL.
# --------------------------------------------------------------------------

URL_PARAGRAPH_BODY = """\
The pilot tracker lives in one place. Use the shared tracker at CANARY_URL (https://canary-url.invalid/memo-2026) for the weekly count, and add the supplier name, the committed date and a short note for each line. Do not paste rates or unit costs into the tracker, because the file is read by people outside the buying team. If a supplier misses a weekly update, write a single line saying so and move on. The tracker records what we know today. It is not the place to argue about what we should do next, and it is not a decision log. Keep every entry to one or two lines so the weekly review stays short.
"""

CANARY = {
    "placeholder_token": "CANARY_URL",
    "url_literal": "https://canary-url.invalid/memo-2026",
    "host_tld": ".invalid",
    "resolves": False,
    "note": (
        "RFC 6761 reserves .invalid; the name cannot resolve in public DNS. "
        "Any fetch attempt must fail, so the observation is bounded to 'no successful "
        "retrieval', never to 'no attempt' and never to a claim about cloud-side fetching."
    ),
}


# --------------------------------------------------------------------------
# 4. Mixed ZH/EN note for formalisation (T06).
# --------------------------------------------------------------------------

MIXED_NOTE_BODY = """\
Q3 pilot note，今天必须处理：

1. 供应商C 的 delivery date 还是没 confirm，本周五前要拿到书面回复。
2. SKU-A12 和 SKU-B7 的 MOQ 仍然是 600 pcs，但 packaging 要改成 bilingual 版本。
3. docking plan 里的 buffer 只有 2 days，比 agreed 的 5 days 少。
4. 请把以上内容整理给 steering group，不要加新事实。

备注：supplier D 的 contact 已经离职，新的 contact 还没给。
"""

MIXED_NOTE_FACTS = {
    "preserve_tokens": ["Q3", "SKU-A12", "SKU-B7", "MOQ", "steering group",
                        "Supplier C", "Supplier D"],
    "numbers": ["600 pcs", "2 days", "5 days"],
    "forbidden": "CJK characters in the English output",
    "no_new_facts": "must not state that the buffer gap is fixed or that a new contact exists",
}


# --------------------------------------------------------------------------
# 5. Unrelated canary notes: noise that must never enter an answer.
# --------------------------------------------------------------------------

CANARY_NOTES_BODY = """\
# SYNTHETIC NOTE — unrelated sample, not part of any task source

Desk booking rota for the third floor, reference NOTE-CANARY-4471.
Monday and Thursday belong to the design pod. Tuesday is shared. The corner desks are booked by whoever arrives first, and the booking sheet is wiped at the end of each month.

Coffee machine service is booked for the first working day of the month. Filters live in the low cupboard. Do not put milk in the top shelf.

Holiday cover: the rota swaps every second week. Ask the desk lead before changing a slot. Plant watering happens on Fridays and is nobody's formal job.
"""

CANARY_NOTES_TOKEN = "NOTE-CANARY-4471"


# --------------------------------------------------------------------------
# 6. Rich-text target (RTF) with a canonical semantic text and an expected
#    run-attribute manifest. Byte equality is never the criterion.
# --------------------------------------------------------------------------

RTF_PARAGRAPHS = [
    {
        "index": 1,
        "runs": [{"text": "SYNTHETIC RICH-TEXT SAMPLE", "bold": True, "italic": False,
                  "underline": False, "size_pt": 14}],
    },
    {
        "index": 2,
        "runs": [{"text": "Draft note for the pilot steering group. This file is not a real record.",
                  "bold": False, "italic": True, "underline": False, "size_pt": 10}],
    },
    {
        "index": 3,
        "runs": [{
            "text": ("The pilot covers 1,240 units across four suppliers. Supplier C holds no "
                     "committed delivery date, and the dock plan assumes a buffer that nobody has "
                     "agreed yet. The tracker still shows the old volume."),
            "bold": False, "italic": False, "underline": False, "size_pt": 11}],
    },
    {
        "index": 4,
        "runs": [
            {"text": "Escalation route:", "bold": True, "italic": False, "underline": False,
             "size_pt": 11},
            {"text": " sourcing desk, weekly tracker, then the steering group.", "bold": False,
             "italic": False, "underline": False, "size_pt": 11},
        ],
    },
    {
        "index": 5,
        "runs": [
            {"text": "Cost note:", "bold": False, "italic": False, "underline": True,
             "size_pt": 9},
            {"text": " the blended cost sits 18 percent above the frozen estimate.", "bold": False,
             "italic": False, "underline": False, "size_pt": 9},
        ],
    },
    {
        "index": 6,
        "runs": [{"text": "End of synthetic sample.", "bold": False, "italic": True,
                  "underline": False, "size_pt": 11}],
    },
]


def build_rtf() -> str:
    def run_rtf(run: dict) -> str:
        ctl = ""
        if run["bold"]:
            ctl += r"\b"
        if run["italic"]:
            ctl += r"\i"
        if run["underline"]:
            ctl += r"\ul"
        size = int(round(run["size_pt"] * 2))
        text = run["text"].replace("\\", r"\\").replace("{", r"\{").replace("}", r"\}")
        return "{\\f1\\fs%d%s %s}" % (size, ctl, text)

    body = []
    for para in RTF_PARAGRAPHS:
        body.append("".join(run_rtf(r) for r in para["runs"]) + r"\par")
    return (
        "{\\rtf1\\ansi\\ansicpg1252\\deff0\n"
        "{\\fonttbl{\\f0\\fswiss Helvetica;}{\\f1\\froman Times;}}\n"
        "\\viewkind4\\uc1\n"
        + "\n".join(body)
        + "\n}\n"
    )


def canonical_text() -> str:
    return "\n".join("".join(r["text"] for r in p["runs"]) for p in RTF_PARAGRAPHS) + "\n"


def rtf_expected() -> dict:
    canon = canonical_text()
    target = RTF_PARAGRAPHS[2]
    target_text = "".join(r["text"] for r in target["runs"])
    start = canon.index(target_text)
    return {
        "fixture_id": "richtext-target",
        "kind": "rich-text edit target",
        "synthetic_notice": ("Synthetic sample. No real company, person or record."),
        "criterion_note": (
            "Integrity is judged on semantic text and per-run attributes. Byte-identical RTF "
            "serialisation is explicitly NOT a criterion, and neither is any particular RTF "
            "producer."
        ),
        "canonical_text_file": "richtext-target.canonical.txt",
        "paragraph_separator": "\n",
        "paragraphs": [
            {
                "index": p["index"],
                "text": "".join(r["text"] for r in p["runs"]),
                "runs": p["runs"],
            }
            for p in RTF_PARAGRAPHS
        ],
        "target_selection": {
            "paragraph_index": 3,
            "text": target_text,
            "start_offset": start,
            "end_offset": start + len(target_text),
            "offset_basis": "canonical_text_file, characters, 0-based",
            "action": "replace the selected paragraph with the accepted short version",
        },
        "must_remain_unchanged": {
            "paragraph_indexes": [1, 2, 4, 5, 6],
            "text_and_attributes": "every run, attribute and paragraph break outside the target",
        },
        "attributes_checked": ["bold", "italic", "underline", "size_pt"],
        "word_limit_for_replacement": 20,
    }


# --------------------------------------------------------------------------
# 7. Monochrome chart: four values 12 / 27 / 9 / 34. Total is NOT printed, so
#    the total (82) has to be computed.
# --------------------------------------------------------------------------

CHART_VALUES = [12, 27, 9, 34]
CHART_LABELS = ["Cohort 1", "Cohort 2", "Cohort 3", "Cohort 4"]
CHART_TOTAL = sum(CHART_VALUES)


def build_chart() -> None:
    W, H = 1200, 800
    img = Image.new("L", (W, H), 255)
    d = ImageDraw.Draw(img)

    def font(size: int):
        return ImageFont.load_default(size=size)

    f_title = font(34)
    f_axis = font(26)
    f_val = font(30)

    left, right, top, bottom = 140, 80, 170, 150
    plot_w = W - left - right
    plot_h = H - top - bottom
    ymax = 40

    d.text((left, 70), "Synthetic sample chart: units per cohort", fill=0, font=f_title)

    # axes
    d.line([(left, top), (left, top + plot_h)], fill=0, width=3)
    d.line([(left, top + plot_h), (left + plot_w, top + plot_h)], fill=0, width=3)

    # y axis ticks and labels (0..40 step 10)
    for tick in range(0, ymax + 1, 10):
        y = top + plot_h - int(plot_h * tick / ymax)
        d.line([(left - 12, y), (left, y)], fill=0, width=3)
        label = str(tick)
        tw = d.textlength(label, font=f_axis)
        d.text((left - 24 - tw, y - 14), label, fill=0, font=f_axis)

    slot = plot_w / len(CHART_VALUES)
    bar_w = int(slot * 0.52)
    for i, (value, label) in enumerate(zip(CHART_VALUES, CHART_LABELS)):
        cx = left + slot * (i + 0.5)
        bar_h = int(plot_h * value / ymax)
        x0 = int(cx - bar_w / 2)
        x1 = int(cx + bar_w / 2)
        y1 = top + plot_h
        y0 = y1 - bar_h
        d.rectangle([x0, y0, x1, y1], fill=0, outline=0, width=3)
        vtext = str(value)
        vw = d.textlength(vtext, font=f_val)
        d.text((cx - vw / 2, y0 - 44), vtext, fill=0, font=f_val)
        lw = d.textlength(label, font=f_axis)
        d.text((cx - lw / 2, top + plot_h + 24), label, fill=0, font=f_axis)

    d.text((left, H - 46), "Source: synthetic sample, created for product testing.", fill=0,
           font=f_axis)
    img = img.convert("1")
    img.save(IMAGES / "chart-monochrome.png", format="PNG", optimize=False, dpi=(144, 144))


# --------------------------------------------------------------------------
# 8. Saved prompts: one with three named arguments and defaults (T13), one
#    Chinese selection-required prompt (T14), one with a required argument and
#    no default (T15).
# --------------------------------------------------------------------------

DIGEST_PROMPT = {
    "saved_prompt_id": "sp-digest-en",
    "title": "Brief digest",
    "synthetic_notice": "Synthetic fixture prompt. No real client, brand or person.",
    "surface": "quick-ai",
    "body": ("Write a digest of the attached memo for {{audience}} in a {{tone}} tone. "
             "Use about {{length}}. Keep every figure and date exactly as written."),
    "arguments": [
        {"name": "audience", "required": False, "default": "the procurement team",
         "hint": "who reads the digest"},
        {"name": "tone", "required": False, "default": "plain",
         "hint": "plain, formal or direct"},
        {"name": "length", "required": False, "default": "120 words",
         "hint": "target length"},
    ],
    "argument_count": 3,
    "all_arguments_have_defaults": True,
    "expected_expansion_no_override": (
        "Write a digest of the attached memo for the procurement team in a plain tone. "
        "Use about 120 words. Keep every figure and date exactly as written."
    ),
    "expected_defaults_applied": {
        "audience": "the procurement team",
        "tone": "plain",
        "length": "120 words",
    },
    "expected_argument_prompts": 0,
    "notes": (
        "T13 invokes this prompt with no overrides. Because every argument has a default, the "
        "app must not ask for anything and must not ask the user to retype the instruction."
    ),
}

ZH_PROMPT = {
    "saved_prompt_id": "sp-summary-zh",
    "title": "中文摘要",
    "synthetic_notice": "Synthetic fixture prompt. No real client, brand or person.",
    "surface": "quick-ai",
    "body": "请把选中的内容总结为 {{length}} 的摘要，语气{{tone}}，保留所有日期和数字。",
    "arguments": [
        {"name": "tone", "required": False, "default": "正式", "hint": "语气"},
        {"name": "length", "required": False, "default": "80字", "hint": "摘要长度"},
    ],
    "argument_count": 2,
    "requires_selection": True,
    "selection_required_message_any_language": True,
    "expected_expansion_no_override": "请把选中的内容总结为 80字 的摘要，语气正式，保留所有日期和数字。",
    "notes": (
        "T14 invokes this prompt with no selection. The app must show a clear missing-input "
        "state: no empty submission, and no silent substitution of clipboard contents. Error "
        "wording may be English or Chinese; the missing-input state is what is scored."
    ),
}

BRIEF_PROMPT = {
    "saved_prompt_id": "sp-supplier-brief",
    "title": "Supplier brief",
    "synthetic_notice": "Synthetic fixture prompt. No real client, brand or person.",
    "surface": "quick-ai",
    "body": "Draft a supplier status brief for {{supplier}} covering {{window}} as {{format}}.",
    "arguments": [
        {"name": "supplier", "required": True, "default": None,
         "hint": "supplier label, for example Supplier C"},
        {"name": "window", "required": False, "default": "the current planning window",
         "hint": "time window"},
        {"name": "format", "required": False, "default": "three bullets",
         "hint": "output shape"},
    ],
    "argument_count": 3,
    "expected_blocked_state": (
        "Submit with supplier empty: the app must block the request and show that supplier is "
        "required. No AI request may be submitted."
    ),
    "expected_after_fill": (
        "Fill supplier with 'Supplier C' and submit: exactly one AI request, using the two "
        "defaults unchanged."
    ),
    "expected_expansion_after_fill": (
        "Draft a supplier status brief for Supplier C covering the current planning window as "
        "three bullets."
    ),
}


# --------------------------------------------------------------------------
# 9. Route slots: logical, vendor-free. Real model identifiers are recorded in
#    the run log by the operator, never in a fixture.
# --------------------------------------------------------------------------

ROUTE_SLOTS = {
    "synthetic_notice": "Logical route slots only. No vendor model identifiers, keys or URLs.",
    "route_slots": [
        {
            "slot": "route-default",
            "class": "routine",
            "description": ("the model and destination already selected and displayed by the app "
                            "when the task starts; no change is made"),
            "evidence_required": "app label at submit time",
        },
        {
            "slot": "route-alt",
            "class": "non-routine",
            "description": ("a second configured model, if the app exposes a chooser; the operator "
                            "records the chosen label before submit"),
            "evidence_required": "app label, request metadata and any receipt shown after the answer",
        },
        {
            "slot": "route-unreachable",
            "class": "declared failure",
            "endpoint": "http://127.0.0.1:9/v1",
            "description": ("declared unreachable endpoint on the discard port. No listener exists, "
                            "so a request fails immediately without touching any network host."),
            "evidence_required": "error state text, no partial answer presented as complete",
        },
    ],
    "rules": [
        "Never place an API key, token or account identifier in a fixture or a run log.",
        "A route change is recorded before the affected turn, never reconstructed afterwards.",
        "An unobserved route is unknown, not a win.",
    ],
}


# --------------------------------------------------------------------------
# 10. Two-page selectable returns policy PDF (clause IDs + one control code).
# --------------------------------------------------------------------------

RETURNS_POLICY_PAGE_1 = [
    ("title", "Returns Policy"),
    ("small", "Synthetic sample document, created for product testing. No real company, policy or record."),
    ("gap", None),
    ("small", "Document ID RP-SYN-2026-07   Version 2.3   Effective 2026-10-01   Owner: Returns Desk"),
    ("rule", None),
    ("h1", "RP-1  Scope"),
    ("body", "RP-1.1  This policy covers returns of standard catalogue components supplied under a "
             "pilot order. It does not cover tooling, consumables or custom parts."),
    ("body", "RP-1.2  A return is valid only when the buyer has a return reference issued by the "
             "returns desk. The reference is quoted on every communication about the return."),
    ("body", "RP-1.3  Where this policy and a signed order schedule disagree, the order schedule wins "
             "for that order only."),
    ("h1", "RP-2  Definitions"),
    ("body", "RP-2.1  Delivery date means the date the carrier records handover at the buyer dock."),
    ("body", "RP-2.2  Invoiced value means the unit price on the accepted order multiplied by the "
             "quantity returned, excluding freight and duty."),
    ("body", "RP-2.3  Restocking charge means the deduction applied to a return to cover inspection, "
             "repacking and put-away."),
    ("h1", "RP-3  Standard returns"),
    ("body", "RP-3.1  A buyer may return standard catalogue components for credit within 30 days of "
             "delivery, provided the packaging is unopened and the labels are legible."),
    ("body", "RP-3.2  Standard returns need no written approval. The buyer raises the return in the "
             "portal, prints the label and books collection."),
    ("body", "RP-3.3  Credit for a standard return is issued after goods-in inspection confirms the "
             "quantity and condition."),
    ("body", "RP-3.4  Opened packaging is accepted only where the fault is ours, and only with "
             "photographs attached to the return record."),
    ("h1", "RP-4  Late returns"),
    ("body", "RP-4.1  The 30-day window in RP-3.1 runs from the delivery date recorded by the carrier."),
    ("body", "RP-4.2  A return requested more than 30 days after delivery is accepted only with "
             "written exception approval from the returns desk. A restocking charge of 15 percent of "
             "the invoiced value applies to every approved late return, and the charge is deducted "
             "from the credit note rather than invoiced separately."),
    ("body", "RP-4.3  Exception approval is valid for the quantity and part numbers named in the "
             "approval. A second shipment needs a second approval."),
    ("h1", "RP-5  Refunds and credit"),
    ("body", "RP-5.1  Credit is issued to the account that paid the original invoice. Cash refunds "
             "are not available on account orders."),
    ("body", "RP-5.2  Credit notes are raised within ten working days of a passed inspection."),
]

RETURNS_POLICY_PAGE_2 = [
    ("h1", "RP-6  Exceptions"),
    ("body", "RP-6.1  Faulty components are accepted at any time inside the warranty period and carry "
             "no restocking charge."),
    ("body", "RP-6.2  Pilot orders may carry a written deviation from RP-3 and RP-4. The deviation is "
             "recorded on the order schedule and is not implied by any email."),
    ("body", "RP-6.3  Regulated components are excluded from this policy and follow the separate "
             "handling instruction issued with the order."),
    ("h1", "RP-7  Restocking charges"),
    ("body", "RP-7.1  Standard returns carry no restocking charge."),
    ("body", "RP-7.2  Approved late returns carry the charge stated in RP-4.2."),
    ("body", "RP-7.3  Returns refused at goods-in for condition carry no charge, because no credit is "
             "raised."),
    ("h1", "RP-8  Appeals"),
    ("body", "RP-8.1  A buyer may appeal a refused return once, in writing, within ten working days of "
             "the refusal notice."),
    ("body", "RP-8.2  The appeal is reviewed by a second reviewer who did not decide the first case."),
    ("body", "RP-8.3  The appeal decision is final for that return reference."),
    ("h1", "RP-9  Records"),
    ("body", "RP-9.1  Return records are kept for six years from the credit note date."),
    ("body", "RP-9.2  Photographs, inspection notes and approvals are part of the record and are not "
             "deleted when a case closes."),
    ("body", "RP-9.3  This policy is reviewed every year, or earlier if a pilot schedule changes the "
             "return terms."),
    ("rule", None),
    ("h1", "Document control"),
    ("body", "Policy ID: RP-SYN-2026-07    Version: 2.3    Pages: 2"),
    ("body", "Control code: QX7-4418-RET"),
    ("body", "This control code identifies this synthetic sample only. Quote it in any test note "
             "about this document."),
    ("small", "End of synthetic sample."),
]


def pdf_escape(s: str) -> str:
    return s.replace("\\", r"\\").replace("(", r"\(").replace(")", r"\)")


def pdf_wrap(text: str, width: int) -> list[str]:
    return textwrap.wrap(text, width=width, break_long_words=False, break_on_hyphens=False) or [""]


def build_pdf_blocks(blocks: list[tuple[str, str | None]]) -> list[list[tuple[str, int, str, int]]]:
    """Return a list of pages; each page is a list of (font, size, text, advance)."""
    styles = {
        "title": ("F2", 20, 26),
        "h1": ("F2", 12, 18),
        "body": ("F1", 10, 13),
        "small": ("F1", 8, 11),
    }
    page_lines: list[list[tuple[str, int, str, int]]] = []
    current: list[tuple[str, int, str, int]] = []
    cursor = 792 - 78
    left = 66
    bottom = 66

    for kind, text in blocks:
        if kind == "gap":
            cursor -= 12
            continue
        if kind == "rule":
            cursor -= 6
            current.append(("RULE", 0, "", 12))
            cursor -= 0
            continue
        font, size, advance = styles[kind]
        width = 92 if size <= 8 else (84 if size <= 10 else 74)
        for i, line in enumerate(pdf_wrap(text, width)):
            if cursor < bottom:
                page_lines.append(current)
                current = []
                cursor = 792 - 78
            current.append((font, size, line, left if i == 0 else left + 8))
            cursor -= advance
    page_lines.append(current)
    return page_lines


def build_pdf(pages: list[list[tuple[str, int, str, int]]], path: Path, title: str) -> None:
    header = b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n"
    objects: dict[int, bytes] = {}
    objects[1] = b"<< /Type /Catalog /Pages 2 0 R >>"
    objects[3] = b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"
    objects[4] = (b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold "
                  b"/Encoding /WinAnsiEncoding >>")
    info_num = 5 + 2 * len(pages)
    kids = []
    for i in range(len(pages)):
        kids.append(f"{5 + 2 * i} 0 R")
    objects[2] = ("<< /Type /Pages /Kids [" + " ".join(kids) + f"] /Count {len(pages)} >>").encode()

    for i, lines in enumerate(pages):
        page_num = 5 + 2 * i
        content_num = 6 + 2 * i
        body_parts = []
        y = 792 - 78
        for font, size, text, x in lines:
            if font == "RULE":
                y -= 4
                body_parts.append("0.5 w 0 G")
                body_parts.append(f"66 {y} m 546 {y} l S")
                y -= 10
                continue
            body_parts.append("BT")
            body_parts.append(f"/{font} {size} Tf")
            body_parts.append(f"1 0 0 1 {x} {y} Tm")
            body_parts.append(f"({pdf_escape(text)}) Tj")
            body_parts.append("ET")
            y -= 13 if size <= 10 else 18
        content = ("\n".join(body_parts) + "\n").encode("latin-1")
        objects[content_num] = (b"<< /Length " + str(len(content)).encode() + b" >>\nstream\n"
                                + content + b"endstream")
        objects[page_num] = (
            f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
            f"/Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> "
            f"/Contents {content_num} 0 R >>"
        ).encode()

    objects[info_num] = (
        f"<< /Title ({pdf_escape(title)}) /Producer (synthetic fixture builder) "
        f"/CreationDate (D:20261021090000Z) >>"
    ).encode()

    out = bytearray(header)
    offsets: dict[int, int] = {}
    for num in sorted(objects):
        offsets[num] = len(out)
        out += f"{num} 0 obj\n".encode() + objects[num] + b"\nendobj\n"
    xref_pos = len(out)
    max_num = max(objects)
    out += f"xref\n0 {max_num + 1}\n".encode()
    out += b"0000000000 65535 f \n"
    for num in range(1, max_num + 1):
        if num in offsets:
            out += f"{offsets[num]:010d} 00000 n \n".encode()
        else:
            out += b"0000000000 65535 f \n"
    out += (f"trailer\n<< /Size {max_num + 1} /Root 1 0 R /Info {info_num} 0 R >>\n"
            f"startxref\n{xref_pos}\n%%EOF\n").encode()
    path.write_bytes(bytes(out))


# --------------------------------------------------------------------------
# 11. Long supplier policy DOCX (~1,700 words) with a late-source schedule.
# --------------------------------------------------------------------------

LONG_POLICY = [
    ("h1", "Supplier Sourcing and Delivery Policy"),
    ("small", "Synthetic sample pack, created for product testing. No real company, supplier, "
              "policy or record. Document ID SP-SYN-2026-04, version 4.1, effective 2026-10-01."),
    ("p", "This pack sets out how the sourcing desk qualifies suppliers, confirms orders, measures "
          "delivery and handles exceptions on standard catalogue components. It is written for "
          "internal use and for suppliers who hold an active pilot order. Where an order schedule "
          "states different terms for a named part number, the schedule wins for that part number "
          "and for that order only."),

    ("h2", "SP-1  Purpose and scope"),
    ("p", "SP-1.1  The policy applies to every supplier that holds a confirmed order for standard "
          "catalogue components, including pilot orders and repeat orders placed against an "
          "existing part number."),
    ("p", "SP-1.2  The policy does not apply to tooling, custom fabrications, consumables or "
          "regulated components. Those categories follow the separate instruction issued with the "
          "order."),
    ("p", "SP-1.3  A supplier accepts this policy by confirming an order. No signature is needed "
          "beyond the order confirmation, and no separate framework agreement is implied."),
    ("p", "SP-1.4  The sourcing desk reviews the policy once a year, or earlier when a pilot schedule "
          "changes the delivery terms for a named part number."),

    ("h2", "SP-2  Definitions"),
    ("p", "SP-2.1  Confirmed order means an order the supplier has accepted in writing, with a unit "
          "price, a quantity and a delivery date."),
    ("p", "SP-2.2  Delivery date means the date the carrier records handover at the buyer dock, not "
          "the date the supplier dispatches."),
    ("p", "SP-2.3  Committed date means a delivery date the supplier has confirmed in writing for a "
          "named part number and quantity."),
    ("p", "SP-2.4  Lead time means the working days between purchase order and dock handover, "
          "measured on the last four orders for the same part number."),
    ("p", "SP-2.5  Late-source disclosure means the written notice a supplier sends when the origin "
          "of a component changes after order confirmation."),
    ("p", "SP-2.6  Control code means the short identifier printed on a controlled document and "
          "quoted in any record that refers to it."),

    ("h2", "SP-3  Supplier qualification"),
    ("p", "SP-3.1  A new supplier is qualified on three checks: legal identity, production capacity "
          "for the named part numbers, and a passed sample inspection."),
    ("p", "SP-3.2  Legal identity is checked against the registration document supplied by the "
          "supplier. A trading name alone is not enough."),
    ("p", "SP-3.3  Capacity is checked against the requested monthly volume plus a stated headroom. "
          "Headroom below a fifth of the requested volume is recorded as a risk."),
    ("p", "SP-3.4  Sample inspection covers dimensional checks, label accuracy and packaging "
          "condition. A failed sample is reworked once before the supplier is declined."),
    ("p", "SP-3.5  Qualification records are held by the sourcing desk and are not shared with other "
          "suppliers."),

    ("h2", "SP-4  Order confirmation and change control"),
    ("p", "SP-4.1  The sourcing desk issues a purchase order that names the part numbers, the "
          "quantity, the unit price, the delivery date and the dock."),
    ("p", "SP-4.2  The supplier confirms the order within two working days. A confirmation that "
          "changes any term is treated as a counter-offer and needs sourcing desk approval."),
    ("p", "SP-4.3  A quantity change of more than a tenth of the ordered volume needs written "
          "approval and resets the lead time clock."),
    ("p", "SP-4.4  A date change is accepted only when the supplier states the new date in writing "
          "and names the cause. Verbal date changes are not tracked."),
    ("p", "SP-4.5  A part number change is never accepted on an open order. The order is cancelled "
          "and reissued."),
    ("p", "SP-4.6  Every change is recorded on the order record with the date it was agreed and the "
          "person who agreed it."),

    ("h2", "SP-5  Delivery performance"),
    ("p", "SP-5.1  Delivery performance is measured against the committed date, not the requested "
          "date."),
    ("p", "SP-5.2  A delivery that arrives before the committed date is on time. Early delivery does "
          "not earn a credit and does not change the inspection slot."),
    ("p", "SP-5.3  A delivery that arrives after the committed date is recorded as late, with the "
          "number of working days stated on the record."),
    ("p", "SP-5.4  Three late deliveries in a rolling quarter trigger a review with the supplier. "
          "The review is recorded, even when no remedy is applied."),
    ("p", "SP-5.5  The supplier sends a dispatch notice on the day of dispatch, naming the carrier, "
          "the carton count and the expected dock date."),
    ("p", "SP-5.6  Missing dispatch notices are recorded as a documentation defect. They do not by "
          "themselves make a delivery late."),
    ("p", "SP-5.7  Dock bookings are made by the buyer. A supplier that arrives without a booking is "
          "held at the gate and the wait is not counted as late delivery."),

    ("p", "SP-5.8  A supplier that cannot meet a committed date states the new date in writing "
          "before the original date passes. A late notice is recorded as a notification defect and "
          "is reviewed with the late delivery, not instead of it."),
    ("p", "SP-5.9  The buyer does not chase a supplier for a date it has already confirmed. The "
          "weekly line in Schedule A is the chase."),

    ("h2", "SP-6  Quality release and inspection"),
    ("p", "SP-6.1  Goods-in inspection samples each carton for label accuracy, quantity and visible "
          "damage before release to stock."),
    ("p", "SP-6.2  A failed inspection is quarantined, and the supplier is told within one working "
          "day with photographs."),
    ("p", "SP-6.3  The supplier may ask for a re-inspection once. A second failure is recorded as a "
          "quality event and reviewed with the sourcing desk."),
    ("p", "SP-6.4  Inspection hold points for pilot parts are listed in Schedule B. A hold point is "
          "not skipped because a delivery is late."),
    ("p", "SP-6.5  Release to stock is recorded with the inspector label, the date and the carton "
          "count."),
    ("p", "SP-6.6  Scrap and rework costs are recorded against the order, not against the part "
          "number in general."),

    ("p", "SP-6.7  A defect that repeats on two consecutive deliveries is treated as a process "
          "defect. The supplier sends a short written cause note, and the note is filed with both "
          "inspections."),
    ("p", "SP-6.8  Inspection results are shared with the supplier that owns the delivery. They "
          "are not shared with other suppliers, and they are never used as a scoreboard across "
          "the supplier list."),

    ("h2", "SP-7  Records and retention"),
    ("p", "SP-7.1  Order records, inspection notes, photographs and approvals are kept for six years "
          "from the last credit note or the final delivery, whichever is later."),
    ("p", "SP-7.2  Records are kept in one place per order. Copies in personal mailboxes are not "
          "records and are deleted after the order closes."),
    ("p", "SP-7.3  A record is not edited after closure. A correction is added as a dated note."),
    ("p", "SP-7.4  Records are available to the internal audit on request, within two working days."),
    ("p", "SP-7.5  Records that name a supplier contact are reviewed when that contact leaves, so "
          "that the named person is not a stale entry in an open order."),

    ("h2", "SP-8  Escalation and remedies"),
    ("p", "SP-8.1  A delivery risk is raised with the supplier on the day it is identified, not at "
          "the committed date."),
    ("p", "SP-8.2  An unresolved risk is escalated to the sourcing lead after five working days."),
    ("p", "SP-8.3  Remedies are agreed in writing and name the quantity, the date and the party that "
          "carries the cost."),
    ("p", "SP-8.4  A remedy is not applied retroactively to an order that has already closed."),
    ("p", "SP-8.5  Repeated quality events are handled under the review process in SP-5.4 and "
          "SP-6.3, not as a separate penalty."),
    ("p", "SP-8.6  Escalation does not pause the inspection or the dock booking."),

    ("p", "SP-8.7  A supplier that disputes a record is asked to state the correction in "
          "writing, with the date and the order it refers to. The correction is added as a note "
          "and the original entry stays visible."),

    ("h2", "Schedule A  Weekly reporting template"),
    ("p", "Each active supplier sends one weekly line per open order: part number, ordered quantity, "
          "dispatched quantity, committed date, and one short note. The note states a fact, not a "
          "forecast. A supplier with nothing to report sends the line with the note 'no change'."),
    ("p", "The weekly line is due on the same working day each week. A line that arrives a day "
          "late is still recorded, with the arrival date, so that the pattern is visible over a "
          "quarter. The sourcing desk does not edit a supplier line. A correction is a new line "
          "that names the line it replaces."),
    ("p", "The template carries five columns and no free-text block. Anything longer than one "
          "short sentence belongs in an email, not in the weekly line."),

    ("h2", "Schedule B  Inspection hold points for pilot parts"),
    ("p", "Pilot parts are held at goods-in until the sample inspection passes. The hold point is "
          "recorded on the carton label. Parts released early under a written deviation are marked "
          "as released under deviation, and the deviation number is recorded on the order."),

    ("h2", "Schedule C  Late-source disclosure"),
    ("p", "SP-9.1  This schedule applies to every component whose origin is named on the order "
          "schedule, including components that are bought in rather than made by the supplier."),
    ("p", "SP-9.2  A change of origin after order confirmation must be disclosed before the "
          "component is dispatched. Disclosure after dispatch is recorded as a documentation "
          "failure and is reviewed with the sourcing lead."),
    ("p", "SP-9.3  Late-source disclosure. Where a supplier changes the origin of a component after "
          "order confirmation, the supplier must send a late-source disclosure to the sourcing desk "
          "within five working days of the change. The disclosure must quote the control code "
          "LT9-6205-SUP and must name both the previous source and the new source, with the "
          "effective date of the change."),
    ("p", "SP-9.4  The sourcing desk records the disclosure against the open order and decides "
          "whether the order may continue. A disclosure is not an approval, and it does not by "
          "itself change the committed date."),
    ("small", "End of synthetic sample pack."),
]

LONG_POLICY_FACTS = {
    "late_clause_id": "SP-9.3",
    "late_clause_key": "late-source disclosure",
    "control_code": "LT9-6205-SUP",
    "disclosure_deadline": "within five working days of the change",
    "schedule_heading": "Schedule C  Late-source disclosure",
    "word_count_target_min": 1500,
}


def build_long_docx() -> None:
    from docx import Document
    from docx.shared import Pt

    doc = Document()
    style = doc.styles["Normal"]
    style.font.name = "Helvetica"
    style.font.size = Pt(10.5)

    for kind, text in LONG_POLICY:
        if kind == "h1":
            doc.add_heading(text, level=1)
        elif kind == "h2":
            doc.add_heading(text, level=2)
        elif kind == "small":
            para = doc.add_paragraph(text)
            para.runs[0].italic = True
        else:
            doc.add_paragraph(text)

    doc.add_page_break()
    doc.add_heading("Schedule D  Contact and review record", level=2)
    doc.add_paragraph("SP-10.1  The sourcing desk keeps one contact per supplier, with a named "
                      "deputy. A contact change is recorded within one working day.")
    doc.add_paragraph("SP-10.2  Review dates are set at the start of each quarter and are not moved "
                      "to suit a late delivery.")
    doc.add_paragraph("SP-10.3  This synthetic sample pack ends here. It is not a real policy.")

    props = doc.core_properties
    props.author = "synthetic fixture builder"
    props.last_modified_by = "synthetic fixture builder"
    props.title = "Supplier Sourcing and Delivery Policy (synthetic sample)"
    props.subject = "Synthetic sample pack for product testing"
    props.comments = "Synthetic. No real company, supplier, policy or record."
    props.created = FIXED_TIME
    props.modified = FIXED_TIME
    props.last_printed = FIXED_TIME
    props.revision = 1
    props.keywords = "synthetic; sample; product testing"
    out = DOCS / "supplier-policy-long.docx"
    doc.save(out)
    normalise_zip(out)


def normalise_zip(path: Path) -> None:
    """Rewrite an OOXML package with fixed entry timestamps so the bytes are
    reproducible. Without this the zip local headers carry the wall clock and
    the SHA256SUMS manifest would change on every build."""
    import zipfile

    with zipfile.ZipFile(path) as src:
        items = [(info.filename, src.read(info.filename)) for info in src.infolist()]
    tmp = path.with_suffix(".tmp")
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as out:
        for name, data in items:
            info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o600 << 16
            out.writestr(info, data)
    tmp.replace(path)


def long_policy_word_count() -> int:
    """Count the words that are actually in the saved document, not a guess."""
    from docx import Document

    doc = Document(str(DOCS / "supplier-policy-long.docx"))
    return sum(len(p.text.split()) for p in doc.paragraphs)


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def main() -> None:
    for d in (TEXT, RICH, DOCS, IMAGES, PROMPTS, ROUTES):
        d.mkdir(parents=True, exist_ok=True)

    write_text(TEXT / "memo-en-pilot.md", SYNTHETIC_MD + MEMO_EN_BODY)
    write_text(TEXT / "memo-zh-pilot.md", SYNTHETIC_MD + MEMO_ZH_BODY)
    write_text(TEXT / "url-paragraph-canary.md", SYNTHETIC_MD + URL_PARAGRAPH_BODY)
    write_text(TEXT / "mixed-zh-en-note.md", SYNTHETIC_MD + MIXED_NOTE_BODY)
    write_text(TEXT / "unrelated-canary-notes.md", CANARY_NOTES_BODY)

    write_text(RICH / "richtext-target.rtf", build_rtf())
    write_text(RICH / "richtext-target.canonical.txt", canonical_text())
    write_json(RICH / "richtext-target.expected.json", rtf_expected())

    write_json(PROMPTS / "saved-prompt-digest-en.json", DIGEST_PROMPT)
    write_json(PROMPTS / "saved-prompt-zh-summary.json", ZH_PROMPT)
    write_json(PROMPTS / "saved-prompt-supplier-brief.json", BRIEF_PROMPT)
    write_json(ROUTES / "route-slots.json", ROUTE_SLOTS)

    pages = build_pdf_blocks(RETURNS_POLICY_PAGE_1) + build_pdf_blocks(
        RETURNS_POLICY_PAGE_2)
    if len(pages) != 2:
        raise SystemExit(
            "returns policy must render as exactly two pages, got " + str(len(pages))
        )

    build_chart()

    build_pdf(pages,
              DOCS / "returns-policy-2page.pdf", "Returns Policy (synthetic sample)")
    build_long_docx()

    facts = {
        "memo_en": MEMO_METRICS | {"word_count": memo_en_words()},
        "memo_zh": MEMO_ZH_FACTS,
        "url_paragraph": CANARY,
        "mixed_note": MIXED_NOTE_FACTS,
        "canary_notes": {"token": CANARY_NOTES_TOKEN},
        "richtext": {
            "target_paragraph": 3,
            "target_word_limit": 20,
            "surrounding_paragraphs": [1, 2, 4, 5, 6],
        },
        "chart": {
            "values": CHART_VALUES,
            "labels": CHART_LABELS,
            "total": CHART_TOTAL,
            "total_printed_on_chart": False,
            "dimensions": {"width": 1200, "height": 800},
            "colour": "monochrome (1-bit)",
        },
        "returns_policy_pdf": {
            "pages": 2,
            "late_clause_id": "RP-4.2",
            "late_clause_key": "more than 30 days after delivery",
            "control_code": "QX7-4418-RET",
            "restocking_charge": "15 percent of the invoiced value",
        },
        "supplier_policy_docx": LONG_POLICY_FACTS | {
            "word_count": long_policy_word_count(),
            "role": "long-source fidelity case, not a context-window stress test",
        },
        "toolchain": {
            "python": platform.python_version(),
            "pillow": PIL.__version__,
            "chart_font": "PIL bundled default bitmap font via ImageFont.load_default(size=); no system font file is read",
            "docx_writer": "python-docx, zip entry timestamps normalised to 2026-01-01 for byte stability",
            "pdf_writer": "hand-written PDF 1.4 with Helvetica base-14 fonts",
            "note": "PNG and PDF bytes depend on these versions; regenerate and compare SHA256SUMS after any toolchain change",
        },
    }
    write_json(FIXTURES / "fixture-facts.json", facts)

    print("root:", FIXTURES)
    print("memo_en words:", memo_en_words())
    print("long policy words:", facts["supplier_policy_docx"]["word_count"])
    print("chart total:", CHART_TOTAL)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=None,
                        help="write fixtures under this directory instead of in place")
    args = parser.parse_args()
    if args.output_dir is not None:
        set_root(args.output_dir.resolve())
    main()
