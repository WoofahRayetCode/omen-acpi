#!/usr/bin/env python3
#
# Copyright (C) 2026 Paolo De Marinis
# SPDX-License-Identifier: GPL-3.0-or-later
#
"""Audit an ACPI symbol in the DSDT collected by the OMEN ACPI Toolkit.

It answers one question: does writing NVDE = 1 during _PTS have an observable
effect on this machine, or is it inert?

The script changes nothing. It only reads.

Usage:
    ./nvde-audit.py                      # looks for ~/omen-*acpi-source-*.tar.gz
    ./nvde-audit.py archive.tar.gz
    ./nvde-audit.py dsdt.dsl
    ./nvde-audit.py --symbol OMPR dsdt.dsl
"""

from __future__ import annotations

import argparse
import re
import sys
import tarfile
import tempfile
from collections import Counter, deque
from pathlib import Path


def strip_comments(text: str) -> str:
    # Block comments are replaced by as many newlines as they contained,
    # otherwise the reported line numbers would not match the original file.
    text = re.sub(
        r"/\*.*?\*/",
        lambda match: "\n" * match.group(0).count("\n"),
        text,
        flags=re.DOTALL,
    )
    # Every line keeps its own terminator: a plain join would drop a trailing
    # empty line and misreport the total.
    return "".join(line.split("//")[0] + "\n" for line in text.splitlines())


def collect_all_sources(argument: str | None) -> list[tuple[str, str]]:
    """Return [(label, text)] for every .dsl/.asl found in the source."""
    if argument:
        source = Path(argument).expanduser()
    else:
        archives = sorted(
            Path.home().glob("omen-*acpi-source-*.tar.gz"),
            key=lambda path: path.stat().st_mtime,
            reverse=True,
        )
        if not archives:
            raise SystemExit("no ~/omen-*acpi-source-*.tar.gz archive found.")
        source = archives[0]

    def read_all(root: Path, prefix: str) -> list[tuple[str, str]]:
        found = sorted(list(root.rglob("*.dsl")) + list(root.rglob("*.asl")))
        return [
            (f"{prefix}{path.name}", path.read_text(encoding="utf-8", errors="replace"))
            for path in found
        ]

    if source.is_file() and source.name.endswith((".tar.gz", ".tgz")):
        with tempfile.TemporaryDirectory() as temporary:
            with tarfile.open(source, mode="r:gz") as archive:
                for member in archive.getmembers():
                    member_path = Path(member.name)
                    if member_path.is_absolute() or ".." in member_path.parts:
                        raise SystemExit(f"unsafe path: {member.name}")
                archive.extractall(temporary)
            return read_all(Path(temporary), f"{source.name} -> ")
    if source.is_dir():
        return read_all(source, "")
    return [(source.name, source.read_text(encoding="utf-8", errors="replace"))]


def load_source(argument: str | None) -> tuple[str, str]:
    """Return (source_label, asl_text)."""
    if argument:
        source = Path(argument).expanduser()
        if not source.exists():
            raise SystemExit(f"source does not exist: {source}")
    else:
        home = Path.home()
        archives = sorted(
            home.glob("omen-*acpi-source-*.tar.gz"),
            key=lambda path: path.stat().st_mtime,
            reverse=True,
        )
        if not archives:
            raise SystemExit(
                "no ~/omen-*acpi-source-*.tar.gz archive found.\n"
                "Pass a .tar.gz, a directory or a .dsl file explicitly."
            )
        source = archives[0]

    def biggest_dsl(root: Path) -> Path:
        found = sorted(root.rglob("*.dsl"))
        if not found:
            raise SystemExit(f"no .dsl file inside {root}")
        return max(found, key=lambda path: path.stat().st_size)

    if source.is_file() and source.name.endswith((".tar.gz", ".tgz")):
        with tempfile.TemporaryDirectory() as temporary:
            with tarfile.open(source, mode="r:gz") as archive:
                for member in archive.getmembers():
                    member_path = Path(member.name)
                    if member_path.is_absolute() or ".." in member_path.parts:
                        raise SystemExit(f"unsafe path in archive: {member.name}")
                    if not (member.isfile() or member.isdir()):
                        raise SystemExit(f"non-regular member in archive: {member.name}")
                archive.extractall(temporary)
            best = biggest_dsl(Path(temporary))
            return f"{source}  ->  {best.name}", best.read_text(encoding="utf-8", errors="replace")

    if source.is_dir():
        best = biggest_dsl(source)
        return str(best), best.read_text(encoding="utf-8", errors="replace")

    return str(source), source.read_text(encoding="utf-8", errors="replace")


def matching_brace(text: str, opening: int) -> int:
    depth = 0
    position = opening
    while position < len(text):
        character = text[position]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return position
        position += 1
    return len(text) - 1


def index_methods(text: str) -> list[tuple[str, int, int]]:
    """[(name, first_line, last_line)], 0-based, tolerant of single-line methods."""
    methods: list[tuple[str, int, int]] = []

    for match in re.finditer(r"^[ \t]*Method\s*\(\s*(\\?[A-Za-z0-9_.\\]+)", text, re.MULTILINE):
        name = match.group(1).split(".")[-1].lstrip("\\")

        # Skip ahead to the brace that opens the body, leaving the argument list.
        position = match.end()
        paren_depth = 1
        while position < len(text):
            character = text[position]
            if character == "(":
                paren_depth += 1
            elif character == ")":
                paren_depth -= 1
            elif character == "{" and paren_depth <= 0:
                break
            position += 1
        if position >= len(text):
            continue

        closing = matching_brace(text, position)
        methods.append(
            (
                name,
                text.count("\n", 0, match.start()),
                text.count("\n", 0, closing),
            )
        )
    return methods


def enclosing_method(methods: list[tuple[str, int, int]], line_number: int) -> str:
    best: tuple[str, int] | None = None
    for name, start, end in methods:
        if start <= line_number <= end:
            span = end - start
            if best is None or span < best[1]:
                best = (name, span)
    return best[0] if best else "<global scope>"


def store_argument_pairs(line: str) -> list[tuple[str, str]]:
    """Extract (value, destination) from every Store (...) present on the line."""
    pairs: list[tuple[str, str]] = []

    for match in re.finditer(r"(?<![A-Za-z0-9_])Store\s*\(", line):
        position = match.end()
        start = position
        depth = 1
        while position < len(line):
            character = line[position]
            if character == "(":
                depth += 1
            elif character == ")":
                depth -= 1
                if depth == 0:
                    break
            position += 1
        inner = line[start:position]

        depth = 0
        split_at = -1
        for offset, character in enumerate(inner):
            if character in "([":
                depth += 1
            elif character in ")]":
                depth -= 1
            elif character == "," and depth == 0:
                split_at = offset
        if split_at != -1:
            pairs.append((inner[:split_at], inner[split_at + 1 :]))
    return pairs


class Symbol:
    def __init__(self, name: str) -> None:
        self.name = name
        self.reference = re.compile(
            r"(?<![A-Za-z0-9_.\\])(?:\\?[A-Za-z_][A-Za-z0-9_]*\.)*" + name + r"(?![A-Za-z0-9_])"
        )
        self.declare_name = re.compile(r"^\s*Name\s*\(\s*\\?[A-Za-z0-9_.\\]*" + name + r"\s*,")
        self.declare_field = re.compile(r"^\s*" + name + r"\s*,\s*(?:\d+|0x[0-9A-Fa-f]+)\s*,?\s*$")
        self.assignment = re.compile(
            r"^\s*(?:\\?[A-Za-z_][A-Za-z0-9_]*\.)*" + name + r"\s*(?:\+|-|\*|/|\||&|\^|<<|>>)?=(?!=)"
        )
        self.read_modify = re.compile(
            r"(?:Increment|Decrement)\s*\(\s*(?:\\?[A-Za-z_][A-Za-z0-9_]*\.)*" + name + r"\s*\)"
        )


def classify(line: str, symbol: Symbol) -> set[str]:
    if symbol.declare_name.match(line) or symbol.declare_field.match(line):
        return {"declaration"}
    if symbol.read_modify.search(line):
        return {"read", "write"}

    kinds: set[str] = set()

    if symbol.assignment.match(line):
        kinds.add("write")
        remainder = line.split("=", 1)[1]
        if symbol.reference.search(remainder):
            kinds.add("read")
        return kinds

    pairs = store_argument_pairs(line)
    if pairs:
        residual = line
        for value, destination in pairs:
            if symbol.reference.search(destination):
                kinds.add("write")
            if symbol.reference.search(value):
                kinds.add("read")
            residual = residual.replace(value, " ").replace(destination, " ")
        # A reference outside every Store on the same line is still a read.
        if symbol.reference.search(residual):
            kinds.add("read")
        if kinds:
            return kinds

    return {"read"}


def declaration_kind(lines: list[str], symbol: Symbol) -> tuple[str, int | None, str]:
    """Tell a global Name apart from an OperationRegion field."""
    field_region: str | None = None
    field_depth = 0

    for number, line in enumerate(lines):
        field_match = re.match(r"^\s*(?:Bank|Index)?Field\s*\(\s*(\w+)", line)
        if field_match:
            field_region = field_match.group(1)
            field_depth = 0

        if field_region is not None:
            field_depth += line.count("{") - line.count("}")
            if field_depth < 0 or (field_depth == 0 and "}" in line):
                field_region = None

        if symbol.declare_field.match(line) and field_region:
            return ("OperationRegion field", number, f"inside region {field_region}")
        if symbol.declare_name.match(line):
            return ("global Name", number, "plain namespace variable")

    return ("not declared", None, "")


def external_methods(text: str) -> set[str]:
    """Methods declared External: their body lives in another table."""
    return {
        match.group(1).split(".")[-1].lstrip("\\")
        for match in re.finditer(
            r"^\s*External\s*\(\s*(\\?[A-Za-z0-9_.\\]+)\s*,\s*MethodObj",
            text,
            re.MULTILINE,
        )
    }


def build_call_graph(text: str, methods: list[tuple[str, int, int]]) -> dict[str, set[str]]:
    lines = text.splitlines()
    names = {name for name, _, _ in methods}
    # External methods are leaf nodes: reachable, but with a body that cannot be
    # inspected from this file. Omitting them would make a path look closed when
    # it actually continues in another table.
    externals = external_methods(text) - names
    graph: dict[str, set[str]] = {name: set() for name in names | externals}
    call = re.compile(
        r"(?<![A-Za-z0-9_])(?:\\?[A-Za-z_][A-Za-z0-9_]*\.)*([A-Za-z_][A-Za-z0-9_]{0,3})\s*\("
    )

    for name, start, end in methods:
        body = "\n".join(lines[start : end + 1])
        for candidate in call.findall(body):
            if candidate in graph and candidate != name:
                graph[name].add(candidate)
    return graph


def reachable_from(graph: dict[str, set[str]], origin: str) -> dict[str, list[str]]:
    if origin not in graph:
        return {}
    paths = {origin: [origin]}
    queue = deque([origin])
    while queue:
        current = queue.popleft()
        for following in sorted(graph.get(current, ())):
            if following not in paths:
                paths[following] = paths[current] + [following]
                queue.append(following)
    return paths


SELF_TEST_ASL = """\
DefinitionBlock ("", "DSDT", 2, "X", "Y", 0x1)
{
    External (APTS, MethodObj)
    Name (NVDE, Zero)
    Method (_PTS, 1, NotSerialized)
    {
        MPTS (Arg0)   /* comment */
        APTS (Arg0)
        \\_SB.PCI0.GPP0.PEGP._PS3 ()
    }
    Method (MPTS, 1, NotSerialized) { Store (One, NVDE) }
    Method (_PS3, 0, NotSerialized) { Return (Zero) }
    Method (_PS3, 0, NotSerialized) { Return (One) }
    Method (GM22, 0, NotSerialized) { If (LEqual (NVDE, One)) { Return (One) } }
}
"""


def self_test() -> int:
    text = strip_comments(SELF_TEST_ASL)
    assert len(text.splitlines()) == len(SELF_TEST_ASL.splitlines()), "line numbers drifted"
    assert "comment" not in text, "block comment was not stripped"

    symbol = Symbol("NVDE")
    methods = index_methods(text)
    names = Counter(name for name, _, _ in methods)
    assert names["_PS3"] == 2, names
    assert names["_PTS"] == 1, names

    kinds = [
        classify(line, symbol)
        for line in text.splitlines()
        if symbol.reference.search(line)
    ]
    assert {"declaration"} in kinds, kinds
    assert {"write"} in kinds, kinds
    assert {"read"} in kinds, kinds

    graph = build_call_graph(text, methods)
    paths = reachable_from(graph, "_PTS")
    assert set(paths) == {"_PTS", "MPTS", "APTS", "_PS3"}, sorted(paths)
    assert "APTS" not in names, "APTS must stay a blind spot"
    assert names["_PS3"] > 1, "_PS3 must stay ambiguous"

    assert "GM22" not in paths, "GM22 is not reachable from _PTS"
    print("self-test: PASS")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Audit an ACPI symbol in the collected DSDT."
    )
    parser.add_argument("source", nargs="?", help=".tar.gz archive, directory or .dsl file")
    parser.add_argument("--symbol", default="NVDE", help="symbol to analyse (default: NVDE)")
    parser.add_argument("--origin", default="_PTS", help="starting method (default: _PTS)")
    parser.add_argument(
        "--scan-all",
        action="store_true",
        help="list the symbol's occurrences in ALL .dsl/.asl files (DSDT plus SSDTs)",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="internal check on a synthetic ASL; reads no file",
    )
    arguments = parser.parse_args()

    if arguments.self_test:
        return self_test()

    # An empty or non-ACPI symbol would build a regex that matches everywhere,
    # and therefore a confident but false verdict.
    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]{0,3}", arguments.symbol) is None:
        raise SystemExit(f"invalid ACPI symbol: {arguments.symbol!r}")

    symbol = Symbol(arguments.symbol)

    if arguments.scan_all:
        print("=" * 78)
        print(f"SCAN OF ALL TABLES: {symbol.name}")
        print("=" * 78)
        total = 0
        for label, raw_text in collect_all_sources(arguments.source):
            body = strip_comments(raw_text)
            table_lines = body.splitlines()
            table_methods = index_methods(body)
            hits = []
            for number, line in enumerate(table_lines):
                if symbol.reference.search(line):
                    hits.append(
                        (number, line.strip(), classify(line, symbol), enclosing_method(table_methods, number))
                    )
            total += len(hits)
            marker = f"{len(hits)} occurrences" if hits else "no occurrence"
            print(f"\n  {label}  ({len(table_lines)} lines, {len(table_methods)} methods): {marker}")
            for number, text, kinds, method in hits:
                print(f"      line {number + 1:>6}  [{'+'.join(sorted(kinds)):<17}]  in {method}")
                print(f"                     {text}")
        print(f"\n  TOTAL occurrences across all tables: {total}")
        print()
        return 0
    label, raw = load_source(arguments.source)
    text = strip_comments(raw)
    lines = text.splitlines()

    print("=" * 78)
    print(f"Source    : {label}")
    print(f"Symbol    : {symbol.name}     path origin: {arguments.origin}")
    print(f"ASL lines : {len(lines)}")
    print("=" * 78)

    kind, declaration_line, detail = declaration_kind(lines, symbol)
    print(f"\n[1] DECLARATION OF {symbol.name}")
    if declaration_line is None:
        print(f"    {symbol.name} is not declared in this DSDT.")
        print("    Writing it would create a new name that no firmware method reads.")
    else:
        print(f"    kind : {kind} ({detail})")
        print(f"    line : {declaration_line + 1}: {lines[declaration_line].strip()}")
        if kind == "OperationRegion field":
            print("    WARNING: writing to it can have hardware effects (EC/SMI) even if")
            print("    no AML method reads the value back.")
        else:
            print("    A write is observable only if some AML method reads it back.")

    methods = index_methods(text)
    occurrences: list[tuple[int, str, set[str], str]] = []
    for number, line in enumerate(lines):
        if not symbol.reference.search(line):
            continue
        kinds = classify(line, symbol)
        if kinds == {"declaration"}:
            continue
        occurrences.append((number, line.strip(), kinds, enclosing_method(methods, number)))

    print(f"\n[2] OCCURRENCES ({len(occurrences)} beyond the declaration, across {len(methods)} methods)")
    if not occurrences:
        print(f"    None. The firmware never touches {symbol.name}.")
    for number, body, kinds, method in occurrences:
        print(f"    line {number + 1:>6}  [{'+'.join(sorted(kinds)):<17}]  in {method}")
        print(f"                   {body}")

    readers = sorted({method for _, _, kinds, method in occurrences if "read" in kinds})
    print(f"\n[3] WHO READS {symbol.name}")
    if not readers:
        print(f"    Nobody. No firmware method consults {symbol.name}.")
    for reader in readers:
        print(f"    {reader}")

    graph = build_call_graph(text, methods)
    paths = reachable_from(graph, arguments.origin)
    print(f"\n[4] REACHABILITY FROM {arguments.origin}")
    if arguments.origin not in graph:
        print(f"    WARNING: {arguments.origin} not found among this DSDT's methods.")
    else:
        print(f"    Methods reachable from {arguments.origin}: {len(paths)}")
    for reader in readers:
        if reader in paths:
            print(f"    REACHABLE      {reader}   via  {' -> '.join(paths[reader])}")
        else:
            print(f"    not reachable  {reader}")

    # ponytail: the graph resolves calls by four-character short name, ignoring
    # scope. Scope is not resolved; ambiguity is reported instead: a name defined
    # more than once does not identify a specific body.
    definitions = Counter(name for name, _, _ in methods)
    blind = sorted(name for name in paths if name not in definitions)
    ambiguous = sorted(name for name in paths if definitions[name] > 1)
    if blind:
        print(f"\n    BLIND SPOTS: {len(blind)} reachable methods are External,")
        print("    that is, defined in another table and not inspectable here:")
        for name in blind:
            print(f"      {name}   via  {' -> '.join(paths[name])}")
    if ambiguous:
        print(f"\n    AMBIGUOUS NAMES: {len(ambiguous)} reachable methods have more than one")
        print("    definition in this table; the call does not identify which body:")
        for name in ambiguous:
            print(f"      {name}   {definitions[name]} definitions   via  {' -> '.join(paths[name])}")
    if blind or ambiguous:
        print("\n    Use --scan-all across every table before concluding.")

    critical = [reader for reader in readers if reader in paths]

    print("\n" + "=" * 78)
    print("VERDICT")
    print("=" * 78)
    if kind == "OperationRegion field":
        print(f"  NOT INERT: {symbol.name} is a hardware field. Writing it touches the")
        print("  underlying region regardless of AML readers. A real test is required.")
    elif not readers:
        print(f"  INERT: no AML method ever reads {symbol.name}.")
        print(f"  Writing {symbol.name} = 1 during {arguments.origin} cannot change shutdown")
        print("  behaviour. The choice between variants can be made on simplicity and")
        print("  fidelity, not on risk.")
    elif not critical:
        print(f"  INERT ON THE SHUTDOWN PATH: {symbol.name} is read, but by no method")
        print(f"  reachable from {arguments.origin} in this table:")
        print("    " + ", ".join(readers))
        if blind or ambiguous:
            print("  CONCLUSION NOT CLOSED: reachable methods remain whose body is not")
            print(f"  identified here ({', '.join(blind + ambiguous)}).")
            print(f"  One of those bodies may read {symbol.name}.")
        print("  Check by hand that none of these is invoked during S5.")
    else:
        print(f"  RELEVANT: {symbol.name} is read by methods reachable from")
        print(f"  {arguments.origin}:")
        for reader in critical:
            print(f"    {reader}   via  {' -> '.join(paths[reader])}")
        print("  The write has a potential effect. Read those methods before deciding.")
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
