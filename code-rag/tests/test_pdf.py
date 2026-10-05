import uuid

import pymupdf

from code_rag.pdf import (
    article_hint,
    chunk_text,
    is_decoy_layer,
    iter_pages,
    page_chunks,
    point_id,
    text_quality,
)


def test_chunk_text_empty_and_short():
    assert chunk_text("   \n ") == []
    assert chunk_text("  court  ") == ["court"]


def test_chunk_text_windows_overlap_and_coverage():
    words = [f"mot{i:05d}" for i in range(2000)]  # ~18 000 caractères
    text = " ".join(words)
    chunks = chunk_text(text, size=3200, overlap=0.15)
    assert len(chunks) >= 6
    assert all(len(c) <= 3200 for c in chunks)
    for a, b in zip(chunks, chunks[1:], strict=False):
        assert b.split()[1] in a  # le début de l'extrait suivant reprend la fin du précédent
    joined = " ".join(chunks)
    assert all(w in joined for w in words)
    assert chunk_text(text) == chunks  # déterministe


def test_article_hint():
    assert article_hint("intro\n12-3000 Remplissage des conduits") == "12-3000"
    assert article_hint("  4-004 Ampacité\n") == "4-004"
    assert article_hint("voir Section 4 Labor units") == "Section 4"
    assert article_hint("Table 2 Conduit hours") == "Table 2"
    assert article_hint("Tableau D1 non numérique, Tableau 6A") == "Tableau 6A"
    assert article_hint("aucun repère ici, 1-1/2 po, 2024-01-05") == ""


def test_point_id_is_deterministic_uuid():
    a = point_id("CSA 2026", 12, 0)
    assert a == point_id("CSA 2026", 12, 0)
    assert a != point_id("CSA 2026", 12, 1)
    assert a != point_id("CSA 2026", 13, 0)
    assert uuid.UUID(a).version == 5


def test_pages_are_one_based_and_chunks_stay_on_their_page(tiny_pdf):
    pages = list(iter_pages(tiny_pdf))
    assert [(p, total) for p, total, _ in pages] == [(1, 3), (2, 3), (3, 3)]

    by_page = {p: page_chunks("Mini Code", p, text) for p, _, text in pages}
    assert len(by_page[1]) == 1
    assert by_page[1][0].article_hint == "12-3000"
    assert "Remplissage des conduits" in by_page[1][0].text

    long_page = by_page[2]
    assert len(long_page) >= 2
    assert [c.chunk_index for c in long_page] == list(range(len(long_page)))
    assert all(c.page == 2 and c.source == "Mini Code" for c in long_page)
    assert long_page[0].article_hint == "Section 4"
    assert "Line 119" in long_page[-1].text

    assert by_page[3] == []  # page sans texte


def test_text_quality_real_text_vs_letter_salad():
    assert text_quality("") == 0.0
    assert text_quality("12 345 -- 6,7") == 0.0  # aucun mot
    assert text_quality("Le conduit doit être dans la Section 4.") > 0.5
    assert text_quality("The conductor shall be in the table") > 0.5
    assert text_quality("cicaan vedet temppelici ocuuc ulkomaan kertoivat") == 0.0


def test_is_decoy_layer_on_generated_pdfs(french_pdf, decoy_pdf, tiny_pdf, tmp_path):
    with pymupdf.open(french_pdf) as doc:
        assert not is_decoy_layer(doc)
    with pymupdf.open(decoy_pdf) as doc:
        assert is_decoy_layer(doc)
    with pymupdf.open(tiny_pdf) as doc:  # texte réel + page vide ignorée
        assert not is_decoy_layer(doc)

    blank = tmp_path / "vide.pdf"
    with pymupdf.open() as doc:
        doc.new_page()
        doc.save(blank)
    with pymupdf.open(blank) as doc:  # scan sans texte : c'est l'affaire de « OCR nécessaire ? »
        assert not is_decoy_layer(doc)


def test_is_decoy_layer_samples_evenly_spaced_pages(decoy_pdf):
    with pymupdf.open(decoy_pdf) as doc:
        assert is_decoy_layer(doc, sample_pages=1)
        assert is_decoy_layer(doc, sample_pages=50)  # plus que de pages : toutes échantillonnées
        assert not is_decoy_layer(doc, sample_pages=0)  # rien échantillonné, rien à juger
