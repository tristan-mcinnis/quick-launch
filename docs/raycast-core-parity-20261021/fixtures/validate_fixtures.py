#!/usr/bin/env python3
"""Validate the primary synthetic fixtures and the task manifest proposal.

Checks performed, all deterministic and offline:
  1. every JSON fixture parses and carries the required keys
  2. the English memo has ~320 words, exactly four numeric facts, two dates,
     four suppliers with two dates missing, three risks in stated order
  3. the Chinese memo carries both glossary terms and both dates
  4. the URL paragraph carries the CANARY_URL placeholder, a .invalid host and
     no other URL
  5. the RTF parses to the canonical text and to the expected per-run
     attributes (byte equality is never checked)
  6. the PDF is two pages, selectable, with clause IDs and one control code,
     and the T10 sentence appears exactly once
  7. the DOCX parses, is longer than 1,500 words, and carries the late-source
     clause and control code in the last part of the document
  8. the PNG is monochrome, 1200x800, and its facts match the fact index
  9. the saved-prompt definitions have the argument shape the tasks assume
 10. the task manifest covers T01-T22, every fixture reference exists, every
     fixture is used, and the call sums equal the declared budget
 11. SHA256SUMS and the per-fixture sha256 in the manifest match the bytes

Exit code 0 means every check passed. Any failure prints FAIL lines and exits 1.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

FIXTURES = Path(__file__).resolve().parent
MANIFEST = FIXTURES.parent / "task-manifest-proposal.json"
PRIVATE_BLACKLIST = FIXTURES.parents[2] / ".scrub-private"
REPO_ROOT = FIXTURES.parents[2]


def set_root(root: Path, manifest: Path | None = None) -> None:
    """Validate another copy (scratch rebuild or review snapshot)."""
    global FIXTURES, MANIFEST
    FIXTURES = root
    MANIFEST = manifest if manifest is not None else root.parent / "task-manifest-proposal.json"

FAILURES: list[str] = []
CHECKS = 0


def check(condition: bool, message: str) -> None:
    global CHECKS
    CHECKS += 1
    if not condition:
        FAILURES.append(message)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


# --------------------------------------------------------------------------
# RTF parsing
# --------------------------------------------------------------------------

def parse_rtf(raw: str) -> list[list[dict]]:
    paragraphs: list[list[dict]] = []
    runs: list[dict] = []
    state = {"bold": False, "italic": False, "underline": False, "size_pt": 11.0}
    stack: list[dict] = []
    buf: list[str] = []
    i = 0
    skip_depth = 0
    n = len(raw)

    def flush() -> None:
        if buf:
            text = "".join(buf)
            if text:
                runs.append({"text": text, **state})
            buf.clear()

    while i < n:
        ch = raw[i]
        if skip_depth:
            if ch == "{":
                skip_depth += 1
            elif ch == "}":
                skip_depth -= 1
            i += 1
            continue
        if ch == "{":
            if raw.startswith("{\\fonttbl", i) or raw.startswith("{\\*", i):
                skip_depth = 1
                i += 1
                continue
            flush()
            stack.append(dict(state))
            i += 1
            continue
        if ch == "}":
            flush()
            if stack:
                state = stack.pop()
            i += 1
            continue
        if ch == "\\":
            m = re.match(r"\\([a-zA-Z]+)(-?\d+)?", raw[i:])
            if m:
                word, param = m.group(1), m.group(2)
                i += m.end()
                if raw[i:i + 1] == " ":
                    i += 1
                if word == "par":
                    flush()
                    paragraphs.append(runs)
                    runs = []
                elif word in ("b", "i", "ul"):
                    on = param != "0"
                    key = {"b": "bold", "i": "italic", "ul": "underline"}[word]
                    state[key] = on
                elif word == "fs" and param is not None:
                    state["size_pt"] = int(param) / 2
                continue
            if raw[i:i + 2] in ("\\{", "\\}", "\\\\"):
                buf.append(raw[i + 1])
                i += 2
                continue
            i += 1
            continue
        if ch in "\r\n":
            i += 1
            continue
        buf.append(ch)
        i += 1

    flush()
    if runs:
        paragraphs.append(runs)
    return [p for p in paragraphs if "".join(r["text"] for r in p).strip()]


# --------------------------------------------------------------------------
# Checks
# --------------------------------------------------------------------------

def check_text_fixtures(facts: dict) -> None:
    memo_path = FIXTURES / "text/memo-en-pilot.md"
    memo = memo_path.read_text(encoding="utf-8")
    body = memo.split("-->\n\n", 1)[1]
    words = len(body.split())
    check(300 <= words <= 340, f"memo word count {words} not in 300..340")

    date_spans = re.findall(r"20\d\d-\d\d-\d\d", body)
    body_without_dates = body
    for span in date_spans:
        body_without_dates = body_without_dates.replace(span, "DATE")
    digits = re.findall(r"\d[\d,]*", body_without_dates)
    non_date = digits
    check(sorted(set(non_date)) == sorted(["1,240", "18", "6", "2"]),
          f"memo numeric facts are {sorted(set(non_date))}, expected 1,240/18/6/2")
    check(sorted(set(date_spans)) == ["2026-11-14", "2026-12-03"],
          f"memo dates are {sorted(set(date_spans))}")
    check("Supplier A" in body and "Supplier B" in body, "memo missing supplier A or B")
    check("Suppliers C and D" in body, "memo missing the unstated-date suppliers C and D")
    check(body.count("Supplier A has committed delivery on 2026-11-14") == 1,
          "supplier A date sentence missing or duplicated")
    check(body.count("Supplier B has committed delivery on 2026-12-03") == 1,
          "supplier B date sentence missing or duplicated")
    for key in ("Risk, highest:", "Risk, middle:", "Risk, lowest:"):
        check(key in body, f"memo missing ordered risk marker {key}")
    order = [body.index("Risk, highest:"), body.index("Risk, middle:"),
             body.index("Risk, lowest:")]
    check(order == sorted(order), "memo risk markers are out of order")
    check("not confirmed a delivery date" in body, "memo missing unstated-date wording")

    zh = (FIXTURES / "text/memo-zh-pilot.md").read_text(encoding="utf-8")
    for term in ("供应链", "复购率"):
        check(zh.count(term) >= 1, f"ZH memo missing glossary term {term}")
    for date in ("2026-11-14", "2026-12-03"):
        check(date in zh, f"ZH memo missing date {date}")
    check("800" in zh, "ZH memo missing unit count 800")

    url_para = (FIXTURES / "text/url-paragraph-canary.md").read_text(encoding="utf-8")
    check("CANARY_URL" in url_para, "URL paragraph missing CANARY_URL placeholder")
    urls = re.findall(r"https?://[^\s)]+", url_para)
    check(urls == ["https://canary-url.invalid/memo-2026"], f"unexpected URLs: {urls}")
    check(".invalid" in url_para, "URL paragraph host is not .invalid")

    mixed = (FIXTURES / "text/mixed-zh-en-note.md").read_text(encoding="utf-8")
    for token in ("SKU-A12", "SKU-B7", "MOQ", "600 pcs", "Q3", "2 days", "5 days"):
        check(token in mixed, f"mixed note missing token {token}")

    notes = (FIXTURES / "text/unrelated-canary-notes.md").read_text(encoding="utf-8")
    check("NOTE-CANARY-4471" in notes, "canary note missing its token")
    check("desk booking" in notes.lower(), "canary note is not plausibly unrelated office material")


def check_richtext(facts: dict) -> None:
    rtf_raw = (FIXTURES / "richtext/richtext-target.rtf").read_text(encoding="utf-8")
    expected = json.loads((FIXTURES / "richtext/richtext-target.expected.json").read_text())
    canonical = (FIXTURES / "richtext/richtext-target.canonical.txt").read_text()

    paragraphs = parse_rtf(rtf_raw)
    check(len(paragraphs) == 6, f"RTF parsed to {len(paragraphs)} paragraphs, expected 6")

    parsed_text = "\n".join("".join(r["text"] for r in p) for p in paragraphs) + "\n"
    check(parsed_text == canonical, "RTF text does not match the canonical text file")

    for exp, got in zip(expected["paragraphs"], paragraphs):
        exp_text = exp["text"]
        got_text = "".join(r["text"] for r in got)
        check(exp_text == got_text, f"paragraph {exp['index']} text mismatch")
        got_attrs = [(r["text"], r["bold"], r["italic"], r["underline"], r["size_pt"])
                     for r in got]
        exp_attrs = [(r["text"], r["bold"], r["italic"], r["underline"], r["size_pt"])
                     for r in exp["runs"]]
        check(exp_attrs == got_attrs,
              f"paragraph {exp['index']} run attributes differ: {got_attrs}")

    sel = expected["target_selection"]
    check(canonical[sel["start_offset"]:sel["end_offset"]] == sel["text"],
          "target selection offsets do not slice the stated target text")
    check(sel["paragraph_index"] == 3, "target paragraph is not paragraph 3")
    check("not a criterion" in expected["criterion_note"].lower(),
          "expected manifest must state that byte-identical RTF is not a criterion")


def check_pdf(facts: dict) -> None:
    pdf = FIXTURES / "documents/returns-policy-2page.pdf"
    raw = pdf.read_bytes()
    check(raw.startswith(b"%PDF-1.4"), "PDF header missing")
    check(raw.count(b"/Type /Page ") == 2, "PDF is not exactly two pages")
    proc = subprocess.run(["pdftotext", "-layout", str(pdf), "-"],
                          capture_output=True, text=True)
    check(proc.returncode == 0, f"pdftotext failed: {proc.stderr}")
    text = proc.stdout
    check(text.count("\f") <= 2, "PDF has more than two text pages")

    clause_ids = set(re.findall(r"RP-\d\.\d", text))
    check(len(clause_ids) >= 20, f"PDF exposes only {len(clause_ids)} clause IDs")
    for cid in ("RP-1.1", "RP-4.2", "RP-9.3"):
        check(cid in clause_ids, f"PDF missing clause {cid}")

    target = ("A return requested more than 30 days after delivery is accepted only with "
              "written exception approval from the returns desk.")
    flat = re.sub(r"\s+", " ", text)
    check(flat.count(target) == 1, "T10 target sentence is not present exactly once")
    check(text.count("QX7-4418-RET") == 1, "PDF control code missing or duplicated")
    check("15 percent" in flat, "PDF restocking charge missing")
    check("Synthetic sample" in text, "PDF is not labelled as a synthetic sample")
    # selectability: real text, not an image of text
    check(len(flat.split()) > 550, "PDF text layer is too thin to be selectable content")


def check_docx(facts: dict) -> None:
    from docx import Document

    docx = FIXTURES / "documents/supplier-policy-long.docx"
    doc = Document(str(docx))
    text = "\n".join(p.text for p in doc.paragraphs)
    words = len(text.split())
    check(words >= 1500, f"long DOCX has {words} words, expected >= 1500")
    check("SP-9.3" in text, "long DOCX missing late-source clause SP-9.3")
    check(text.count("LT9-6205-SUP") == 1, "long DOCX control code missing or duplicated")
    check("within five working days of the change" in text,
          "long DOCX missing the disclosure deadline")
    pos = text.find("Schedule C  Late-source disclosure")
    check(pos > 0, "long DOCX missing Schedule C heading")
    check(pos / max(len(text), 1) > 0.75,
          "late-source clause is not late in the document")
    check(text.count("SP-") >= 40, "long DOCX does not carry a realistic clause set")
    repeated = max(text.count(p.text) for p in doc.paragraphs if len(p.text.split()) > 12)
    check(repeated <= 2, "long DOCX repeats a paragraph more than twice")
    check(doc.core_properties.title.startswith("Supplier Sourcing"),
          "DOCX core properties not set by the fixture builder")


def check_image(facts: dict) -> None:
    from PIL import Image

    png = FIXTURES / "images/chart-monochrome.png"
    with Image.open(png) as img:
        check(img.size == (1200, 800), f"chart size is {img.size}")
        check(img.mode == "1", f"chart mode is {img.mode}, expected 1-bit monochrome")
        colours = img.convert("L").getcolors(maxcolors=8)
        check(colours is not None and len(colours) <= 2,
              f"chart has {colours and len(colours)} tones, expected pure monochrome")
    chart = facts["chart"]
    check(chart["values"] == [12, 27, 9, 34], "chart values in facts are not 12/27/9/34")
    check(chart["total"] == 82, "chart total in facts is not 82")
    check(chart["total_printed_on_chart"] is False, "chart must not print its total")


def check_prompts(facts: dict) -> None:
    digest = json.loads((FIXTURES / "prompts/saved-prompt-digest-en.json").read_text())
    args = digest["arguments"]
    check(len(args) == 3, "digest prompt does not have three named arguments")
    check(all(a["default"] for a in args), "digest prompt arguments must all have defaults")
    check(digest["body"].count("{{") == 3, "digest body does not reference three arguments")
    for name in ("audience", "tone", "length"):
        check("{{%s}}" % name in digest["body"], f"digest body missing {{{{{name}}}}}")
        check(any(a["name"] == name for a in args), f"digest arguments missing {name}")

    zh = json.loads((FIXTURES / "prompts/saved-prompt-zh-summary.json").read_text())
    check(zh.get("requires_selection") is True, "ZH prompt must require a selection")
    check(zh["title"] == "中文摘要", "ZH prompt title mismatch")

    brief = json.loads((FIXTURES / "prompts/saved-prompt-supplier-brief.json").read_text())
    required = [a for a in brief["arguments"] if a["required"]]
    check(len(required) == 1 and required[0]["default"] is None,
          "supplier brief must have exactly one required argument with no default")

    routes = json.loads((FIXTURES / "routes/route-slots.json").read_text())
    slots = {s["slot"]: s for s in routes["route_slots"]}
    check(set(slots) == {"route-default", "route-alt", "route-unreachable"},
          f"unexpected route slots: {sorted(slots)}")
    check(slots["route-unreachable"]["endpoint"] == "http://127.0.0.1:9/v1",
          "unreachable endpoint is not the declared discard-port endpoint")


def check_manifest(facts: dict) -> None:
    manifest = json.loads(MANIFEST.read_text())
    tasks = manifest["tasks"]
    ids = [t["id"] for t in tasks]
    check(ids == ["T%02d" % n for n in range(1, 23)], f"task ids are {ids}")
    check(manifest["status"].startswith("PROPOSED"), "manifest must not claim to be frozen")

    total = 0
    for task in tasks:
        check(bool(task.get("prompt") or task.get("turns") or task.get("cases")
                   or task.get("scenarios")),
              f"{task['id']} has no prompt, turns, cases or scenarios")
        check(task["domain"].split("/")[0] in manifest["domains"],
              f"{task['id']} domain {task['domain']} is not in the domain list")
        for ref in task.get("input_refs", []):
            check((FIXTURES / ref).exists(), f"{task['id']} references missing fixture {ref}")
        check(len(task.get("expected_criteria", [])) >= 1,
              f"{task['id']} has no expected criteria")
        calls = task.get("calls")
        if calls is None:
            calls = sum(c.get("calls", 0) for c in task.get("cases", []))
        if "cases" in task:
            check(calls == sum(c["calls"] for c in task["cases"]),
                  f"{task['id']} case calls do not sum to its total")
        if "turns" in task:
            submits = sum(t.get("submits", 0) for t in task["turns"])
            check(calls == submits,
                  f"{task['id']} turn submits {submits} != calls {calls}")
        if "scenarios" in task:
            check(calls == sum(s["calls"] for s in task["scenarios"]),
                  f"{task['id']} scenario calls do not sum")
        total += calls

    check(total == manifest["primary_call_total"],
          f"recalculated primary calls {total} != declared {manifest['primary_call_total']}")

    budget = manifest["budget"]["allocation"]
    check(sum(budget.values()) == manifest["budget"]["per_app_submitted_turns_allowed"],
          "budget allocation does not sum to the permitted 60 turns")
    check(budget["primary"] == total, "budget primary does not equal the task call sum")

    repeats = manifest["repeats"]
    repeat_total = (sum(r["calls"] for r in repeats["timing"])
                    + sum(r["calls"] for r in repeats["safety"]))
    check(repeat_total == repeats["total_calls"] == budget["repeated_timing_and_safety"],
          "repeat call counts do not match the budget block")
    for group in ("timing", "safety"):
        for rep in repeats[group]:
            check(rep["task"] in ids, f"repeat {rep['id']} points at unknown task")

    holdout = manifest["holdout"]
    check(holdout["calls"] == budget["holdout"], "holdout calls do not match the budget")
    covered = set()
    for domain, variants in holdout["coverage"].items():
        check(domain in manifest["domains"], f"holdout coverage names unknown domain {domain}")
        covered.update(variants)
    check(len(covered) == holdout["variant_count"],
          f"holdout coverage names {len(covered)} variants, declared {holdout['variant_count']}")
    check(sorted(holdout["coverage"]) == sorted(manifest["domains"]),
          "holdout coverage does not span all seven domains")

    holdout_manifest_path = FIXTURES / "holdout-manifest.json"
    if holdout_manifest_path.exists():
        hm = json.loads(holdout_manifest_path.read_text())
        check(len(hm["variants"]) == holdout["variant_count"],
              "holdout manifest variant count mismatch")
        check(sum(v["calls"] for v in hm["variants"]) == holdout["calls"],
              "holdout manifest call sum mismatch")
        for variant in hm["variants"]:
            digest = variant.get("artifact_sha256") or variant.get("sha256") or ""
            check(len(digest) == 64 and all(c in "0123456789abcdef" for c in digest),
                  f"{variant['id']} has no valid sha256 hash")
            check(variant["file_count"] >= 1, f"{variant['id']} declares no asset files")
            check("prompt" not in variant, f"{variant['id']} leaks its prompt")
        check(hm.get("contents_public") is False, "holdout manifest must not publish contents")

    check((FIXTURES / "generate" / "generate-primary-fixtures.py").exists(),
          "the generator must live in generate/, which Git does not ignore")
    check(not (FIXTURES / "build").exists(),
          "fixtures/build/ is ignored by this repository: the generator must not live there")

    repeat_ids = {r["id"] for group in ("timing", "safety") for r in repeats[group]}
    known_refs = set(ids) | repeat_ids | {"ALL"}
    for entry in manifest["fixtures"]:
        unknown = set(entry["used_by"]) - known_refs
        check(not unknown,
              f"fixture {entry['id']} names unknown task or repeat references")

    used = set()
    for task in tasks:
        for ref in task.get("input_refs", []):
            used.add(ref)
        for case in task.get("cases", []):
            used.update(case.get("input_refs", []))
    declared = {f["path"] for f in manifest["fixtures"]}
    for entry in manifest["fixtures"]:
        check({"id", "path", "role", "used_by"} <= set(entry),
              f"fixture entry {entry.get('id')} is missing keys")
    check(len(declared) == manifest["fixture_units"]["count"],
          f"declared fixture files {len(declared)} != fixture_units {manifest['fixture_units']['count']}")
    for path in declared:
        check((FIXTURES / path).exists(), f"declared fixture {path} does not exist")
    for path in declared - {"fixture-facts.json"}:
        check(path in used, f"fixture {path} is declared but not used by any task")
    for path in used:
        check((FIXTURES / path).exists(), f"task reference {path} does not exist")

    # hashes in the manifest, when present, must match the bytes
    for entry in manifest["fixtures"]:
        if "sha256" in entry:
            actual = sha256(FIXTURES / entry["path"])
            check(entry["sha256"] == actual, f"sha256 mismatch for {entry['path']}")
            check(entry["bytes"] == (FIXTURES / entry["path"]).stat().st_size,
                  f"byte size mismatch for {entry['path']}")


def check_sums_file() -> None:
    sums = FIXTURES / "SHA256SUMS"
    check(sums.exists(), "SHA256SUMS is missing")
    listed = {}
    for line in sums.read_text().splitlines():
        if not line.strip():
            continue
        digest, path = line.split("  ", 1)
        listed[path] = digest
    on_disk = {}
    for path in sorted(FIXTURES.rglob("*")):
        if not path.is_file():
            continue
        rel = str(path.relative_to(FIXTURES))
        if rel == "SHA256SUMS" or "__pycache__" in path.parts or path.suffix == ".pyc":
            continue
        on_disk[rel] = sha256(path)
    check(set(listed) == set(on_disk),
          f"SHA256SUMS lists {sorted(set(listed) ^ set(on_disk))} differently from disk")
    for path, digest in on_disk.items():
        check(listed.get(path) == digest, f"SHA256SUMS digest mismatch for {path}")
    check(len(on_disk) >= 16, f"SHA256SUMS covers only {len(on_disk)} files")


def check_no_forbidden_content() -> None:
    """Generic, publishable patterns only.

    Client, colleague and employer names are NOT listed here: this file is
    tracked and must never carry the private list. They come from the
    untracked .scrub-private file when it exists, and from scripts/scrub.sh at
    publish time. Matched names are never printed, only a count.
    """
    generic = [b"Raycast", b"DeepSeek", b"OpenAI", b"Anthropic", b"SKIP_TESTS",
               b"api_key", b"PRIVATE " + b"KEY", b"BEGIN " + b"RSA" + b" PRIVATE KEY"]
    home = b"/" + b"Users" + b"/"
    binaries = {".pdf", ".docx", ".png"}
    scanned = 0
    skip_names = {"SHA256SUMS", Path(__file__).name}
    for path in sorted(FIXTURES.rglob("*")):
        if not path.is_file() or path.name in skip_names:
            continue
        if "__pycache__" in path.parts or path.suffix == ".pyc":
            continue
        if "generate" in path.parts:
            continue
        raw = path.read_bytes()
        scanned += 1
        label = path.name
        for token in generic:
            check(token not in raw, f"{label} contains a forbidden vendor or key token")
        # PDF and DOCX bytes are text-bearing; a PNG is compressed, so it is
        # checked for the generic tokens above but not relied on for prose.
        if path.suffix not in binaries or path.suffix in (".pdf", ".docx"):
            check(home not in raw, f"{label} contains an absolute home path")
        if path.suffix in (".md", ".json", ".txt", ".rtf"):
            text = raw.decode("utf-8", errors="replace")
            house_markers = ["~/" + "vault", "vault" + "-vps", "vault" + "-private"]
            check(not any(marker in text for marker in house_markers),
                  f"{label} contains a private house path")
    check(scanned >= 16, f"forbidden scan covered only {scanned} files")

    if PRIVATE_BLACKLIST.exists():
        patterns = [ln.strip() for ln in PRIVATE_BLACKLIST.read_text().splitlines()
                    if ln.strip() and not ln.strip().startswith("#")]
        if patterns:
            rx = re.compile("|".join(patterns), re.IGNORECASE)
            hits = 0
            for path in sorted(FIXTURES.rglob("*")):
                if not path.is_file() or path.name in skip_names:
                    continue
                if "__pycache__" in path.parts or path.suffix == ".pyc":
                    continue
                if "generate" in path.parts:
                    continue
                if rx.search(path.read_bytes().decode("utf-8", errors="replace")):
                    hits += 1
            check(hits == 0,
                  f"private blacklist matched in {hits} candidate file(s); names withheld "
                  f"(run scripts/scrub.sh for the publish gate)")
        print(f"private blacklist: {len(patterns)} patterns loaded from the untracked file")
    else:
        print("private blacklist: not present; private tokens are left to scripts/scrub.sh")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=None,
                       help="validate a copy of the fixtures at this path")
    parser.add_argument("--manifest", type=Path, default=None)
    parser.add_argument("--private-blacklist", type=Path, default=None,
                       help="untracked regex list; defaults to the repository .scrub-private")
    args = parser.parse_args()
    if args.root is not None:
        set_root(args.root.resolve(), args.manifest.resolve() if args.manifest else None)
    if args.private_blacklist is not None:
        globals()["PRIVATE_BLACKLIST"] = args.private_blacklist.resolve()

    facts = json.loads((FIXTURES / "fixture-facts.json").read_text())
    check_text_fixtures(facts)
    check_richtext(facts)
    check_pdf(facts)
    check_docx(facts)
    check_image(facts)
    check_prompts(facts)
    check_manifest(facts)
    check_sums_file()
    check_no_forbidden_content()

    print(f"checks run: {CHECKS}")
    if FAILURES:
        print(f"FAIL ({len(FAILURES)})")
        for failure in FAILURES:
            print(" -", failure)
        return 1
    print("PASS: all primary fixture and manifest checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
