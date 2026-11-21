import logging
import os

import uvicorn

from coachw.api.app import create_app
from coachw.api.config import ApiSettings

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
uvicorn.run(
    create_app(ApiSettings.from_env()),
    host=os.environ.get("COACHW_API_HOST", "127.0.0.1"),
    port=int(os.environ.get("COACHW_API_PORT", "8000")),
)
