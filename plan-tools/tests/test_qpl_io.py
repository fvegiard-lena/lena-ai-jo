from plan_tools.qpl_io import dumps, loads, roundtrip_check, serialize


def test_fixture_is_bom_crlf_tabs(mini_doc):
    assert mini_doc.raw.startswith(b'\xef\xbb\xbf<?xml version="1.0"?>\r\n')
    assert b"\r\n\t<Project" in mini_doc.raw
    assert mini_doc.newline == "\r\n"


def test_serialize_is_byte_identical(mini_doc):
    assert serialize(mini_doc) == mini_doc.raw
    assert dumps(mini_doc) == mini_doc.raw


def test_roundtrip_check_fixture(mini_path):
    r = roundtrip_check(mini_path)
    assert r.byte_equal and r.c14n_equal and not r.diff_hint and not r.error


def test_style_quirks_preserved(mini_doc):
    out = serialize(mini_doc)
    assert b'<Element X1="0" Y1="0" X2="300" Y2="0" />' in out  # Line : espace avant />
    assert b'<Element X="2973" Y="4100" Width="24" Height="24"/>' in out  # Counter : sans espace
    assert b'<Point X="1000" Y="1000"/>' in out
    assert b"<ContactName></ContactName>" in out
    assert "L&apos;étage &amp; toit".encode() in out


def test_modified_doc_is_serialized_not_raw(mini_doc):
    assert not mini_doc.is_modified()
    mini_doc.root.find("Project").set("Name", "S-0001")
    assert mini_doc.is_modified()
    out = dumps(mini_doc)
    assert out != mini_doc.raw
    assert b'<Project Name="S-0001">' in out
    assert out.startswith(b"\xef\xbb\xbf") and out.endswith(b"</QuoterPlanSession>\r\n")


def test_unreproducible_unmodified_doc_falls_back_to_raw():
    raw = b'<?xml version="1.0"?>\n<a><b x="1" /></a>\n'  # « <b .. /> » hors <Line> : non reproduit
    doc = loads(raw)
    assert serialize(doc) != raw
    assert dumps(doc) == raw


def test_roundtrip_reports_parse_error(tmp_path):
    bad = tmp_path / "bad.qpl"
    bad.write_bytes(b"<QuoterPlanSession><Plans>")
    r = roundtrip_check(bad)
    assert not r.byte_equal and not r.c14n_equal and "XMLSyntaxError" in r.error
