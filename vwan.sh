#!/bin/bash

# hacked from ...
# https://github.com/dmauser/azure-virtualwan/tree/main/svh-ri-inter-region
# cngfw only supported in certain regions
# https://docs.paloaltonetworks.com/cloud-ngfw/azure/cloud-ngfw-for-azure/getting-started-with-cngfw-for-azure/supported-regions-and-zones

if [ $# -ne 3 ]
  then
    echo "No enough arguments provided. Example: ./vwan.sh <Resource Group> <Region 1> <Region 2>"
    exit 1
fi
az login
# Parameters (make changes based on your requirements)
rg=$1      #set resource group
region1=$2 #set region1
region2=$3 #set region2

vwanname=vwan-lab #set vWAN name
hub1name=$region1-vhub #set Hub1 name
hub2name=$region2-vhub #set Hub2 name
username=azureuser #set username
echo "The password length must be between 12 and 72. Password must have the 3 of the following: 1 lower case character, 1 upper case character, 1 number and 1 special character."
read -s -p "Password: " PASSWORD
password=$PASSWORD
vmsize=Standard_B1s #set VM Size
subscription_id=$(az account show --query id | tr -d '"')

# Pre-Requisites

# Check if virtual wan extension is installed if not install it
if ! az extension list | grep -q virtual-wan; then
    echo "virtual-wan extension is not installed, installing it now..."
    az extension add --name virtual-wan --only-show-errors
fi

if ! az extension list | grep -q palo-alto-networks; then
    echo "palo-alto-networks extension is not installed, installing it now..."
    az extension add --name palo-alto-networks --only-show-errors
fi

start=`date +%s`
echo "Script started at $(date)"

#Variables
mypip=$(curl -4 ifconfig.io -s)

# create rg
az group create -n $rg -l $region1 --output none

echo Creating vwan and both hubs...
#  create virtual wan
az network vwan create -g $rg -n $vwanname --branch-to-branch-traffic true --location $region1 --type Standard --output none
az network vhub create -g $rg --name $hub1name --address-prefix 10.251.0.0/21 --vwan $vwanname --location $region1 --sku Standard --no-wait
az network vhub create -g $rg --name $hub2name --address-prefix 10.252.0.0/21 --vwan $vwanname --location $region2 --sku Standard --no-wait

echo Creating spoke VNETs...
# create spokes virtual network
# Region1
az network vnet create --address-prefixes 172.16.1.0/24 -n spoke1 -g $rg -l $region1 --subnet-name subnet1 --subnet-prefixes 172.16.1.0/27 --output none
az network vnet create --address-prefixes 172.16.2.0/24 -n spoke2 -g $rg -l $region1 --subnet-name subnet2 --subnet-prefixes 172.16.2.0/27 --output none
# Region2
az network vnet create --address-prefixes 172.16.3.0/24 -n spoke3 -g $rg -l $region2 --subnet-name subnet3 --subnet-prefixes 172.16.3.0/27 --output none
az network vnet create --address-prefixes 172.16.4.0/24 -n spoke4 -g $rg -l $region2 --subnet-name subnet4 --subnet-prefixes 172.16.4.0/27 --output none

echo Creating VMs in Region 1
# create a VM in each spoke
az vm create -n spoke1VM  -g $rg --image ubuntults --public-ip-sku Standard --size $vmsize -l $region1 --subnet subnet1 --vnet-name spoke1 --admin-username $username --admin-password $password --nsg "" --no-wait --only-show-errors
az vm create -n spoke2VM  -g $rg --image ubuntults --public-ip-sku Standard --size $vmsize -l $region1 --subnet subnet2 --vnet-name spoke2 --admin-username $username --admin-password $password --nsg "" --no-wait --only-show-errors

echo Creating VMs in Region 2
# create a VM in each spoke
az vm create -n spoke3VM  -g $rg --image ubuntults --public-ip-sku Standard --size $vmsize -l $region2 --subnet subnet3 --vnet-name spoke3 --admin-username $username --admin-password $password --nsg "" --no-wait --only-show-errors
az vm create -n spoke4VM  -g $rg --image ubuntults --public-ip-sku Standard --size $vmsize -l $region2 --subnet subnet4 --vnet-name spoke4 --admin-username $username --admin-password $password --nsg "" --no-wait --only-show-errors

# Continue only if all VMs are created
echo Waiting VMs to complete provisioning...
az vm wait -g $rg --created --ids $(az vm list -g $rg --query '[].{id:id}' -o tsv) --only-show-errors -o none
#Enabling boot diagnostics for all VMs in the resource group 
echo Enabling boot diagnostics for all VMs in the resource group...
# enable boot diagnostics for all VMs in the resource group
az vm boot-diagnostics enable --ids $(az vm list -g $rg --query '[].{id:id}' -o tsv) -o none
### Installing tools for networking connectivity validation such as traceroute, tcptraceroute, iperf and others (check link below for more details) 
echo Installing tools for networking connectivity validation such as traceroute, tcptraceroute, iperf and others...
nettoolsuri="https://raw.githubusercontent.com/dmauser/azure-vm-net-tools/main/script/nettools.sh"
for vm in `az vm list -g $rg --query "[?storageProfile.imageReference.offer=='UbuntuServer'].name" -o tsv`
do
 az vm extension set \
 --resource-group $rg \
 --vm-name $vm \
 --name customScript \
 --publisher Microsoft.Azure.Extensions \
 --protected-settings "{\"fileUris\": [\"$nettoolsuri\"],\"commandToExecute\": \"./nettools.sh\"}" \
 --no-wait
done

echo Checking Hub1 provisioning status...
# Checking Hub1 provisioning and routing state 
prState=''
rtState=''

while [[ $prState != 'Succeeded' ]];
do
    prState=$(az network vhub show -g $rg -n $hub1name --query 'provisioningState' -o tsv)
    echo "$hub1name provisioningState="$prState
    sleep 5
done

while [[ $rtState != 'Provisioned' ]];
do
    rtState=$(az network vhub show -g $rg -n $hub1name --query 'routingState' -o tsv)
    echo "$hub1name routingState="$rtState
    sleep 5
done

while [[ $prState != 'Succeeded' ]];
do
    prState=$(az network vhub show -g $rg -n $hub2name --query 'provisioningState' -o tsv)
    echo "$hub2name provisioningState="$prState
    sleep 5
done

while [[ $rtState != 'Provisioned' ]];
do
    rtState=$(az network vhub show -g $rg -n $hub2name --query 'routingState' -o tsv)
    echo "$hub2name routingState="$rtState
    sleep 5
done

echo Creating Cloud NGFW Public IPs
    az network public-ip create -n $hub1name-cngfw-pip -g $rg --location $region1 --sku Standard --output none --zone 1 2 3 
    az network public-ip create -n $hub2name-cngfw-pip -g $rg --location $region2 --sku Standard --output none --zone 1 2 3
    hub1_cngfw_pip=$(az network public-ip show -n $hub1name-cngfw-pip -g $rg --query ipAddress | tr -d '"')
    hub2_cngfw_pip=$(az network public-ip show -n $hub2name-cngfw-pip -g $rg --query ipAddress | tr -d '"')

echo Creating Local Rulestacks...

    az palo-alto cloudngfw local-rulestack create -g $rg -n $hub1name-rulestack --identity "{type:None}" --location $region1 --default-mode IPS --description "Hub 1 Local Rulestack" --min-app-id-version "8595-7473" --scope "LOCAL" --security-services "{vulnerability-profile:BestPractice,anti-spyware-profile:BestPractice,anti-virus-profile:BestPractice,url-filtering-profile:BestPractice,file-blocking-profile:BestPractice,dns-subscription:BestPractice}"
    az palo-alto cloudngfw local-rulestack create -g $rg -n $hub2name-rulestack --identity "{type:None}" --location $region2 --default-mode IPS --description "Hub 2 Local Rulestack" --min-app-id-version "8595-7473" --scope "LOCAL" --security-services "{vulnerability-profile:BestPractice,anti-spyware-profile:BestPractice,anti-virus-profile:BestPractice,url-filtering-profile:BestPractice,file-blocking-profile:BestPractice,dns-subscription:BestPractice}"

sleep 5

echo Creating Cloud NGFW in Hub1...
    az network virtual-appliance create --name $hub1name-cngfw-nva --resource-group $rg --location $region1 --vhub /subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/$hub1name --delegation "{service-name:PaloAltoNetworks.Cloudngfw/firewalls}"
    az palo-alto cloudngfw firewall create --name $hub1name --resource-group $rg --location $region1 --dns-settings "{enable-dns-proxy:DISABLED,enabled-dns-type:CUSTOM}" --marketplace-details "{marketplace-subscription-status:Subscribed,offer-id:pan_swfw_cloud_ngfw,publisher-id:paloaltonetworks}" --plan-data "{billing-cycle:MONTHLY,plan-id:panw-cloud-ngfw-payg,usage-type:PAYG}" --is-panorama-managed FALSE --associated-rulestack "{location:$region1,resource-id:/subscriptions/$subscription_id/resourceGroups/$rg/providers/PaloAltoNetworks.Cloudngfw/localRulestacks/$hub1name-rulestack}" --network-profile "{network-type:VWAN,public-ips:[{address:$hub1_cngfw_pip,resource-id:/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/publicIPAddresses/$hub1name-cngfw-pip}],vwan-configuration:{v-hub:{resource-id:/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/$hub1name},network-virtual-appliance-id:/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/networkVirtualAppliances/$hub1name-cngfw-nva},enable-egress-nat:DISABLED}"

echo Creating Cloud NGFW in Hub2...
    az network virtual-appliance create --name $hub2name-cngfw-nva --resource-group $rg --location $region2 --vhub /subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/$hub2name --delegation "{service-name:PaloAltoNetworks.Cloudngfw/firewalls}"
    az palo-alto cloudngfw firewall create --name $hub2name --resource-group $rg --location $region2 --dns-settings "{enable-dns-proxy:DISABLED,enabled-dns-type:CUSTOM}" --marketplace-details "{marketplace-subscription-status:Subscribed,offer-id:pan_swfw_cloud_ngfw,publisher-id:paloaltonetworks}" --plan-data "{billing-cycle:MONTHLY,plan-id:panw-cloud-ngfw-payg,usage-type:PAYG}" --is-panorama-managed FALSE --associated-rulestack "{location:$region2,resource-id:/subscriptions/$subscription_id/resourceGroups/$rg/providers/PaloAltoNetworks.Cloudngfw/localRulestacks/$hub2name-rulestack}" --network-profile "{network-type:VWAN,public-ips:[{address:$hub2_cngfw_pip,resource-id:/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/publicIPAddresses/$hub2name-cngfw-pip}],vwan-configuration:{v-hub:{resource-id:/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/$hub2name},network-virtual-appliance-id:/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/networkVirtualAppliances/$hub2name-cngfw-nva},enable-egress-nat:DISABLED}"

echo Creating Hub1 vNET connections
# create spoke to Vwan connections to hub1
az network vhub connection create -n spoke1conn --remote-vnet spoke1 -g $rg --vhub-name $hub1name --no-wait
az network vhub connection create -n spoke2conn --remote-vnet spoke2 -g $rg --vhub-name $hub1name --no-wait

prState=''
while [[ $prState != 'Succeeded' ]];
do
    prState=$(az network vhub connection show -n spoke1conn --vhub-name $hub1name -g $rg  --query 'provisioningState' -o tsv)
    echo "vnet connection spoke1conn provisioningState="$prState
    sleep 5
done

# create spoke to Vwan connections to hub2
az network vhub connection create -n spoke3conn --remote-vnet spoke3 -g $rg --vhub-name $hub2name --no-wait
az network vhub connection create -n spoke4conn --remote-vnet spoke4 -g $rg --vhub-name $hub2name --no-wait

prState=''
while [[ $prState != 'Succeeded' ]];
do
    prState=$(az network vhub connection show -n spoke2conn --vhub-name $hub2name -g $rg  --query 'provisioningState' -o tsv)
    echo "vnet connection spoke4conn provisioningState="$prState
    sleep 5
done

echo Creating Log Analytics Workspace...
    az monitor log-analytics workspace create -g $rg -n cngfw-law --location $region1
    workspace=$(az monitor log-analytics workspace show --name cngfw-law --resource-group $rg --query customerId | tr -d '"')
    primaryKey=$(az monitor log-analytics workspace get-shared-keys --resource-group $rg --workspace-name cngfw-law --query "primarySharedKey" | tr -d '"')
    secondaryKey=$(az monitor log-analytics workspace get-shared-keys --resource-group $rg --workspace-name cngfw-law --query "secondarySharedKey" | tr -d '"')

prState=''

echo Checking Cloud NGFW in $region1 provisioning status...
    while [[ $prState != 'Succeeded' ]];
    do
        prState=$(az palo-alto cloudngfw firewall show --firewall-name $hub1name -g $rg --query 'provisioningState' -o tsv)
        echo "Cloud NGFW provisioningState="$prState
        echo "Waiting for Succeeded..."
        sleep 10
    done

echo Associating Log Analytics workspace to Cloud NGFW in $region1 
    az palo-alto cloudngfw firewall save-log-profile --log-option SAME_DESTINATION --log-type TRAFFIC --resource-group $rg --common-destination "{monitor-configurations:{id:/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.OperationalInsights/workspaces/cngfw-law,workspace:$workspace,primary-key:$primaryKey,secondary-key:$secondaryKey}}" --firewall-name $hub1name

prState=''

echo Checking Cloud NGFW in $region2 provisioning status...
    while [[ $prState != 'Succeeded' ]];
    do
        prState=$(az palo-alto cloudngfw firewall show --firewall-name $hub2name -g $rg --query 'provisioningState' -o tsv)
        echo "Cloud NGFW provisioningState="$prState
        echo "Waiting for Succeeded..."
        sleep 10
    done

echo Associating Log Analytics workspace to Cloud NGFW in $region2 
    az palo-alto cloudngfw firewall save-log-profile --log-option SAME_DESTINATION --log-type TRAFFIC --resource-group $rg --common-destination "{monitor-configurations:{id:/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.OperationalInsights/workspaces/cngfw-law,workspace:$workspace,primary-key:$primaryKey,secondary-key:$secondaryKey}}" --firewall-name $hub2name


echo Create a Routing Intent and Policy in both hubs...
    az network vhub routing-intent create -n $hub1name-ri -g $rg --vhub $hub1name --routing-policies "[{name:InternetTraffic,destinations:[Internet],next-hop:/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/networkVirtualAppliances/$hub1name-cngfw-nva},{name:PrivateTrafficPolicy,destinations:[PrivateTraffic],next-hop:/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/networkVirtualAppliances/$hub1name-cngfw-nva}]"
    az network vhub routing-intent create -n $hub2name-ri -g $rg --vhub $hub2name --routing-policies "[{name:InternetTraffic,destinations:[Internet],next-hop:/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/networkVirtualAppliances/$hub2name-cngfw-nva},{name:PrivateTrafficPolicy,destinations:[PrivateTraffic],next-hop:/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/networkVirtualAppliances/$hub2name-cngfw-nva}]"

echo Deployment has finished
# Add script ending time but hours, minutes and seconds
end=`date +%s`
runtime=$((end-start))
echo "Script finished at $(date)"
echo "Total script execution time: $(($runtime / 3600)) hours $((($runtime / 60) % 60)) minutes and $(($runtime % 60)) seconds."
