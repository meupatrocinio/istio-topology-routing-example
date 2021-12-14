# Istio topology based routing example

This respoistory contains the examples to do topology based routing as specified in the blog <<link to the blog>>. 
There is "app" folder which contains code to build the app and "k8s" module which contains Kubenetes spec files to deploy to run the examples. Ensure that while following the instructions **<<>>** are replaced with the right value. For example **<<replace_with_account_id>>** should be replaced with the relevant account number.

### 1. Build and publish the example app

First step is build the clone the application code and create and ecr repository and login to the repository
```shell 
git clone https://github.com/mahasiva-amazon/istio-topology-routing-example.git
aws ecr create-repository --repository-name istio-tpr-app --image-scanning-configuration scanOnPush=true
aws ecr get-login-password --region us-west-2 | docker login --username AWS --password-stdin <<replace_with_account_id>>.dkr.ecr.us-west-2.amazonaws.com
```
Next step is to build the app
```shell
cd app
docker build -t istio-tpr-app .
docker tag istio-tpr-app:latest <<replace_with_account_id>>.dkr.ecr.us-west-2.amazonaws.com/istio-tpr-app:v1.0.0
docker push <<replace_with_account_id>>.dkr.ecr.us-west-2.amazonaws.com/istio-tpr-app:v1.0.0
```
Now the app is built and published to the ecr repository. 

### 2. Build the eks cluster,install Istio and the sample application

#### a. Create a EKS cluster to perform data analysis
```shell
cd infra
eksctl create cluster -f eksdtoanalysis.yaml

```

#### b. Enable VPC Flow Logs for the cluster VPC and install CloudWatch dashboards
The flow logs can be used to analyze which type of traffic results in data transfers costs through CloudWatch dashboards
```shell
export CLUSTER_VPC_ID=($(aws ec2 describe-vpcs --region us-west-2  --filters Name="tag:alpha.eksctl.io/cluster-name",Values=dto-analysis-k8scluster | jq -r '.Vpcs[].VpcId'))
export FL_ROLE_ID=($(aws iam create-role --role-name dtoanalysis-fllogs-role --assume-role-policy-document file://flowlogstrustpolicy.json | jq -r '.Role.Arn'))
aws iam put-role-policy --role-name dtoanalysis-fllogs-role --policy-name allow.flowlogs.cloudwatch --policy-document file://allow-cloudwatch-flowlogs.json
aws ec2 create-flow-logs \
    --resource-type VPC \
    --resource-ids ${CLUSTER_VPC_ID} \
    --traffic-type ALL \
    --deliver-logs-permission-arn ${FL_ROLE_ID} \
    --log-destination-type cloud-watch-logs \
    --log-destination  'arn:aws:logs:us-west-2:<<replace_with_account_id>>:log-group:dto-dto-analysis-k8scluster-logs' \
    --log-format '${account-id} ${action} ${az-id} ${bytes} ${dstaddr} ${end} ${dstport} ${flow-direction} ${instance-id} ${interface-id} ${log-status} ${packets} ${pkt-dst-aws-service} ${pkt-dstaddr} ${pkt-srcaddr} ${pkt-src-aws-service} ${protocol} ${region} ${srcaddr} ${srcport} ${start} ${sublocation-id} ${sublocation-type} ${subnet-id} ${traffic-path} ${tcp-flags} ${type} ${version} ${vpc-id}'
./create-dashboard.sh us-west-2 "alpha.eksctl.io/cluster-name" "dto-analysis-k8scluster" dto-analysis-k8scluster dto-dto-analysis-k8scluster-logs dto-analysis-k8scluster-dashboard

```

#### c. Install Istio controller, ingress and egress gateways
```shell
export ISTIO_VERSION="1.10.0"
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=${ISTIO_VERSION} sh -
cd istio-${ISTIO_VERSION}
sudo cp -v bin/istioctl /usr/local/bin/
istioctl version --remote=false
yes | istioctl install --set profile=demo

```

#### d. Create service account with necessary permissions
```shell
eksctl utils associate-iam-oidc-provider --cluster=dto-analysis-k8scluster --approve
APP_POLICY_ARN=`aws iam create-policy --policy-name AppAccessPolicy --policy-document file://msk-cluster-policy.json | jq -r ".Policy.Arn"`
eksctl create iamserviceaccount --cluster=dto-analysis-k8scluster --name=mscrudallow --namespace=octank-travel-ns --attach-policy-arn=$APP_POLICY_ARN --approve

```

#### e. Install the test container
```shell
kubectl run curl-debug --image=radial/busyboxplus:curl -l "type=testcontainer" -n octank-travel-ns -it --tty  sh
#Run curl command in the test container to see which AZ the test container is running in
curl -s 169.254.169.254/latest/meta-data/placement/availability-zone
#exit the test container
exit

```

Expose the curl-debug deployment as service

```shell
kubectl expose deploy curl-debug -n octank-travel-ns --port=80 --target-port=8000
```

#### f. Install the app. 
Make sure to replace the **<<replace_with_account_id>>** in the deployment.yaml with relevant account number
```shell
kubectl apply -f namespace.yaml
kubectl apply -f deployment.yaml
kubectl apply -f services.yaml

```

#### g. Write a startup script in the test container
```shell
kubectl exec -it --tty -n octank-travel-ns $(kubectl get pod -l "type=testcontainer" -n octank-travel-ns -o jsonpath='{.items[0].metadata.name}') sh
#create a startup script
cat <<EOF>> test.sh
n=1
while [ \$n -le 5 ]
do
     curl -s zip-lookup-service-local.octank-travel-ns
     sleep 1
     echo "---"
     n=\$(( n+1 ))
done
EOF
chmod +x test.sh
clear
./test.sh
#exit the test container
exit

```
You should see the lines similar to the ones below displayed in the console.
```shell
CA - 94582 az - us-west-2b---
CA - 94582 az - us-west-2a---
CA - 94582 az - us-west-2b---
CA - 94582 az - us-west-2a---
CA - 94582 az - us-west-2b---
```
As you could see from the output of running the test script that calls from the test container are returning to the "zip-lookup-service" pods running in multiple AZs. This will result in inter-AZ data transfer costs

### 3. Using Istio to avoid inter-AZ data transfers costs for inter-cluster traffic

In order to control inter-AZ data transfer costs for inter cluster traffic, we need to enable topology aware routing within Istio. Topology aware routing is  supported out of the box in Istio for Pod egress traffic, all that is needed is to create a destination rule object and associate it with the relevant service. Let us walk through an example of using Istio to control inter-AZ traffic

#### a. Enable injection of side car containers for the namespace

Update the namespace.yaml to add the label "istio-injection: enabled"

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: octank-travel-ns
  labels:
    istio-injection: enabled
```

Next apply the changes to the namespace. This will not impact existing Pods that are already running, hence scale down the deployment to zero and then scale up.

```shell
kubectl apply -f namespace.yaml
kubectl get po -n octank-travel-ns

```

The console should be should be similar to below

```shell
zip-lookup-service-deployment-645d5c8df5-4nbfp   1/1     Running   0          136m
zip-lookup-service-deployment-645d5c8df5-mnpgs   1/1     Running   0          136m
zip-lookup-service-deployment-645d5c8df5-vvnh4   1/1     Running   0          136m
```

The number of containers per pod is "1", hence let us scale down the deployment and then scale it up.

```shell
kubectl get deploy -n octank-travel-ns
kubectl scale deploy zip-lookup-service-deployment -n octank-travel-ns --replicas=0
kubectl scale deploy zip-lookup-service-deployment -n octank-travel-ns --replicas=3
kubectl get po -n octank-travel-ns

```

The console should be should be similar to below

```shell
zip-lookup-service-deployment-645d5c8df5-rm6pb   2/2     Running   0          3m37s
zip-lookup-service-deployment-645d5c8df5-t5dr7   2/2     Running   0          3m37s
zip-lookup-service-deployment-645d5c8df5-tt92m   2/2     Running   0          3m37s
```
The number of containers per pod is "2" as the side cars have been injected.

Perform the scale down and scale up for the test container to ensure side car is injected to the test container also.

```shell
kubectl get deploy -n octank-travel-ns
kubectl scale deploy curl-debug -n octank-travel-ns --replicas=0
kubectl scale deploy curl-debug -n octank-travel-ns --replicas=1
kubectl get po -n octank-travel-ns

```

The console should be should be similar to below

```shell
curl-debug-86c79f68c4-vdwff                      2/2     Running       0          6s
```

Ensure the test scripts are installed again in the newly created test container

```shell
kubectl exec -it --tty -n octank-travel-ns $(kubectl get pod -l "type=testcontainer" -n octank-travel-ns -o jsonpath='{.items[0].metadata.name}') sh
#create a startup script
cat <<EOF>> test.sh
n=1
while [ \$n -le 5 ]
do
     curl -s zip-lookup-service-local.octank-travel-ns
     sleep 1
     echo "---"
     n=\$(( n+1 ))
done
EOF
chmod +x test.sh
#exit the test container
exit

```

#### b. Enable topology aware routing 

To enable topology aware routing, we need to create a destination rule and link it to the zip-lookup-service-local

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: DestinationRule
metadata:
  name: zip-lookup-service-local
  namespace: octank-travel-ns
spec:
  host: zip-lookup-service-local
  trafficPolicy:
    outlierDetection:
      consecutiveErrors: 7
      interval: 30s
      baseEjectionTime: 30s
```

```shell
kubectl apply -f destinationrule.yaml
    
```

Let us log back into the test container to validate 

```shell
kubectl exec -it --tty -n octank-travel-ns $(kubectl get pod -l "type=testcontainer" -n octank-travel-ns -o jsonpath='{.items[0].metadata.name}') sh
    
```

Run the following commands in the test container

```shell
curl -s 169.254.169.254/latest/meta-data/placement/availability-zone
./test.sh
exit

```

The console output should show all traffic going to the same AZ

```shell
CA - 94582 az - us-west-2a---
CA - 94582 az - us-west-2a---
CA - 94582 az - us-west-2a---
CA - 94582 az - us-west-2a---
CA - 94582 az - us-west-2a---
```

As you could see, the calls are going to the Pods in the same AZ whereas earlier the calls were distributed across multiple AZs where the pods were running. This means that topology aware routing is sucessful for Pod to Pod communication and will result in **significant** cost saves in terms data transfer costs.

### 3. Using Istio to avoid inter-AZ data transfers costs for calls to AWS services

In the earlier section, we looked into how we can enable topology aware routing at Kubernetes service level. In this section, we can focus on how we can perform topology aware routing for external services and AWS services.

#### Topology aware routing for AWS services

In case of AWS services, it is a best practice to leverage VPC endpoints to communicate to the AWS Service from the VPC. When VPC Endpoints are generated, a regional endpoint and AZ specific endpoints are generated. The endpoints are DNS names that map back to ENIs created in the VPC to facilate communication with AWS service directly without using Internet or NAT gateways. These ENIs are typically created across one or more AZs. 

When we configure a Pod with a regional endpoint, the endpoint may resolve one of the AZ specific ENIs and depending which AZ the Pod is running there may inter-AZ costs when using regional VPC endpoints. We cannot use the AZ specific endpoints because the Pod can relocated to any node in any AZ by the Kubernetes scheduler.

So in order to address this issue, we can leverage Istio's Service Entry objects to enable topology aware routing to AWS service VPC endpoints.

##### i. AWS Services with no VPC Enpoint 

RDS sevice does not require VPC endpoints, however there are DB primary and secondary nodes (read replicas) which are AZ specific. Hence we need to have mechanism to configure the Pods to route read calls specially to one of the DB instances, primary or secondary, depending on the AZ of the Pod.

Let us start by creating an Aurora MySQL RDS database server for testing purpose with a reader enpoint.

```shell
export CLUSTER_SG_ID=($(aws eks describe-cluster --name dto-analysis-k8scluster | jq -r '.cluster.resourcesVpcConfig.clusterSecurityGroupId'))
echo $CLUSTER_SG_ID
export CLUSTER_SUBNET_1=($(aws ec2 describe-subnets --region us-west-2  --filters Name="vpc-id",Values=${CLUSTER_VPC_ID} Name="availability-zone",Values=us-west-2a | jq -r '.Subnets[].SubnetId'))
export CLUSTER_SUBNET_2=($(aws ec2 describe-subnets --region us-west-2  --filters Name="vpc-id",Values=${CLUSTER_VPC_ID} Name="availability-zone",Values=us-west-2b | jq -r '.Subnets[].SubnetId'))
echo $CLUSTER_SUBNET_1 $CLUSTER_SUBNET_2
aws rds create-db-subnet-group --db-subnet-group-name default-subnet-group --db-subnet-group-description "test DB subnet group" --subnet-ids "$CLUSTER_SUBNET_1" "$CLUSTER_SUBNET_2"
aws rds create-db-cluster --db-cluster-identifier dto-analysis-k8scluster-rds --engine aurora-mysql --engine-version 5.7.12 --master-username master --master-user-password secret99 --db-subnet-group-name default-subnet-group --vpc-security-group-ids $CLUSTER_SG_ID
aws rds create-db-instance --db-instance-identifier write-instance --db-cluster-identifier dto-analysis-k8scluster-rds --engine aurora-mysql --db-instance-class db.r5.large
aws rds create-db-instance --db-instance-identifier read-instance --db-cluster-identifier dto-analysis-k8scluster-rds --engine aurora-mysql --db-instance-class db.r5.large --availability-zone us-west-2b
export PRIMARY_EP=($(aws rds describe-db-clusters --db-cluster-identifier dto-analysis-k8scluster-rds | jq -r '.DBClusters[].Endpoint'))
export READER_EP=($(aws rds describe-db-clusters --db-cluster-identifier dto-analysis-k8scluster-rds | jq -r '.DBClusters[].ReaderEndpoint'))
echo $PRIMARY_EP
echo $READER_EP
```

Next, we need to define service entry object for the RDS instance with relevant endpoints

```yaml
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
 name: external-svc-rds
 namespace: octank-travel-ns
spec:
 hosts:
 - $PRIMARY_EP
 location: MESH_EXTERNAL
 ports:
 - number: 3305
   name: tcp
   protocol: tcp
 resolution: DNS
 endpoints:
 - address: $PRIMARY_EP
   locality: us-west-2/us-west-2a
   ports:
     tcp: 3306
 - address: $READER_EP
   locality: us-west-2/us-west-2b
   ports:
     tcp: 3306
```

Next, we need to define destination rule object to enable topology aware routing when connecting to the RDS instances

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
 name: external-svc-rds-dr
 namespace: octank-travel-ns
spec:
 host: $PRIMARY_EP
 trafficPolicy:
   outlierDetection:
     consecutive5xxErrors: 1
     interval: 15s
     baseEjectionTime: 1m
```

Next, we need to apply the service entry and destination rule objects.

```shell
#created a single file with the service entry and destination rule object
cat <<EOF> rds-se.yaml
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
 name: external-svc-rds
 namespace: octank-travel-ns
spec:
 hosts:
 - $PRIMARY_EP
 location: MESH_EXTERNAL
 ports:
 - number: 3305
   name: tcp
   protocol: tcp
 resolution: DNS
 endpoints:
 - address: $PRIMARY_EP
   locality: us-west-2/us-west-2a
   ports:
     tcp: 3306
 - address: $READER_EP
   locality: us-west-2/us-west-2b
   ports:
     tcp: 3306
---
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
 name: external-svc-rds-dr
 namespace: octank-travel-ns
spec:
 host: $PRIMARY_EP
 trafficPolicy:
   outlierDetection:
     consecutive5xxErrors: 1
     interval: 15s
     baseEjectionTime: 1m
EOF
kubectl apply -f rds-se.yaml

```

Next, we need to validate the configuration. For that we need to ensure we are logging in to a Pod that is running in us-west-2b. In this case, the ***.items[0].metadata.name*** represents a Pod running in us-west-2b but in your case it may be different. Hence trying running with different number e.g. ***.items[1].metadata.name*** and checking AZ through ***curl -s 169.254.169.254/latest/meta-data/placement/availability-zone*** until you land on a Pod in the us-west-2b AZ.

```shell
kubectl exec -it --tty -n octank-travel-ns $(kubectl get pod -l "app=zip-lookup-service" -n octank-travel-ns -o jsonpath='{.items[0].metadata.name}') sh
curl -s 169.254.169.254/latest/meta-data/placement/availability-zone
exit

````

Next we need to monitor the Istio proxy logs associated with the Pod we selected. This is to see where the egress traffic is landing. Perform the below operation in a seperate terminal

```shell
kubectl logs $(kubectl get pod -l "app=zip-lookup-service" -n octank-travel-ns -o jsonpath='{.items[0].metadata.name}') -n octank-travel-ns -c istio-proxy -f

```

Next let us trying running a curl command to see the check the egrees traffic logs in the Istio proxy container

```shell
echo $PRIMARY_EP
kubectl exec -it --tty -n octank-travel-ns $(kubectl get pod -l "app=zip-lookup-service" -n octank-travel-ns -o jsonpath='{.items[0].metadata.name}') sh
curl <<replace_with_primary_endpoint_url>>:3305
exit
dig $READER_EP
```

You should a ouput to similar to below in the terminal where you're monitoring logs

```shell
[2021-12-14T18:59:41.553Z] "- - -" 0 - - - "-" 145 109 2 - "-" "-" "-" "-" "X.X.X.X:3306" outbound|3305||<<primary_endpoint_url>> 1.1.1.1:37162 X.X.X.X:3305 1.1.1.1:34828 - -
```

The IP address of the reader database instance shown the by dig command and IP address in the Istio proxy logs should match which means that we are able to route traffic to db instance in right availability using topology aware routing feature of Istio.

This example show how we can leverage topology aware routing for RDS but we can extend same mechanism to route traffic to any endpoint in the cluster VPC or any other VPCs connected to the cluster VPC.  

##### ii. AWS Services with VPC Enpoints

In case of VPC endpoints, the same mechanism as earlier is used but we use the regional VPC endpoint as the primary in our service entry objects. An example of S3 VPC will look as follows

```yaml
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
 name: external-svc-s3
 namespace: octank-travel-ns
spec:
 hosts:
 - <<replace_with_s3_regional_endpoint>>
 location: MESH_EXTERNAL
 ports:
 - number: 443
   name: https
   protocol: TLS
 resolution: DNS
 endpoints:
 - address: <<replace_with_s3_us-west-2a_endpoint>>
   locality: us-west-2/us-west-2a
   ports:
     https: 443
 - address: <<replace_with_s3_us-west-2b_endpoint>>
   locality: us-west-2/us-west-2b
   ports:
     https: 443
---
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
 name: external-svc-rds-dr
 namespace: octank-travel-ns
spec:
 host: <<replace_with_s3_regional_endpoint>>
 trafficPolicy:
   outlierDetection:
     consecutive5xxErrors: 1
     interval: 15s
     baseEjectionTime: 1m
```

### Conclusion

In EKS cluster, data transfers costs can become a significant driver of costs. Hence we need to monitor the costs and have solutions in place to address them. In this example, we showcased how Istio can leveraged to address your data transfer costs. Along with Istio, we also recommend following best practices specified in the blog <<blogurl-TBD>> to address data transfer costs.


