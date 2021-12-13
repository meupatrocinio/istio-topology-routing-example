# Istio Topology based routing example
This respoistory contains the examples to do topology based routing as specified in the blog <<link to the blog>>. 
There is "app" folder which contains code build the app and "k8s" module which contains Kubenetes spec files to deploy to run the examples.

# Pre-requistes
## Build and publish the example app
```shell 
git clone https://github.com/mahasiva-amazon/istio-topology-routing-example.git
cd app
aws ecr create-repository --repository-name istio-tpr-app --image-scanning-configuration scanOnPush=true
```


