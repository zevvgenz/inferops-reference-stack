# Single image serves both roles: the app (uvicorn main:app) and the
# migration Job (alembic upgrade head) — see charts/reference-stack values
# app.image / migration.image, both point at this same image. Keeps the
# migration guaranteed in lockstep with the app's model definitions.
FROM python:3.12-slim

WORKDIR /app

# System deps for psycopg[binary] are none beyond what the wheel bundles;
# kept minimal on purpose.
# requirements.txt mirrors pyproject.toml's [project.dependencies] exactly
# (see the comment there) — no build-backend/wheel machinery needed since
# main.py/db.py are top-level modules, not an installable package.
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py db.py alembic.ini ./
COPY migrations ./migrations

ENV PYTHONUNBUFFERED=1

EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
