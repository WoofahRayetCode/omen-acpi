#!/usr/bin/env python3
#
# Copyright (C) 2026 Paolo De Marinis
# SPDX-License-Identifier: GPL-3.0-or-later
#
"""Audit di NVDE nel DSDT raccolto dall'OMEN ACPI Toolkit.

Risponde a una sola domanda: scrivere NVDE = 1 durante _PTS ha un effetto
osservabile su questa macchina, oppure e' inerte?

Lo script non modifica nulla. Legge soltanto.

Uso:
    ./nvde-audit.py                      # cerca ~/omen-*acpi-source-*.tar.gz
    ./nvde-audit.py archivio.tar.gz
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
    # I commenti a blocco vengono sostituiti con altrettanti newline, altrimenti
    # i numeri di riga riportati non corrisponderebbero al file originale.
    text = re.sub(
        r"/\*.*?\*/",
        lambda match: "\n" * match.group(0).count("\n"),
        text,
        flags=re.DOTALL,
    )
    # Ogni riga conserva il proprio terminatore: un join semplice perderebbe
    # l'ultima riga vuota e falserebbe il totale riportato.
    return "".join(line.split("//")[0] + "\n" for line in text.splitlines())


def collect_all_sources(argument: str | None) -> list[tuple[str, str]]:
    """Restituisce [(etichetta, testo)] per ogni .dsl/.asl trovato nella sorgente."""
    if argument:
        source = Path(argument).expanduser()
    else:
        archives = sorted(
            Path.home().glob("omen-*acpi-source-*.tar.gz"),
            key=lambda path: path.stat().st_mtime,
            reverse=True,
        )
        if not archives:
            raise SystemExit("nessun archivio ~/omen-*acpi-source-*.tar.gz trovato.")
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
                        raise SystemExit(f"percorso non sicuro: {member.name}")
                archive.extractall(temporary)
            return read_all(Path(temporary), f"{source.name} -> ")
    if source.is_dir():
        return read_all(source, "")
    return [(source.name, source.read_text(encoding="utf-8", errors="replace"))]


def load_source(argument: str | None) -> tuple[str, str]:
    """Restituisce (etichetta_sorgente, testo_asl)."""
    if argument:
        source = Path(argument).expanduser()
        if not source.exists():
            raise SystemExit(f"sorgente inesistente: {source}")
    else:
        home = Path.home()
        archives = sorted(
            home.glob("omen-*acpi-source-*.tar.gz"),
            key=lambda path: path.stat().st_mtime,
            reverse=True,
        )
        if not archives:
            raise SystemExit(
                "nessun archivio ~/omen-*acpi-source-*.tar.gz trovato.\n"
                "Passa esplicitamente un .tar.gz, una directory o un file .dsl."
            )
        source = archives[0]

    def biggest_dsl(root: Path) -> Path:
        found = sorted(root.rglob("*.dsl"))
        if not found:
            raise SystemExit(f"nessun file .dsl dentro {root}")
        return max(found, key=lambda path: path.stat().st_size)

    if source.is_file() and source.name.endswith((".tar.gz", ".tgz")):
        with tempfile.TemporaryDirectory() as temporary:
            with tarfile.open(source, mode="r:gz") as archive:
                for member in archive.getmembers():
                    member_path = Path(member.name)
                    if member_path.is_absolute() or ".." in member_path.parts:
                        raise SystemExit(f"percorso non sicuro nell'archivio: {member.name}")
                    if not (member.isfile() or member.isdir()):
                        raise SystemExit(f"membro non regolare nell'archivio: {member.name}")
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
    """[(nome, riga_inizio, riga_fine)] con indici 0-based, robusto ai metodi su una riga."""
    methods: list[tuple[str, int, int]] = []

    for match in re.finditer(r"^[ \t]*Method\s*\(\s*(\\?[A-Za-z0-9_.\\]+)", text, re.MULTILINE):
        name = match.group(1).split(".")[-1].lstrip("\\")

        # Salta fino alla graffa che apre il corpo, uscendo dalla lista argomenti.
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
    return best[0] if best else "<ambito globale>"


def store_argument_pairs(line: str) -> list[tuple[str, str]]:
    """Estrae (valore, destinazione) da ogni Store (...) presente nella riga."""
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
        return {"dichiarazione"}
    if symbol.read_modify.search(line):
        return {"lettura", "scrittura"}

    kinds: set[str] = set()

    if symbol.assignment.match(line):
        kinds.add("scrittura")
        remainder = line.split("=", 1)[1]
        if symbol.reference.search(remainder):
            kinds.add("lettura")
        return kinds

    pairs = store_argument_pairs(line)
    if pairs:
        residual = line
        for value, destination in pairs:
            if symbol.reference.search(destination):
                kinds.add("scrittura")
            if symbol.reference.search(value):
                kinds.add("lettura")
            residual = residual.replace(value, " ").replace(destination, " ")
        # Un riferimento fuori da ogni Store sulla stessa riga resta una lettura.
        if symbol.reference.search(residual):
            kinds.add("lettura")
        if kinds:
            return kinds

    return {"lettura"}


def declaration_kind(lines: list[str], symbol: Symbol) -> tuple[str, int | None, str]:
    """Distingue un Name globale da un campo di OperationRegion."""
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
            return ("campo di OperationRegion", number, f"dentro la regione {field_region}")
        if symbol.declare_name.match(line):
            return ("Name globale", number, "semplice variabile di namespace")

    return ("non dichiarato", None, "")


def external_methods(text: str) -> set[str]:
    """Metodi dichiarati External: il corpo vive in un'altra tabella."""
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
    # I metodi External sono nodi foglia: raggiungibili, ma con corpo non
    # ispezionabile da questo file. Ometterli farebbe sembrare chiuso un
    # percorso che invece prosegue in un'altra tabella.
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
        MPTS (Arg0)   /* commento */
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
    assert len(text.splitlines()) == len(SELF_TEST_ASL.splitlines()), "righe non allineate"
    assert "commento" not in text, "commento a blocco non rimosso"

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
    assert {"dichiarazione"} in kinds, kinds
    assert {"scrittura"} in kinds, kinds
    assert {"lettura"} in kinds, kinds

    graph = build_call_graph(text, methods)
    paths = reachable_from(graph, "_PTS")
    assert set(paths) == {"_PTS", "MPTS", "APTS", "_PS3"}, sorted(paths)
    assert "APTS" not in names, "APTS deve restare un punto cieco"
    assert names["_PS3"] > 1, "_PS3 deve restare ambiguo"

    assert "GM22" not in paths, "GM22 non e' raggiungibile da _PTS"
    print("self-test: PASS")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Audit di un simbolo ACPI nel DSDT raccolto.")
    parser.add_argument("source", nargs="?", help="archivio .tar.gz, directory o file .dsl")
    parser.add_argument("--symbol", default="NVDE", help="simbolo da analizzare (default: NVDE)")
    parser.add_argument("--origin", default="_PTS", help="metodo di partenza (default: _PTS)")
    parser.add_argument(
        "--scan-all",
        action="store_true",
        help="elenca le occorrenze del simbolo in TUTTI i .dsl/.asl (DSDT piu' SSDT)",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="verifica interna su un ASL sintetico; non legge alcun file",
    )
    arguments = parser.parse_args()

    if arguments.self_test:
        return self_test()

    # Un simbolo vuoto o non ACPI produrrebbe una regex che combacia ovunque,
    # e quindi un verdetto sicuro di se' ma falso.
    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]{0,3}", arguments.symbol) is None:
        raise SystemExit(f"simbolo ACPI non valido: {arguments.symbol!r}")

    symbol = Symbol(arguments.symbol)

    if arguments.scan_all:
        print("=" * 78)
        print(f"SCANSIONE DI TUTTE LE TABELLE: {symbol.name}")
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
            marker = f"{len(hits)} occorrenze" if hits else "nessuna occorrenza"
            print(f"\n  {label}  ({len(table_lines)} righe, {len(table_methods)} metodi): {marker}")
            for number, text, kinds, method in hits:
                print(f"      riga {number + 1:>6}  [{'+'.join(sorted(kinds)):<17}]  in {method}")
                print(f"                     {text}")
        print(f"\n  TOTALE occorrenze su tutte le tabelle: {total}")
        print()
        return 0
    label, raw = load_source(arguments.source)
    text = strip_comments(raw)
    lines = text.splitlines()

    print("=" * 78)
    print(f"Sorgente : {label}")
    print(f"Simbolo  : {symbol.name}     origine percorso: {arguments.origin}")
    print(f"Righe ASL: {len(lines)}")
    print("=" * 78)

    kind, declaration_line, detail = declaration_kind(lines, symbol)
    print(f"\n[1] DICHIARAZIONE DI {symbol.name}")
    if declaration_line is None:
        print(f"    {symbol.name} non e' dichiarato in questo DSDT.")
        print("    Scriverlo creerebbe un nome nuovo che nessun metodo del firmware legge.")
    else:
        print(f"    tipo : {kind} ({detail})")
        print(f"    riga : {declaration_line + 1}: {lines[declaration_line].strip()}")
        if kind == "campo di OperationRegion":
            print("    ATTENZIONE: scriverci puo' avere effetti hardware (EC/SMI) anche se")
            print("    nessun metodo AML rilegge il valore.")
        else:
            print("    Una scrittura e' osservabile solo se qualche metodo AML la rilegge.")

    methods = index_methods(text)
    occurrences: list[tuple[int, str, set[str], str]] = []
    for number, line in enumerate(lines):
        if not symbol.reference.search(line):
            continue
        kinds = classify(line, symbol)
        if kinds == {"dichiarazione"}:
            continue
        occurrences.append((number, line.strip(), kinds, enclosing_method(methods, number)))

    print(f"\n[2] OCCORRENZE ({len(occurrences)} oltre la dichiarazione, su {len(methods)} metodi)")
    if not occurrences:
        print(f"    Nessuna. Il firmware non tocca mai {symbol.name}.")
    for number, body, kinds, method in occurrences:
        print(f"    riga {number + 1:>6}  [{'+'.join(sorted(kinds)):<17}]  in {method}")
        print(f"                   {body}")

    readers = sorted({method for _, _, kinds, method in occurrences if "lettura" in kinds})
    print(f"\n[3] CHI LEGGE {symbol.name}")
    if not readers:
        print(f"    Nessuno. Nessun metodo del firmware consulta {symbol.name}.")
    for reader in readers:
        print(f"    {reader}")

    graph = build_call_graph(text, methods)
    paths = reachable_from(graph, arguments.origin)
    print(f"\n[4] RAGGIUNGIBILITA' DA {arguments.origin}")
    if arguments.origin not in graph:
        print(f"    ATTENZIONE: {arguments.origin} non trovato fra i metodi del DSDT.")
    else:
        print(f"    Metodi raggiungibili da {arguments.origin}: {len(paths)}")
    for reader in readers:
        if reader in paths:
            print(f"    RAGGIUNGIBILE      {reader}   via  {' -> '.join(paths[reader])}")
        else:
            print(f"    non raggiungibile  {reader}")

    # ponytail: il grafo risolve le chiamate per nome corto di 4 caratteri,
    # ignorando lo scope. Non si risolve lo scope, si segnala l'ambiguita':
    # un nome definito piu' volte non identifica un corpo preciso.
    definitions = Counter(name for name, _, _ in methods)
    blind = sorted(name for name in paths if name not in definitions)
    ambiguous = sorted(name for name in paths if definitions[name] > 1)
    if blind:
        print(f"\n    PUNTI CIECHI: {len(blind)} metodi raggiungibili sono External,")
        print("    cioe' definiti in un'altra tabella e non ispezionabili qui:")
        for name in blind:
            print(f"      {name}   via  {' -> '.join(paths[name])}")
    if ambiguous:
        print(f"\n    NOMI AMBIGUI: {len(ambiguous)} metodi raggiungibili hanno piu' di una")
        print("    definizione in questa tabella; la chiamata non identifica quale corpo:")
        for name in ambiguous:
            print(f"      {name}   {definitions[name]} definizioni   via  {' -> '.join(paths[name])}")
    if blind or ambiguous:
        print("\n    Usa --scan-all su tutte le tabelle prima di concludere.")

    critical = [reader for reader in readers if reader in paths]

    print("\n" + "=" * 78)
    print("VERDETTO")
    print("=" * 78)
    if kind == "campo di OperationRegion":
        print(f"  NON INERTE: {symbol.name} e' un campo hardware. Scriverlo tocca la regione")
        print("  sottostante a prescindere dai lettori AML. Serve un test reale.")
    elif not readers:
        print(f"  INERTE: nessun metodo AML legge mai {symbol.name}.")
        print(f"  Scrivere {symbol.name} = 1 durante {arguments.origin} non puo' cambiare il")
        print("  comportamento dello spegnimento. La scelta fra le varianti si puo' fare")
        print("  su basi di semplicita' e fedelta', non di rischio.")
    elif not critical:
        print(f"  INERTE SUL PERCORSO DI SPEGNIMENTO: {symbol.name} viene letto, ma da")
        print(f"  nessun metodo raggiungibile da {arguments.origin} in questa tabella:")
        print("    " + ", ".join(readers))
        if blind or ambiguous:
            print("  CONCLUSIONE NON CHIUSA: restano metodi raggiungibili il cui corpo")
            print(f"  non e' identificato qui ({', '.join(blind + ambiguous)}).")
            print(f"  Uno di quei corpi puo' leggere {symbol.name}.")
        print("  Verifica a mano che nessuno di questi sia invocato durante S5.")
    else:
        print(f"  RILEVANTE: {symbol.name} viene letto da metodi raggiungibili da")
        print(f"  {arguments.origin}:")
        for reader in critical:
            print(f"    {reader}   via  {' -> '.join(paths[reader])}")
        print("  La scrittura ha un effetto potenziale. Leggi quei metodi prima di decidere.")
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
