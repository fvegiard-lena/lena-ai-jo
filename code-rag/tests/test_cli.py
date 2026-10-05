import pytest
from typer.testing import CliRunner

from code_rag import cli

runner = CliRunner()


@pytest.fixture
def wired(monkeypatch, fake_qdrant, embedder):
    """CLI branché sur le faux Qdrant et l'Ollama simulé."""
    monkeypatch.setattr(cli, "make_client", lambda: fake_qdrant)
    monkeypatch.setattr(cli, "make_embedder", lambda: embedder)
    monkeypatch.setattr(cli, "qdrant_health", lambda: None)
    return fake_qdrant


def points(fake, collection="codes_electriques"):
    return fake.collections[collection]["points"]


def test_ingest_creates_collection_and_payloads(wired, tiny_pdf):
    result = runner.invoke(cli.app, ["ingest", str(tiny_pdf)])
    assert result.exit_code == 0, result.output
    assert "[Mini Code] p.1/3" in result.output
    assert "p.3/3 : 0 extrait(s)" in result.output
    assert "1 page(s) sans texte" in result.output

    assert wired.collections["codes_electriques"]["size"] == 4096
    assert ("codes_electriques", "source") in wired.indexes
    stored = points(wired)
    assert len(stored) >= 3
    payloads = [p.payload for p in stored.values()]
    assert {p["page"] for p in payloads} == {1, 2}
    assert all(p["source"] == "Mini Code" for p in payloads)
    first = next(p for p in payloads if p["page"] == 1)
    assert first["article_hint"] == "12-3000"
    assert first["chunk_index"] == 0
    assert first["ingested_at"]
    assert "Remplissage des conduits" in first["text"]


def test_ingest_is_resumable_and_force_reembeds(wired, tiny_pdf, ollama):
    runner.invoke(cli.app, ["ingest", str(tiny_pdf)])
    n_points, n_batches = len(points(wired)), len(ollama.batches)

    again = runner.invoke(cli.app, ["ingest", str(tiny_pdf)])
    assert again.exit_code == 0, again.output
    assert f"0 extrait(s) indexé(s), {n_points} ignoré(s)" in again.output
    assert len(ollama.batches) == n_batches  # aucun nouvel appel d'embedding
    assert len(points(wired)) == n_points

    forced = runner.invoke(cli.app, ["ingest", str(tiny_pdf), "--force"])
    assert forced.exit_code == 0, forced.output
    assert f"{n_points} extrait(s) indexé(s), 0 ignoré(s)" in forced.output
    assert len(points(wired)) == n_points  # mêmes IDs : écrasés, pas dupliqués


def test_ingest_source_override_and_guard(wired, tiny_pdf, tmp_path):
    result = runner.invoke(cli.app, ["ingest", str(tiny_pdf), "--source", "CSA 2026"])
    assert result.exit_code == 0, result.output
    assert {p.payload["source"] for p in points(wired).values()} == {"CSA 2026"}

    other = tmp_path / "autre.pdf"
    other.write_bytes(tiny_pdf.read_bytes())
    guard = runner.invoke(cli.app, ["ingest", str(tiny_pdf), str(other), "--source", "X"])
    assert guard.exit_code == 2


def test_ingest_refuses_decoy_text_layer(wired, decoy_pdf):
    result = runner.invoke(cli.app, ["ingest", str(decoy_pdf)])
    assert result.exit_code == 3, result.output
    assert "Couche texte factice détectée dans « Factice.pdf »" in result.output
    assert "(texte présent mais sans mots réels)" in result.output
    assert "ocrmypdf --language fra+eng --force-ocr" in result.output
    assert "Factice OCR.pdf" in result.output
    assert wired.collections == {}  # Qdrant n'a pas été touché


def test_ingest_allow_decoy_overrides_guard(wired, decoy_pdf):
    result = runner.invoke(cli.app, ["ingest", str(decoy_pdf), "--allow-decoy"])
    assert result.exit_code == 0, result.output
    assert points(wired)


def test_ingest_accepts_real_french_text(wired, french_pdf):
    result = runner.invoke(cli.app, ["ingest", str(french_pdf)])
    assert result.exit_code == 0, result.output
    assert points(wired)


def test_ask_prints_cited_extracts_and_final_line(wired, tiny_pdf):
    runner.invoke(cli.app, ["ingest", str(tiny_pdf)])
    result = runner.invoke(cli.app, ["ask", "remplissage des conduits", "--k", "2"])
    assert result.exit_code == 0, result.output
    lines = [line for line in result.output.splitlines() if line.startswith("**[")]
    assert len(lines) == 2
    assert lines[0].startswith("**[Mini Code p.1 — 12-3000]** 12-3000 Remplissage des conduits")
    assert result.output.rstrip().endswith(cli.FINAL_LINE)


def test_ask_unknown_source_says_nothing_found(wired, tiny_pdf):
    runner.invoke(cli.app, ["ingest", str(tiny_pdf)])
    result = runner.invoke(cli.app, ["ask", "calibre", "--source", "NECA 2022"])
    assert result.exit_code == 0, result.output
    assert "Aucun extrait trouvé dans la source « NECA 2022 »" in result.output
    assert "**[" not in result.output
    assert result.output.rstrip().endswith("[À CONFIRMER — Jo]")


def test_ask_without_collection_fails(wired):
    result = runner.invoke(cli.app, ["ask", "calibre"])
    assert result.exit_code == 2
    assert "aucun PDF ingéré" in result.output


def test_status_reports_counts_per_source(wired, tiny_pdf):
    empty = runner.invoke(cli.app, ["status"])
    assert empty.exit_code == 0, empty.output
    assert "absente — 0 point" in empty.output

    runner.invoke(cli.app, ["ingest", str(tiny_pdf)])
    runner.invoke(cli.app, ["ingest", str(tiny_pdf), "--source", "CSA 2026"])
    result = runner.invoke(cli.app, ["status"])
    assert result.exit_code == 0, result.output
    assert "Qdrant : OK" in result.output
    assert "Ollama : OK" in result.output
    n = len(points(wired)) // 2
    assert f"  - CSA 2026 : {n} point(s)" in result.output
    assert f"  - Mini Code : {n} point(s)" in result.output


def test_status_flags_unreachable_services(monkeypatch, wired):
    def down() -> None:
        raise RuntimeError("Qdrant injoignable")

    monkeypatch.setattr(cli, "qdrant_health", down)
    result = runner.invoke(cli.app, ["status"])
    assert result.exit_code == 1
    assert "Qdrant : PROBLÈME" in result.output
