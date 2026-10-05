from pathlib import Path

import pytest

from plan_tools.classify import load_config
from plan_tools.qpl_io import load

FIXTURES = Path(__file__).parent / "fixtures"
FIXTURE = FIXTURES / "mini.qpl"
ROUTE_FIXTURE = FIXTURES / "route.qpl"


@pytest.fixture
def mini_path() -> Path:
    return FIXTURE


@pytest.fixture
def mini_doc():
    return load(FIXTURE)


@pytest.fixture
def route_path() -> Path:
    return ROUTE_FIXTURE


@pytest.fixture
def rdoc():
    return load(ROUTE_FIXTURE)


@pytest.fixture
def cfg():
    return load_config()
