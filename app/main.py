from fastapi import FastAPI

from app.__version__ import __version__

app = FastAPI(title="Portfolio API", version=__version__)


@app.get("/")
def root():
    return {"service": "portfolio-api", "version": __version__}


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/items/{item_id}")
def get_item(item_id: int):
    return {"item_id": item_id, "name": f"item-{item_id}"}
