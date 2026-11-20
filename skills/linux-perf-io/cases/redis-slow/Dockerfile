FROM python:3.6


RUN pip install flask redis

EXPOSE 80
ADD app.py /app.py

CMD ["python", "/app.py"]
