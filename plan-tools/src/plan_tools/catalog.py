"""Catalogue : GroupID -> article EEExchangeData (Name, Key, Description)."""

from __future__ import annotations

from dataclasses import dataclass

from lxml import etree


@dataclass(frozen=True)
class CatalogEntry:
    group_id: int
    item_type: str
    item_id: str
    name: str
    key: str
    personal_key: str
    description: str


def load_catalog(root: etree._Element) -> dict[int, CatalogEntry]:
    """Lit tous les <Group GroupID=..><EEExchangeData .../></Group> du document.

    Dans les fichiers réels, les <Group> sont sous <Plans> ; on les cherche partout.
    """
    catalog: dict[int, CatalogEntry] = {}
    for group in root.iter("Group"):
        gid, data = group.get("GroupID", ""), group.find("EEExchangeData")
        if data is None or not gid.lstrip("-").isdigit():
            continue
        catalog.setdefault(
            int(gid),
            CatalogEntry(
                group_id=int(gid),
                item_type=data.get("ItemType", ""),
                item_id=data.get("ItemID", ""),
                name=data.get("Name", ""),
                key=data.get("Key", ""),
                personal_key=data.get("PersonalKey", ""),
                description=data.get("Description", ""),
            ),
        )
    return catalog
