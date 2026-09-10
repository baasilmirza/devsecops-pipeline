from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_root():
    r = client.get("/")
    assert r.status_code == 200
    assert r.json()["service"] == "portfolio-api"


def test_health():
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


def test_get_item():
    r = client.get("/items/42")
    assert r.status_code == 200
    assert r.json() == {"item_id": 42, "name": "item-42"}
