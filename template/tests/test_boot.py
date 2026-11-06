"""The per-product contract: the app boots and /health answers 200."""
import importlib
import sys
from pathlib import Path

from fastapi.testclient import TestClient

ROOT = Path(__file__).resolve().parent.parent


def test_app_boots_and_health_is_200(tmp_path, monkeypatch):
    monkeypatch.setenv("AGENTOS_DB", str(tmp_path / "agentos.db"))
    monkeypatch.syspath_prepend(str(ROOT))
    sys.modules.pop("main", None)
    main = importlib.import_module("main")
    with TestClient(main.app) as client:
        assert client.get("/health").status_code == 200
