FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY search_mcp_server.py .

ENV PORT=8790

EXPOSE 8790

CMD ["sh", "-c", "uvicorn search_mcp_server:app --host 0.0.0.0 --port ${PORT:-8790}"]
