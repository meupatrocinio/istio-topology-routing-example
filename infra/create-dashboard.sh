CLUSTER_REGION=$1
VPC_FILTER_TAG=$2
VPC_FILTER_VALUE=$3
CLUSTER_NAME=$4
ANALYSIS_LOG_GROUP=$5
DASHBOARD_NAME=$6


function initQuery() {
   QUERY="fields @message | \
   parse @message \\\"* * * * * * * * * * * * * * * * * * * * * * * * * * * * *\\\"  as account_id, action, az_id, bytes, dstaddr, dstport, end, flow_direction, instance_id, interface_id, log_status, packets, pkt_dst_aws_service, pkt_dstaddr, pkt_srcaddr, pkt_src_aws_service, protocol, region, srcaddr, srcport, start, sublocation_id, sublocation_type, subnet_id, tcp_flags, traffic_path, type, version, vpc_id \
   | filter "
}

function processENIs() {
   #echo "Got ENIs $1"
   ENIs=$1
   i=0
   for eni in $ENIs
   do
       i=$((i+1))
      #echo "Processing '$eni'"
      if [ $i -eq 1 ]; then
         QUERY="$QUERY ( interface_id = '$eni'"
      else
         QUERY="$QUERY or interface_id = '$eni'"
      fi
   done
   QUERY="$QUERY )"
}

function processExcludeENIs() {
   #echo "Got ENIs $1"
   ENIs=$1
   i=0
   for eni in $ENIs
   do
       i=$((i+1))
      #echo "Processing '$eni'"
      if [ $i -eq 1 ]; then
         QUERY="$QUERY ( interface_id != '$eni'"
      else
         QUERY="$QUERY and interface_id != '$eni'"
      fi
   done
   QUERY="$QUERY )"
}

function processExcludeIPSubQuery() {
   #echo "Got ENIs $1"
   IPs=$1
   i=0
   for ip in $IPs
   do
      i=$((i+1))
      #echo "Processing ip (exclude) '$ip'"
      if [ $i -eq 1 ]; then
         QUERY="$QUERY ( (!isIpInSubnet(pkt_srcaddr,'$ip/32') and !isIpInSubnet(pkt_dstaddr,'$ip/32'))"
      else
          QUERY="$QUERY and (!isIpInSubnet(pkt_srcaddr,'$ip/32') and !isIpInSubnet(pkt_dstaddr,'$ip/32'))"
      fi
   done
   QUERY="$QUERY )"
}

function processIPSubQuery() {
   #echo "Got ENIs $1"
   IPs=$1
   i=0
   for ip in $IPs
   do
      i=$((i+1))
      echo "Processing ip (include) '$ip'"
      if [ $i -eq 1 ]; then
         QUERY="$QUERY ( (isIpInSubnet(pkt_srcaddr,'$ip/32') or isIpInSubnet(pkt_dstaddr,'$ip/32'))"
      else
          QUERY="$QUERY or (isIpInSubnet(pkt_srcaddr,'$ip/32') or isIpInSubnet(pkt_dstaddr,'$ip/32'))"
      fi
   done
   QUERY="$QUERY )"
}

function processCallsSubQuery() {
   #echo "Got ENIs $1"
   IPs=$1
   i=0
   for ip in $IPs
   do
      i=$((i+1))
      echo "Processing ip (include) '$ip'"
      if [ $i -eq 1 ]; then
         QUERY="$QUERY ( isIpInSubnet(pkt_srcaddr,'$ip/32')"
      else
          QUERY="$QUERY or isIpInSubnet(pkt_srcaddr,'$ip/32')"
      fi
   done
   QUERY="$QUERY )"
}

function addWidgets() {
   export X_CORD=$1
   export Y_CORD=$2
   export LOG_GROUP=$ANALYSIS_LOG_GROUP
   export WIDGET_TITLE=$3
   export VIEW=$4
   export WIDTH=$5
   export HEIGHT=$6
   if [ $7 == 'true' ]; then
      export WDGS="$(eval "echo \"$(<cw-logwidget.template)\"")"
   else
      export WDGS="${WDGS},$(eval "echo \"$(<cw-logwidget.template)\"")"
   fi
}

function addTimeSeriesVisalization() {
   export QUERY="$QUERY | stats sum(bytes)/1024/1024 as total_trnsfred_data_in_mb by bin(1m)"
}

function addTimeSeriesVisalizationForCalls() {
   range=$1
   export QUERY="$QUERY | stats count(*)/$range as total_calls_counts by bin(1m)"
}

function includeCIDRs() {
   echo "Got CIDRs $1"
   CIDRs=$1
   i=0
   for cidr in $CIDRs
   do
      i=$((i+1))
      echo "Processing cidr (include) '$cidr'"
      if [ $i -eq 1 ]; then
         QUERY="$QUERY ( (isIpInSubnet(pkt_srcaddr,'$cidr') and isIpInSubnet(pkt_dstaddr,'$cidr'))"
      else
         QUERY="$QUERY or (isIpInSubnet(pkt_srcaddr,'$cidr') and isIpInSubnet(pkt_dstaddr,'$cidr'))"
      fi
   done
   QUERY="$QUERY )"
}

function includeCIDRsInclusive() {
   echo "Got CIDRs $1"
   CIDRs=$1
   i=0
   for cidr in $CIDRs
   do
      i=$((i+1))
      echo "Processing cidr (include) '$cidr'"
      if [ $i -eq 1 ]; then
         QUERY="$QUERY ( (isIpInSubnet(pkt_srcaddr,'$cidr') or isIpInSubnet(pkt_dstaddr,'$cidr'))"
      else
         QUERY="$QUERY or (isIpInSubnet(pkt_srcaddr,'$cidr') or isIpInSubnet(pkt_dstaddr,'$cidr'))"
      fi
   done
   QUERY="$QUERY )"
}

function processInterAZIPQuery() {
   echo "${subnets[@]}"
   i=0
   AZ_QRY=""
   AZ_FILTER=""
   for cidr in ${subnets[@]}
   do
      i=$((i+1))
      #echo "Subnet cidr ${cidr}"
      if [ $i -eq 1 ]; then
         AZ_QRY="fields isIpInSubnet(pkt_dstaddr,'$cidr') or isIpInSubnet(pkt_dstaddr,'$cidr') as dst_$i"
         AZ_QRY="$AZ_QRY | fields isIpInSubnet(pkt_srcaddr,'$cidr') or isIpInSubnet(pkt_srcaddr,'$cidr') as src_$i"
         AZ_FILTER="| filter ((dst_$i and !src_$i) or (!src_$i and dst_$i))"
      else
         AZ_QRY="$AZ_QRY | fields isIpInSubnet(pkt_dstaddr,'$cidr') or isIpInSubnet(pkt_dstaddr,'$cidr' as dst_$i"
         AZ_QRY="$AZ_QRY | fields isIpInSubnet(pkt_srcaddr,'$cidr') or isIpInSubnet(pkt_srcaddr,'$cidr') as src_$i"
         AZ_FILTER="$AZ_FILTER or ((dst_$i and !src_$i) or (!src_$i and dst_$i))"
      fi
   done
   #echo "${AZ_QRY}"
   #echo "${AZ_FILTER}"
   QUERY="$QUERY $AZ_QRY $AZ_FILTER"
}

export CLUSTER_VPC_ID=($(aws ec2 describe-vpcs --region $CLUSTER_REGION  --filters Name="tag:${VPC_FILTER_TAG}",Values=${VPC_FILTER_VALUE} | jq -r '.Vpcs[].VpcId'))
echo "Identified VPC ${CLUSTER_VPC_ID} for traffic analysis..."

#aws ec2 describe-nat-gateways --filter Name="vpc-id",Values=${CLUSTER_VPC_ID} --output json 
#aws ec2 describe-nat-gateways --filter Name="vpc-id",Values=${CLUSTER_VPC_ID} --output json | jq -r '.NatGateways[].NatGatewayAddresses[] | .PrivateIp,.PublicIp'
export NAT_IPS="$(aws ec2 describe-nat-gateways --filter Name="vpc-id",Values=${CLUSTER_VPC_ID} --output json | jq -r '.NatGateways[].NatGatewayAddresses[] | .PrivateIp,.PublicIp')"
echo "Identified NAT IPs - '$NAT_IPS'"
export NAT_ENIS="$(aws ec2 describe-nat-gateways --filter Name="vpc-id",Values=${CLUSTER_VPC_ID} --output json | jq -r '.NatGateways[].NatGatewayAddresses[] | .NetworkInterfaceId')"
echo "Identified NAT ENIs - '$NAT_ENIS'"

initQuery
processENIs "${NAT_ENIS}"
QUERY="$QUERY and "
processExcludeIPSubQuery "${NAT_IPS}"
addTimeSeriesVisalization
addWidgets 0 0 "Cluster NAT Traffic" "timeSeries" 12 6 "true"

#aws ec2 describe-network-interfaces --filter Name="description",Values="Amazon EKS ${CLUSTER_NAME}" --output json
export CLUSTER_ENI="$(aws ec2 describe-network-interfaces --filter Name="description",Values="Amazon EKS ${CLUSTER_NAME}" --output json | jq -r '.NetworkInterfaces[] | .NetworkInterfaceId')"
echo "${CLUSTER_ENI}"

initQuery
processENIs "${CLUSTER_ENI}"
addTimeSeriesVisalization
addWidgets 13 0 "Cluster ENI Traffic" "timeSeries" 12 6 "false"

export VPC_CIDR=($(aws ec2 describe-vpcs --region $CLUSTER_REGION  --filters Name="vpc-id",Values=${CLUSTER_VPC_ID} | jq -r '.Vpcs[].CidrBlock'))
echo "VPC cidr ${VPC_CIDR}"
export CLUSTER_AZS=($(aws ec2 describe-availability-zones --query 'AvailabilityZones[].ZoneName' --output text --region $CLUSTER_REGION))
echo "Identified AZs - ${CLUSTER_AZS[2]} ${CLUSTER_AZS[1]} ${CLUSTER_AZS[2]}"
i=0
for az in ${CLUSTER_AZS[@]} 
do
   echo "AZ is ${az}"
   #aws ec2 describe-subnets --region $CLUSTER_REGION  --filters Name="vpc-id",Values=${CLUSTER_VPC_ID} Name="availability-zone",Values=${az}| jq -r '.Subnets[] | .CidrBlock'
   subnets[$i]="$(aws ec2 describe-subnets --region $CLUSTER_REGION  --filters Name="vpc-id",Values=${CLUSTER_VPC_ID} Name="availability-zone",Values=${az}| jq -r '.Subnets[] | .CidrBlock')"
   i=$((i+1))
done

initQuery
processENIs "${CLUSTER_ENI}"
QUERY="$QUERY | filter "
includeCIDRs "${VPC_CIDR}"
QUERY="$QUERY | "
processInterAZIPQuery
addTimeSeriesVisalizationForCalls 1
addWidgets 0 7 "Inter AZ Calls Cluster ENI" "timeSeries" 24 6 "false"

#echo "${subnets[@]}"
initQuery
#processExcludeENIs "${CLUSTER_ENI}"
#QUERY="$QUERY | "
includeCIDRs "${VPC_CIDR}"
QUERY="$QUERY | "
processInterAZIPQuery
addTimeSeriesVisalization
addWidgets 0 14 "Inter AZ Traffic" "timeSeries" 12 6 "false"

initQuery
#processExcludeENIs "${CLUSTER_ENI}"
#QUERY="$QUERY | "
includeCIDRs "${VPC_CIDR}"
QUERY="$QUERY | "
processInterAZIPQuery
addTimeSeriesVisalizationForCalls 1
addWidgets 13 14 "Inter AZ Calls" "timeSeries" 12 6 "false"

POD_IPS="$(kubectl get po -A -o json | jq -r '.items[] | . as $parent | select(.metadata.name|startswith("coredns")) | $parent.status.podIP')"
echo "$POD_IPS"
initQuery
processIPSubQuery "${POD_IPS}"
QUERY="$QUERY | filter "
includeCIDRs "${VPC_CIDR}"
QUERY="$QUERY | "
processInterAZIPQuery
addTimeSeriesVisalization
addWidgets 0 21 "Inter AZ Traffic CoreDNS" "timeSeries" 12 6 "false"

initQuery
processCallsSubQuery "${POD_IPS}"
QUERY="$QUERY | filter "
includeCIDRs "${VPC_CIDR}"
QUERY="$QUERY | "
processInterAZIPQuery
addTimeSeriesVisalizationForCalls 1
addWidgets 13 21 "Inter AZ Calls CoreDNS" "timeSeries" 12 6 "false"

POD_IPS="$(kubectl get po -A -o json | jq -r '.items[] | . as $parent | select(.metadata.name|startswith("zip-lookup-service")) | $parent.status.podIP')"
echo "$POD_IPS"
initQuery
processIPSubQuery "${POD_IPS}"
QUERY="$QUERY | filter "
includeCIDRs "${VPC_CIDR}"
QUERY="$QUERY | "
processInterAZIPQuery
addTimeSeriesVisalization
addWidgets 0 28 "Inter AZ Traffic Zip App" "timeSeries" 12 6 "false"

initQuery
processCallsSubQuery "${POD_IPS}"
QUERY="$QUERY | filter "
includeCIDRs "${VPC_CIDR}"
QUERY="$QUERY | "
processInterAZIPQuery
addTimeSeriesVisalizationForCalls 1
addWidgets 13 28 "Inter AZ Calls Zip App" "timeSeries" 12 6 "false"

export DSB="$(eval "echo \"$(<cw-dashboard.template)\"")"
echo "$DSB"
aws cloudwatch put-dashboard --dashboard-name $DASHBOARD_NAME --dashboard-body "${DSB}"

