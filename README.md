# Istio Topology based routing example

This respoistory contains the examples to do topology based routing as specified in the blog <<link to the blog>>. 
There is "app" folder which contains code to build the app and "k8s" module which contains Kubenetes spec files to deploy to run the examples.

## Pre-requistes
### Build and publish the example app
First step is build the clone the application code and create and ecr repository and login to the repository
```shell 
git clone https://github.com/mahasiva-amazon/istio-topology-routing-example.git
aws ecr create-repository --repository-name istio-tpr-app --image-scanning-configuration scanOnPush=true
aws ecr get-login-password --region us-west-2 | docker login --username AWS --password-stdin <<replace_with_account_id>>.dkr.ecr.us-west-2.amazonaws.com
```
Next step is to build the app
```shell
cd app
```

