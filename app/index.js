const express = require('express');
var AWS = require('aws-sdk');
require('log-timestamp');
const app = express();
const http = require('http')
  
var healthyThreshold =  Number(process.env.HTHRESHOLD);

AWS.config.update({region: 'us-west-2'});

var exec = require('child_process').exec;

var ip_val = "ip n/a";
exec("hostname -i", function(error, ip, stderr){ 
  ip_val = ip;
});

app.get('/', (req, res) => {
  lookupZip(req,res);
});

app.get('/zip', (req, res) => {
  lookupZip(req,res);
});


app.get('/health', (req, res) => {
  if(healthyThreshold == 1) {
    console.log('HealthCheck: Zip lookup service health check - [success]. HTHRESHOLD=' + healthyThreshold);
    res.sendStatus(200);
  } else {
    console.log('HealthCheck: Zip lookup service health check - [failed] HTHRESHOLD=' + healthyThreshold);
    res.sendStatus(500);
  }
});

function lookupZip(req,res) {
  console.log('Zip lookup received a request. Request will be traced!');
  //http://169.254.169.254/latest/meta-data/placement/availability-zone
  const options = {
    hostname: '169.254.169.254',
    port: 80,
    path: '/latest/meta-data/placement/availability-zone',
    method: 'GET'
  }

  const metaReq = http.request(options, metaResp => {
    console.log(`statusCode: ${metaResp.statusCode}`)
  
    metaResp.on('data', az => {
       res.send(`CA - ` + process.env.ZIPCODE + " az - " + az);
    })
  })
  
  metaReq.on('error', error => {
    console.error(error)
  })
  metaReq.end()
}

//app.use(AWSXRay.express.closeSegment());

const port = process.env.PORT || 8080;
app.listen(port, () => {
  setTimeout(function() {
    console.log('Zip lookup listening on port', port,ip_val);
  },2000);
});

