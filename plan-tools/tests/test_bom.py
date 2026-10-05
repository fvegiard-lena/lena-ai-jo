from plan_tools.bom import HEADER, NO_SCALE, bom_rows, write_bom_csv
from plan_tools.inventory import build_inventory

EXPECTED_HEADER = (
    "Plan;Discipline;Code Canonique DR;Description Technique;Modele / Reference Fabricant;"
    "Localisation;Qte Brute;Correction / Regle Appliquee;Qte Finale;Unite;Statut Action;"
    "Notes Chantier;Reference feuille"
)


def test_header_exact():
    assert ";".join(HEADER) == EXPECTED_HEADER
    assert len(HEADER) == 13


def test_bom_file_header_bytes(mini_doc, tmp_path):
    path = write_bom_csv(build_inventory(mini_doc), tmp_path / "bom.csv")
    first = path.read_bytes().split(b"\r\n", 1)[0]
    assert first == b"\xef\xbb\xbf" + EXPECTED_HEADER.encode("utf-8")


def test_bom_rows_mapping(mini_doc):
    rows = bom_rows(build_inventory(mini_doc))
    assert len(rows) == 5  # Counter, Line, Area, Line, Perimeter (annotations exclues)
    counter, line = rows[0], rows[1]
    assert counter == [
        "Plan A - RDC",
        "",
        "ET PRISE",
        "ET PRISE",
        "",
        "Calque par défaut",
        "2",
        "",
        "2",
        "un",
        "À valider",
        "",
        "Plan A - RDC.png",
    ]
    assert line[2:4] == ["19PE0.75 #12", "conduit 3/4 03c12"]
    assert (line[6], line[8], line[9], line[11]) == ("1200", "1200", "px", NO_SCALE)
    area = rows[2]
    assert area[6] == "400" and "Surface = 10000 px²" in area[11]
    scaled = rows[3]
    assert scaled[2] == "conduit 1 03c08"  # pas d'entrée catalogue -> nom de l'objet
    assert "93,75" in scaled[11] and "[À CONFIRMER — Jo]" in scaled[11]
    assert all(r[1] == "" and r[4] == "" and r[7] == "" for r in rows)
