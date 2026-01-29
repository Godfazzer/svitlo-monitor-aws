# Use a slim python image for production
FROM python:3.11-slim

# Set working directory
WORKDIR /app

# 1. FIX LOGS: Force Python to print logs immediately to CloudWatch
ENV PYTHONUNBUFFERED=1

# Install dependencies
# (Ensure your requirements.txt contains 'requests[socks]'!)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY svitlo_monitor.py .

# 2. FIX PERMISSIONS:
# Create the cache directory explicitly and give 'appuser' ownership of the whole app folder
RUN mkdir cache && \
    useradd -m appuser && \
    chown -R appuser:appuser /app

# Switch to non-root user
USER appuser

# Run the application (No need for -u here if ENV is set above)
CMD ["python", "svitlo_monitor.py"]