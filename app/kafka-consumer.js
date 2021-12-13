var kafka = require('kafka-node'),
    Consumer = kafka.Consumer,
    client = new kafka.KafkaClient( { kafkaHost: process.env.kafka_endpoint }),
    consumer = new Consumer(
         client,
        [
              { topic: process.env.kafka_topic, partition: 0, offset: 0 }
        ],
        { fromOffset: true }         
    );

 consumer.on('message', function (message) 
 {
     console.log(message);
 });

 consumer.on('error', function (err) 
{
    console.log('ERROR: ' + err.toString());
});