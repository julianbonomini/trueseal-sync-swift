#!/usr/bin/env python3
"""G12 parity check: the Swift SDK's exposed case names vs the core's
canonical Shared Facts (sync ADR-0028 / docs ADR-0003, gate G12).

Compares the `case` names of every public sum type in the Swift SDK against
the canonical lists in the vendored `Parity/shared-facts.json` (a byte-exact,
SHA-256-pinned copy of trueseal-sync's generated docs/shared-facts.json —
see Parity/README.md). ANY drift fails the build: a renamed, missing or
extra case, a missing source file, or a missing enum.

Usage:
  check-parity.py                 # compare, print a human report
  check-parity.py --report PATH   # also write the machine-readable report
                                  # (Release Evidence for the Conductor, G12)
  check-parity.py --self-test     # prove the check can fail: renamed /
                                  # missing / extra case fixtures must all
                                  # be caught (the negative test G12 needs)
  check-parity.py --facts PATH --sources-root PATH   # overrides (testing)

Pure stdlib; no network.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile

# Canonical list name -> (source file relative to the sources root, Swift enum).
# One row per canonical list in shared-facts.json. A core case that gains no
# Swift counterpart (or vice versa) fails the check — exactly the G12 gate.
ENUM_MAP = {
    "errors":               ("Sources/TruesealSync/TrueSealError.swift", "TrueSealError"),
    "events":               ("Sources/TruesealSync/Models.swift", "TrueSealEvent"),
    "statuses":             ("Sources/TruesealSync/Models.swift", "GroupStatus"),
    "statusReasons":        ("Sources/TruesealSync/Models.swift", "StatusReason"),
    "connectionStates":     ("Sources/TruesealSync/Models.swift", "ConnectionState"),
    "deliveryIssues":       ("Sources/TruesealSync/Models.swift", "DeliveryIssue"),
    "unreadableReasons":    ("Sources/TruesealSync/Models.swift", "UnreadableReason"),
    "sendFailedReasons":    ("Sources/TruesealSync/Models.swift", "SendFailedReason"),
    "admissionDropReasons": ("Sources/TruesealSync/Models.swift", "AdmissionDropReason"),
}

ENUM_DECL_RE = re.compile(r"\benum\s+([A-Za-z_][A-Za-z0-9_]*)\b")
CASE_LINE_RE = re.compile(r"^\s*case\s+(.+?)\s*(?://.*)?$")
IDENT_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)")


class ParityError(Exception):
    pass


def strip_comments(text):
    """Remove // line comments and /* */ block comments (strings in this
    codebase's enum declarations carry no comment-like literals; the enum
    bodies we parse are declarations only)."""
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    return text


def enum_body(text, enum_name):
    """Return the body text of `enum <enum_name>` (between its braces)."""
    for match in ENUM_DECL_RE.finditer(text):
        if match.group(1) != enum_name:
            continue
        brace = text.find("{", match.end())
        if brace == -1:
            raise ParityError(f"enum {enum_name}: declaration without a body")
        depth = 0
        for i in range(brace, len(text)):
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
                if depth == 0:
                    return text[brace + 1 : i]
        raise ParityError(f"enum {enum_name}: unbalanced braces")
    raise ParityError(f"enum {enum_name}: not found")


def case_names(body):
    """Top-level `case` identifiers declared directly in the enum body,
    one per comma-separated arm at paren depth 0. The body text excludes
    the enum's own braces, so its declarations sit at depth 0; anything
    deeper (a nested type's cases) is ignored."""
    names = []
    depth = 0
    for line in body.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("//") or stripped.startswith("///"):
            continue
        if depth == 0:
            m = CASE_LINE_RE.match(line)
            if m:
                arms = []
                buf = ""
                parens = 0
                for ch in m.group(1):
                    if ch == "(":
                        parens += 1
                    elif ch == ")":
                        parens -= 1
                    if ch == "," and parens == 0:
                        arms.append(buf)
                        buf = ""
                    else:
                        buf += ch
                arms.append(buf)
                for arm in arms:
                    ident = IDENT_RE.match(arm.strip())
                    if ident:
                        names.append(ident.group(1))
        depth += line.count("{") - line.count("}")
    return names


def sha256_file(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def compare(sources_root, facts_path):
    """Returns (ok, report_dict). Never raises for drift — drift is data;
    raises ParityError only for structural problems (missing files/enums)."""
    with open(facts_path, "rb") as fh:
        facts = json.load(fh)

    sections = []
    ok = True
    for list_name, (rel_path, enum_name) in ENUM_MAP.items():
        path = os.path.join(sources_root, rel_path)
        if not os.path.isfile(path):
            raise ParityError(f"source file missing: {rel_path}")
        canonical = facts.get(list_name)
        if canonical is None:
            raise ParityError(f"shared-facts.json has no '{list_name}' list")
        with open(path, "r", encoding="utf-8") as fh:
            source = strip_comments(fh.read())
        sdk = case_names(enum_body(source, enum_name))

        missing = [c for c in canonical if c not in sdk]
        extra = [s for s in sdk if s not in canonical]
        dupes = sorted({s for s in sdk if sdk.count(s) > 1})
        section_ok = not missing and not extra and not dupes
        ok = ok and section_ok
        sections.append(
            {
                "list": list_name,
                "enum": enum_name,
                "source": rel_path,
                "canonicalCount": len(canonical),
                "sdkCount": len(sdk),
                "missingInSdk": missing,
                "extraInSdk": extra,
                "duplicateInSdk": dupes,
                "ok": section_ok,
            }
        )

    report = {
        "check": "g12-sdk-parity",
        "sdk": "trueseal-sync-swift",
        "facts": {
            "path": os.path.relpath(facts_path),
            "sha256": sha256_file(facts_path),
            "sdkVersion": facts.get("sdkVersion"),
        },
        "sections": sections,
        "ok": ok,
    }
    return ok, report


def print_human(report):
    for s in report["sections"]:
        mark = "ok " if s["ok"] else "FAIL"
        line = f"[{mark}] {s['list']:<22} {s['enum']:<18} canonical={s['canonicalCount']} sdk={s['sdkCount']}"
        if not s["ok"]:
            detail = []
            if s["missingInSdk"]:
                detail.append("missing: " + ", ".join(s["missingInSdk"]))
            if s["extraInSdk"]:
                detail.append("extra: " + ", ".join(s["extraInSdk"]))
            if s["duplicateInSdk"]:
                detail.append("duplicate: " + ", ".join(s["duplicateInSdk"]))
            line += "  (" + "; ".join(detail) + ")"
        print(line)
    print(f"facts sha256: {report['facts']['sha256']} (sdkVersion {report['facts']['sdkVersion']})")
    print("G12 parity: " + ("PASS" if report["ok"] else "FAIL"))


def self_test(sources_root, facts_path):
    """The negative test G12 requires: the check MUST catch a renamed, a
    missing and an extra case. Each mutation is applied to a temp copy of
    the sources; every one must flip the verdict to FAIL (and the pristine
    tree must PASS, or this whole exercise is meaningless)."""
    ok, _ = compare(sources_root, facts_path)
    if not ok:
        print("self-test: FAIL — the pristine tree does not pass; nothing to mutate against")
        return False

    error_file = os.path.join(ENUM_MAP["errors"][0])
    with open(os.path.join(sources_root, error_file), "r", encoding="utf-8") as fh:
        original = fh.read()

    mutations = {
        "renamed case": original.replace(
            "case manifestVersionExhausted", "case manifestVersionExhaustedRenamed", 1
        ),
        "missing case": original.replace(
            "    case manifestVersionExhausted\n", "", 1
        ),
        "extra case": original.replace(
            "    case manifestVersionExhausted\n",
            "    case manifestVersionExhausted\n\n    case anExtraCaseTheCoreDoesNotHave\n",
            1,
        ),
    }

    all_caught = True
    for name, mutated in mutations.items():
        if mutated == original:
            print(f"self-test: FAIL — mutation '{name}' did not apply (source pattern drifted)")
            all_caught = False
            continue
        with tempfile.TemporaryDirectory() as tmp:
            shutil.copytree(sources_root, tmp, dirs_exist_ok=True)
            with open(os.path.join(tmp, error_file), "w", encoding="utf-8") as fh:
                fh.write(mutated)
            try:
                caught_ok, _ = compare(tmp, facts_path)
            except ParityError:
                caught_ok = False
        if caught_ok:
            print(f"self-test: FAIL — mutation '{name}' was NOT caught")
            all_caught = False
        else:
            print(f"self-test: mutation '{name}' correctly caught")
    return all_caught


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--facts", default="Parity/shared-facts.json")
    parser.add_argument("--sources-root", default=".")
    parser.add_argument("--report", default=None)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        sys.exit(0 if self_test(args.sources_root, args.facts) else 1)

    try:
        ok, report = compare(args.sources_root, args.facts)
    except ParityError as exc:
        print(f"G12 parity: FAIL — {exc}")
        sys.exit(1)

    print_human(report)
    if args.report:
        with open(args.report, "w", encoding="utf-8") as fh:
            json.dump(report, fh, indent=2)
            fh.write("\n")
        print(f"report written: {args.report}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
