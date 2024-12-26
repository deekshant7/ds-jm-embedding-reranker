FROM python:3.11.4

RUN mkdir -p /opt/python-service
WORKDIR /opt/python-service

COPY . /opt/python-service/
RUN mkdir -p ~/.config/pip ~/.pip && cp ./pip.conf ~/.config/pip/

RUN pip install -r requirements.txt

RUN chmod +x /opt/python-service/prod.sh

EXPOSE 8000

CMD ["bash", "/opt/python-service/prod.sh"]
