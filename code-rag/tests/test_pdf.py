import uuid

from code_rag.pdf import article_hint, chunk_text, iter_pages, page_chunks, point_id


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
