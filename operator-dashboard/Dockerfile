FROM python:3.12-alpine

WORKDIR /app
COPY app.py .

# Non-root user (read-only filesystem except not needed for this app)
RUN adduser -D -H -u 1000 appuser && chown -R appuser:appuser /app
USER appuser

EXPOSE 8090
ENV PYTHONUNBUFFERED=1
CMD ["python", "-u", "app.py"]
