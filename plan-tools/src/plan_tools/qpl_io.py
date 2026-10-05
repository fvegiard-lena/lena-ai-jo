"""Lecture / écriture fidèle des fichiers .qpl (XML Plan Expert).

Le sérialiseur reproduit le style de Plan Expert : BOM UTF-8, CRLF, déclaration
d'origine, `<X></X>` pour les éléments vides sans attribut, `<X a=".."/>` pour les
éléments vides avec attributs, sauf `<Element .. />` (avec espace) sous `<Line>`,
et `'` / `"` échappés en `&apos;` / `&quot;` dans les attributs.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from pathlib import Path

from lxml import etree

_PARSER_OPTS = {
    "huge_tree": True,
    "remove_blank_text": False,
    "resolve_entities": False,
    "load_dtd": False,
    "no_network": True,
}


def _parser() -> etree.XMLParser:
    return etree.XMLParser(**_PARSER_OPTS)


@dataclass
class QplDoc:
    path: Path | None
    raw: bytes
    tree: etree._ElementTree
    prolog: bytes  # tout ce qui précède la balise racine (BOM + déclaration + saut de ligne)
    epilog: bytes  # tout ce qui suit la balise racine fermante
    newline: str
    _c14n_digest: bytes = field(repr=False, default=b"")

    @property
    def root(self) -> etree._Element:
        return self.tree.getroot()

    def is_modified(self) -> bool:
        return _c14n_digest(self.root) != self._c14n_digest


@dataclass(frozen=True)
class RoundtripResult:
    path: Path
    byte_equal: bool
    c14n_equal: bool
    diff_hint: str = ""
    error: str = ""


def _c14n(root: etree._Element) -> bytes:
    return etree.tostring(root, method="c14n")


def _c14n_digest(root: etree._Element) -> bytes:
    return hashlib.sha256(_c14n(root)).digest()


def loads(raw: bytes, path: Path | None = None) -> QplDoc:
    root = etree.fromstring(raw, _parser())
    tag = root.tag.encode("utf-8")
    decl_end = raw.find(b"?>") + 2 if raw.lstrip(b"\xef\xbb\xbf").startswith(b"<?xml") else 0
    start = raw.find(b"<" + tag, decl_end)
    close = raw.rfind(b"</" + tag)
    end = raw.find(b">", close) + 1 if close != -1 else raw.rfind(b">") + 1
    return QplDoc(
        path=path,
        raw=raw,
        tree=etree.ElementTree(root),
        prolog=raw[:start],
        epilog=raw[end:],
        newline="\r\n" if b"\r\n" in raw else "\n",
        _c14n_digest=_c14n_digest(root),
    )


def load(path: str | Path) -> QplDoc:
    p = Path(path)
    return loads(p.read_bytes(), p)


def _esc_text(s: str) -> str:
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _esc_attr(s: str) -> str:
    return _esc_text(s).replace('"', "&quot;").replace("'", "&apos;")


def _write(el: etree._Element, out: list[str], nl: str) -> None:
    if isinstance(el, etree._Comment):
        out.append(f"<!--{el.text or ''}-->")
    elif isinstance(el, etree._ProcessingInstruction):
        out.append(f"<?{el.target} {el.text}?>" if el.text else f"<?{el.target}?>")
    elif isinstance(el, etree._Entity):
        out.append(el.text)
    else:
        tag = el.tag
        attrs = "".join(f' {k}="{_esc_attr(v)}"' for k, v in el.attrib.items())
        if len(el) == 0 and not el.text:
            if attrs:
                parent = el.getparent()
                in_line = tag == "Element" and parent is not None and parent.tag == "Line"
                space = " " if in_line else ""
                out.append(f"<{tag}{attrs}{space}/>")
            else:
                out.append(f"<{tag}></{tag}>")
        else:
            out.append(f"<{tag}{attrs}>")
            if el.text:
                out.append(_esc_text(el.text).replace("\n", nl))
            for child in el:
                _write(child, out, nl)
            out.append(f"</{tag}>")
    if el.tail and el.getparent() is not None:
        out.append(_esc_text(el.tail).replace("\n", nl))


def serialize(doc: QplDoc) -> bytes:
    """Sérialise l'arbre lxml dans le style Plan Expert (sans repli sur les octets d'origine)."""
    out: list[str] = []
    _write(doc.root, out, doc.newline)
    return doc.prolog + "".join(out).encode("utf-8") + doc.epilog


def dumps(doc: QplDoc) -> bytes:
    """Octets à écrire sur disque.

    Repli de sécurité : si le document n'a pas été modifié et que le sérialiseur ne
    reproduit pas exactement l'original, on renvoie les octets d'origine.
    """
    out = serialize(doc)
    if out != doc.raw and not doc.is_modified():
        return doc.raw
    return out


def _diff_hint(a: bytes, b: bytes) -> str:
    n = min(len(a), len(b))
    i = next((k for k in range(n) if a[k] != b[k]), n)
    line = a.count(b"\n", 0, i) + 1
    lo = max(0, i - 40)
    return (
        f"octet {i} (ligne {line}), tailles {len(a)}/{len(b)} : "
        f"original={a[lo : i + 40]!r} | sortie={b[lo : i + 40]!r}"
    )


def roundtrip_check(path: str | Path) -> RoundtripResult:
    p = Path(path)
    try:
        doc = load(p)
        out = serialize(doc)
        byte_equal = out == doc.raw
        reparsed = etree.fromstring(out, _parser())
        c14n_equal = byte_equal or _c14n_digest(reparsed) == doc._c14n_digest
        hint = "" if byte_equal else _diff_hint(doc.raw, out)
        return RoundtripResult(p, byte_equal, c14n_equal, hint)
    except (OSError, etree.XMLSyntaxError) as exc:
        return RoundtripResult(p, False, False, error=f"{type(exc).__name__}: {exc}")
