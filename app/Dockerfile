FROM public.ecr.aws/bitnami/node:latest

#Setup env

RUN apt-get update
RUN apt-get install -y less
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
RUN unzip awscliv2.zip
RUN ./aws/install
RUN apt-get -y install default-jre

# Create and change to the app directory.
WORKDIR /usr/src/app

RUN wget https://archive.apache.org/dist/kafka/2.2.1/kafka_2.12-2.2.1.tgz
RUN tar -xzf kafka_2.12-2.2.1.tgz

COPY package*.json ./


RUN npm install --only=production

COPY . ./

ENV XRAY_URL="xray-service.default:2000"
ENV APPNAME_NAME="zip-service"
ENV ZIPCODE="94582"
ENV HTHRESHOLD="1"
ENV POD_NAME="zip-service-app"
ENV kafka_topic=""
ENV kafka_endpoint=""

# Run the web service on container startup.
CMD [ "npm", "start" ]
