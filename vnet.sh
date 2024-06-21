#!/bin/bash

# hacked from ...
# https://github.com/dmauser/azure-virtualwan/tree/main/svh-ri-inter-region
# cngfw only supported in certain regions
# https://docs.paloaltonetworks.com/cloud-ngfw/azure/cloud-ngfw-for-azure/getting-started-with-cngfw-for-azure/supported-regions-and-zones

if [ $# -ne 2 ]
  then
    echo "No enough arguments name was provided. Example: ./vnet.sh <Resource Group> <Region>"
    exit 1
fi
az login
# Parameters (make changes based on your requirements)
rg=$1 #set resource group
region=$2 	#set region1
 

username=azureuser #set username
echo "The password length must be between 12 and 72. Password must have the 3 of the following: 1 lower case character, 1 upper case character, 1 number and 1 special character."
read -s -p "Password: " PASSWORD
password=$PASSWORD
vmsize=Standard_B1s #set VM Size
subscription_id=$(az account show --query id | tr -d '"')

# Pre-Requisites

if ! az extension list | grep -q palo-alto-networks; then
    echo "palo-alto-networks extension is not installed, installing it now..."
    az extension add --name palo-alto-networks --only-show-errors
fi

start=`date +%s`
echo "Script started at $(date)"

#Variables
mypip=$(curl -4 ifconfig.io -s)

# create rg
az group create -n $rg -l $region --output none

# create hub NSG
az network nsg create --resource-group $rg --name hub-vnet-nsg --location $region -o none
az network nsg rule create -g $rg --nsg-name hub-vnet-nsg -n 'allow-outbound' --direction Inbound --priority 100 --source-address-prefixes VirtualNetwork --destination-address-prefixes Internet --source-port-ranges '*' --destination-port-ranges '*' --access Allow --protocol '*' --description "Allow outbound connections" --output none

echo Creating hub vNet...
az network vnet create --name hub-vnet --resource-group $rg --address-prefix 10.0.0.0/25
az network vnet subnet create -g $rg --vnet-name hub-vnet -n public-subnet --address-prefixes 10.0.0.0/26 --network-security-group hub-vnet-nsg --delegations "PaloAltoNetworks.Cloudngfw/firewalls"
az network vnet subnet create -g $rg --vnet-name hub-vnet -n private-subnet --address-prefixes 10.0.0.64/26 --network-security-group hub-vnet-nsg --delegations "PaloAltoNetworks.Cloudngfw/firewalls"

echo Creating Cloud NGFW Public IPs
    az network public-ip create -n cngfw-pip -g $rg --location $region --sku Standard --output none --zone 1 2 3 
cngfw_pip=$(az network public-ip show -n cngfw-pip -g $rg --query ipAddress | tr -d '"')

echo Creating Local Rulestack...
    az palo-alto cloudngfw local-rulestack create -g $rg -n local-rulestack --identity "{type:None}" --location $region --default-mode IPS --description "Local Rulestack" --min-app-id-version "8595-7473" --scope "LOCAL" --security-services "{vulnerability-profile:BestPractice,anti-spyware-profile:BestPractice,anti-virus-profile:BestPractice,url-filtering-profile:BestPractice,file-blocking-profile:BestPractice,dns-subscription:BestPractice}"

echo Create Cloud NGFW...
az palo-alto cloudngfw firewall create --name cngfw-$region --resource-group $rg --location $region --dns-settings "{enable-dns-proxy:DISABLED,enabled-dns-type:CUSTOM}" --marketplace-details "{marketplace-subscription-status:Subscribed,offer-id:pan_swfw_cloud_ngfw,publisher-id:paloaltonetworks}" --plan-data "{billing-cycle:MONTHLY,plan-id:panw-cloud-ngfw-payg,usage-type:PAYG}" --is-panorama-managed FALSE --associated-rulestack "{location:$region,resource-id:/subscriptions/$subscription_id/resourceGroups/$rg/providers/PaloAltoNetworks.Cloudngfw/localRulestacks/local-rulestack}" --network-profile "{network-type:VNET,public-ips:[{address:$cngfw_pip,resource-id:/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/publicIPAddresses/cngfw-pip}],enable-egress-nat:DISABLED,vnet-configuration:{ip-of-trust-subnet-for-udr:{address:10.0.0.64/26},trust-subnet:{resource-id:/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualNetworks/hub-vnet/subnets/private-subnet},un-trust-subnet:{resource-id:/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualNetworks/hub-vnet/subnets/public-subnet},vnet:{resource-id:/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualNetworks/hub-vnet}}}" --no-wait

echo Creating spoke vNets...
# create spokes virtual network
az network vnet create --address-prefixes 172.16.1.0/24 -n spoke1 -g $rg -l $region --subnet-name subnet1 --subnet-prefixes 172.16.1.0/27 --output none
az network vnet create --address-prefixes 172.16.2.0/24 -n spoke2 -g $rg -l $region --subnet-name subnet2 --subnet-prefixes 172.16.2.0/27 --output none

echo Creating Spoke VMs...
# create a VM in each connected spoke
az vm create -n spoke1VM  -g $rg --image ubuntults --size $vmsize -l $region --subnet subnet1 --vnet-name spoke1 --admin-username $username --admin-password $password --nsg "" --no-wait --only-show-errors
az vm create -n spoke2VM  -g $rg --image ubuntults --size $vmsize -l $region --subnet subnet2 --vnet-name spoke2 --admin-username $username --admin-password $password --nsg "" --no-wait --only-show-errors

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
    
echo Creating Hub vNET peering...
    az network vnet peering create -g $rg -n hub-to-spoke1 --vnet-name hub-vnet --remote-vnet spoke1 --allow-vnet-access --allow-forwarded-traffic --no-wait
    az network vnet peering create -g $rg -n spoke1-to-hub --vnet-name spoke1 --remote-vnet hub-vnet --allow-vnet-access --allow-forwarded-traffic --no-wait
    az network vnet peering create -g $rg -n hub-to-spoke2 --vnet-name hub-vnet --remote-vnet spoke2 --allow-vnet-access --allow-forwarded-traffic --no-wait
    az network vnet peering create -g $rg -n spoke2-to-hub --vnet-name spoke2 --remote-vnet hub-vnet --allow-vnet-access --allow-forwarded-traffic --no-wait

echo Create Route Table...
    az network route-table create -g $rg -n default-route-table
    az network route-table route create -g $rg --route-table-name default-route-table -n default-route --next-hop-type VirtualAppliance --address-prefix 0.0.0.0/0 --next-hop-ip-address 10.0.0.68 --no-wait

echo Associate Route table to spoke subnets...
    az network vnet subnet update --vnet-name spoke1 --name subnet1 --resource-group $rg --route-table default-route-table --no-wait
    az network vnet subnet update --vnet-name spoke2 --name subnet2 --resource-group $rg --route-table default-route-table --no-wait

prState=''

echo Checking Cloud NGFW provisioning status...
    while [[ $prState != 'Succeeded' ]];
    do
        prState=$(az palo-alto cloudngfw firewall show --firewall-name cngfw-$region -g $rg --query 'provisioningState' -o tsv)
        echo "Cloud NGFW provisioningState="$prState
        echo "Waiting for Succeeded..."
        sleep 10
    done

echo Creating and associating Log Analytics Workspace...
    az monitor log-analytics workspace create -g $rg -n cngfw-law --location $region
    workspace=$(az monitor log-analytics workspace show --name cngfw-law --resource-group $rg --query customerId | tr -d '"')
    primaryKey=$(az monitor log-analytics workspace get-shared-keys --resource-group $rg --workspace-name cngfw-law --query "primarySharedKey" | tr -d '"')
    secondaryKey=$(az monitor log-analytics workspace get-shared-keys --resource-group $rg --workspace-name cngfw-law --query "secondarySharedKey" | tr -d '"')
    az palo-alto cloudngfw firewall save-log-profile --log-option SAME_DESTINATION --log-type TRAFFIC --resource-group $rg --common-destination "{monitor-configurations:{id:/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.OperationalInsights/workspaces/cngfw-law,workspace:$workspace,primary-key:$primaryKey,secondary-key:$secondaryKey}}" --firewall-name cngfw-$region

echo Deployment has finished
# Add script ending time but hours, minutes and seconds
end=`date +%s`
runtime=$((end-start))
echo "Script finished at $(date)"
echo "Total script execution time: $(($runtime / 3600)) hours $((($runtime / 60) % 60)) minutes and $(($runtime % 60)) seconds."