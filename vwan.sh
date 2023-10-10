#!/bin/bash

# hacked from ...
# https://github.com/dmauser/azure-virtualwan/tree/main/svh-ri-inter-region
# cngfw only supported in certain regions
# https://docs.paloaltonetworks.com/cloud-ngfw/azure/cloud-ngfw-for-azure/getting-started-with-cngfw-for-azure/supported-regions-and-zones

if [ $# -eq 0 ]
  then
    echo "No Resource Group name was provided. Example: ./deploy.sh Resource Group"
    exit 1
fi
az login
# Parameters (make changes based on your requirements)
prefix=$1
region1=eastus 	#set region1
region2=westeurope #set region2
rg=${prefix}-lab #set resource group
vwanname=${prefix}-panw-lab #set vWAN name
hub1name=${prefix}-sechub1 #set Hub1 name
hub2name=${prefix}-sechub2 #set Hub2 name
username=azureuser #set username
echo "The password length must be between 12 and 72. Password must have the 3 of the following: 1 lower case character, 1 upper case character, 1 number and 1 special character."
read -s -p "Password: " PASSWORD
password=$PASSWORD
vmsize=Standard_DS1_v2 #set VM Size
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
az network vhub create -g $rg --name $hub1name --address-prefix 10.251.0.0/16 --vwan $vwanname --location $region1 --sku Standard --no-wait
az network vhub create -g $rg --name $hub2name --address-prefix 10.252.0.0/16 --vwan $vwanname --location $region2 --sku Standard --no-wait

echo Creating branches VNETs...
# create location1 branch virtual network
az network vnet create --address-prefixes 192.168.0.0/22 -n branch1 -g $rg -l $region1 --subnet-name subnet1 --subnet-prefixes 192.168.0.0/24 --output none

# create location2 branch virtual network
az network vnet create --address-prefixes 192.168.128.0/22 -n branch2 -g $rg -l $region2 --subnet-name subnet2 --subnet-prefixes 192.168.128.0/24 --output none

echo Creating spoke VNETs...
# create spokes virtual network
# Region1
az network vnet create --address-prefixes 172.16.1.0/24 -n spoke1 -g $rg -l $region1 --subnet-name subnet1 --subnet-prefixes 172.16.1.0/27 --output none
# Region2
az network vnet create --address-prefixes 172.16.2.0/24 -n spoke2 -g $rg -l $region2 --subnet-name subnet2 --subnet-prefixes 172.16.2.0/27 --output none

echo Creating VMs in both branches...
# create a VM in each branch spoke
az vm create -n branch1VM  -g $rg --image ubuntults --public-ip-sku Standard --size $vmsize -l $region1 --subnet subnet1 --vnet-name branch1 --admin-username $username --admin-password $password --nsg "" --no-wait --only-show-errors
az vm create -n branch2VM  -g $rg --image ubuntults --public-ip-sku Standard --size $vmsize -l $region2 --subnet subnet2 --vnet-name branch2 --admin-username $username --admin-password $password --nsg "" --no-wait --only-show-errors

echo Creating NSGs in both branches...
#Update NSGs:
az network nsg create --resource-group $rg --name default-nsg-$hub1name-$region1 --location $region1 -o none
az network nsg create --resource-group $rg --name default-nsg-$hub2name-$region2 --location $region2 -o none
# Add my home public IP to NSG for SSH acess
az network nsg rule create -g $rg --nsg-name default-nsg-$hub1name-$region1 -n 'default-allow-ssh' --direction Inbound --priority 100 --source-address-prefixes $mypip --source-port-ranges '*' --destination-address-prefixes '*' --destination-port-ranges 22 --access Allow --protocol Tcp --description "Allow inbound SSH" --output none
az network nsg rule create -g $rg --nsg-name default-nsg-$hub2name-$region2 -n 'default-allow-ssh' --direction Inbound --priority 100 --source-address-prefixes $mypip --source-port-ranges '*' --destination-address-prefixes '*' --destination-port-ranges 22 --access Allow --protocol Tcp --description "Allow inbound SSH" --output none

# Associated NSG to the VNET subnets (Spokes and Branches)
az network vnet subnet update --id $(az network vnet list -g $rg --query '[?location==`'$region1'`].{id:subnets[0].id}' -o tsv) --network-security-group default-nsg-$hub1name-$region1 -o none
az network vnet subnet update --id $(az network vnet list -g $rg --query '[?location==`'$region2'`].{id:subnets[0].id}' -o tsv) --network-security-group default-nsg-$hub2name-$region2 -o none

echo Creating VPN Gateways in both branches...
# create pips for VPN GW's in each branch
az network public-ip create -n branch1-vpngw-pip -g $rg --location $region1 --sku Basic --output none
az network public-ip create -n branch2-vpngw-pip -g $rg --location $region2 --sku Basic --output none

# create VPN gateways
az network vnet subnet create -g $rg --vnet-name branch1 -n GatewaySubnet --address-prefixes 192.168.1.0/24 --output none
az network vnet-gateway create -n branch1-vpngw --public-ip-addresses branch1-vpngw-pip -g $rg --vnet branch1 --asn 65010 --gateway-type Vpn -l $region1 --sku VpnGw1 --vpn-gateway-generation Generation1 --no-wait 
az network vnet subnet create -g $rg --vnet-name branch2 -n GatewaySubnet --address-prefixes 192.168.129.0/24 --output none
az network vnet-gateway create -n branch2-vpngw --public-ip-addresses branch2-vpngw-pip -g $rg --vnet branch2 --asn 65009 --gateway-type Vpn -l $region2 --sku VpnGw1 --vpn-gateway-generation Generation1 --no-wait

echo Creating Spoke VMs...
# create a VM in each connected spoke
az vm create -n spoke1VM  -g $rg --image ubuntults --public-ip-sku Standard --size $vmsize -l $region1 --subnet subnet1 --vnet-name spoke1 --admin-username $username --admin-password $password --nsg "" --no-wait --only-show-errors
az vm create -n spoke2VM  -g $rg --image ubuntults --public-ip-sku Standard --size $vmsize -l $region2 --subnet subnet2 --vnet-name spoke2 --admin-username $username --admin-password $password --nsg "" --no-wait --only-show-errors
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

echo Creating Cloud NGFW Public IPs
    az network public-ip create -n $hub1name-cngfw-pip -g $rg --location $region1 --sku Standard --output none --zone 1 2 3 
    az network public-ip create -n $hub2name-cngfw-pip -g $rg --location $region2 --sku Standard --output none --zone 1 2 3
hub1_cngfw_pip=$(az network public-ip show -n $hub1name-cngfw-pip -g $rg --query ipAddress | tr -d '"')
hub2_cngfw_pip=$(az network public-ip show -n $hub2name-cngfw-pip -g $rg --query ipAddress | tr -d '"')

echo Creating Local Rulestacks...

    az palo-alto cloudngfw local-rulestack create -g $rg -n $hub1name-rulestack --identity "{type:None}" --location $region1 --default-mode IPS --description "Hub 1 Local Rulestack" --min-app-id-version "8595-7473" --scope "LOCAL" --security-services "{vulnerability-profile:BestPractice,anti-spyware-profile:BestPractice,anti-virus-profile:BestPractice,url-filtering-profile:BestPractice,file-blocking-profile:BestPractice,dns-subscription:BestPractice}"

    az palo-alto cloudngfw local-rulestack create -g $rg -n $hub2name-rulestack --identity "{type:None}" --location $region2 --default-mode IPS --description "Hub 2 Local Rulestack" --min-app-id-version "8595-7473" --scope "LOCAL" --security-services "{vulnerability-profile:BestPractice,anti-spyware-profile:BestPractice,anti-virus-profile:BestPractice,url-filtering-profile:BestPractice,file-blocking-profile:BestPractice,dns-subscription:BestPractice}"

echo Creating Cloud NGFW in Hub1...
    az network virtual-appliance create --name $hub1name-cngfw-nva --resource-group $rg --location $region1 --vhub /subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/$hub1name --delegation "{service-name:PaloAltoNetworks.Cloudngfw/firewalls}"
    az palo-alto cloudngfw firewall create --name $hub1name --resource-group $rg --location $region1 --dns-settings "{enable-dns-proxy:DISABLED,enabled-dns-type:CUSTOM}" --marketplace-details "{marketplace-subscription-status:Subscribed,offer-id:pan_swfw_cloud_ngfw,publisher-id:paloaltonetworks}" --plan-data "{billing-cycle:MONTHLY,plan-id:panw-cloud-ngfw-payg,usage-type:PAYG}" --is-panorama-managed FALSE --associated-rulestack "{location:$region1,resource-id:/subscriptions/$subscription_id/resourceGroups/$rg/providers/PaloAltoNetworks.Cloudngfw/localRulestacks/$hub1name-rulestack}" --network-profile "{network-type:VWAN,public-ips:[{address:$hub1_cngfw_pip,resource-id:/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/publicIPAddresses/$hub1name-cngfw-pip}],vwan-configuration:{v-hub:{resource-id:/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/$hub1name},network-virtual-appliance-id:/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/networkVirtualAppliances/$hub1name-cngfw-nva},enable-egress-nat:DISABLED}" --no-wait

echo Creating Hub1 vNET connections
# create spoke to Vwan connections to hub1
az network vhub connection create -n spoke1conn --remote-vnet spoke1 -g $rg --vhub-name $hub1name --no-wait

prState=''
while [[ $prState != 'Succeeded' ]];
do
    prState=$(az network vhub connection show -n spoke1conn --vhub-name $hub1name -g $rg  --query 'provisioningState' -o tsv)
    echo "vnet connection spoke1conn provisioningState="$prState
    sleep 5
done

echo Creating Hub1 VPN Gateway...
# Creating VPN gateways in each Hub1
az network vpn-gateway create -n $hub1name-vpngw -g $rg --location $region1 --vhub $hub1name --no-wait 

echo Checking Hub2 provisioning status...
# Checking Hub2 provisioning and routing state 
prState=''
rtState=''
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

echo Creating Cloud NGFW in Hub2...
    az network virtual-appliance create --name $hub2name-cngfw-nva --resource-group $rg --location $region2 --vhub /subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/$hub2name --delegation "{service-name:PaloAltoNetworks.Cloudngfw/firewalls}"
    az palo-alto cloudngfw firewall create --name $hub2name --resource-group $rg --location $region2 --dns-settings "{enable-dns-proxy:DISABLED,enabled-dns-type:CUSTOM}" --marketplace-details "{marketplace-subscription-status:Subscribed,offer-id:pan_swfw_cloud_ngfw,publisher-id:paloaltonetworks}" --plan-data "{billing-cycle:MONTHLY,plan-id:panw-cloud-ngfw-payg,usage-type:PAYG}" --is-panorama-managed FALSE --associated-rulestack "{location:$region2,resource-id:/subscriptions/$subscription_id/resourceGroups/$rg/providers/PaloAltoNetworks.Cloudngfw/localRulestacks/$hub2name-rulestack}" --network-profile "{network-type:VWAN,public-ips:[{address:$hub2_cngfw_pip,resource-id:/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/publicIPAddresses/$hub2name-cngfw-pip}],vwan-configuration:{v-hub:{resource-id:/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/$hub2name},network-virtual-appliance-id:/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/networkVirtualAppliances/$hub2name-cngfw-nva},enable-egress-nat:DISABLED}" --no-wait

# create spoke to Vwan connections to hub2
az network vhub connection create -n spoke2conn --remote-vnet spoke2 -g $rg --vhub-name $hub2name --no-wait

prState=''
while [[ $prState != 'Succeeded' ]];
do
    prState=$(az network vhub connection show -n spoke2conn --vhub-name $hub2name -g $rg  --query 'provisioningState' -o tsv)
    echo "vnet connection spoke4conn provisioningState="$prState
    sleep 5
done

echo Creating Log Analytics Workspace...


echo Creating Hub2 VPN Gateway...
#Creating VPN gateways in each Hub2
    az network vpn-gateway create -n $hub2name-vpngw -g $rg --location $region2 --vhub $hub2name --no-wait

echo Validating Branches VPN Gateways provisioning...
#Branches VPN Gateways provisioning status
prState=$(az network vnet-gateway show -g $rg -n branch1-vpngw --query provisioningState -o tsv)
if [[ $prState == 'Failed' ]];
then
    echo VPN Gateway is in fail state. Deleting and rebuilding.
    az network vnet-gateway delete -n branch1-vpngw -g $rg
    az network vnet-gateway create -n branch1-vpngw --public-ip-addresses branch1-vpngw-pip -g $rg --vnet branch1 --asn 65010 --gateway-type Vpn -l $region1 --sku VpnGw1 --vpn-gateway-generation Generation1 --no-wait 
    sleep 5
else
    prState=''
    while [[ $prState != 'Succeeded' ]];
    do
        prState=$(az network vnet-gateway show -g $rg -n branch1-vpngw --query provisioningState -o tsv)
        echo "branch1-vpngw provisioningState="$prState
        sleep 5
    done
fi

prState=$(az network vnet-gateway show -g $rg -n branch2-vpngw --query provisioningState -o tsv)
if [[ $prState == 'Failed' ]];
then
    echo VPN Gateway is in fail state. Deleting and rebuilding.
    az network vnet-gateway delete -n branch2-vpngw -g $rg
    az network vnet-gateway create -n branch2-vpngw --public-ip-addresses branch2-vpngw-pip -g $rg --vnet branch2 --asn 65009 --gateway-type Vpn -l $region2 --sku VpnGw1 --vpn-gateway-generation Generation1 --no-wait 
    sleep 5
else
    prState=''
    while [[ $prState != 'Succeeded' ]];
    do
        prState=$(az network vnet-gateway show -g $rg -n branch2-vpngw --query provisioningState -o tsv)
        echo "branch2-vpngw provisioningState="$prState
        sleep 5
    done
fi

echo Validating vHubs VPN Gateways provisioning...
#vWAN Hubs VPN Gateway Status
prState=$(az network vpn-gateway show -g $rg -n $hub1name-vpngw --query provisioningState -o tsv)
if [[ $prState == 'Failed' ]];
then
    echo VPN Gateway is in fail state. Deleting and rebuilding.
    az network vpn-gateway delete -n $hub1name-vpngw -g $rg
    az network vpn-gateway create -n $hub1name-vpngw -g $rg --location $region1 --vhub $hub1name --no-wait
    sleep 5
else
    prState=''
    while [[ $prState != 'Succeeded' ]];
    do
        prState=$(az network vpn-gateway show -g $rg -n $hub1name-vpngw --query provisioningState -o tsv)
        echo $hub1name-vpngw "provisioningState="$prState
        sleep 5
    done
fi

prState=$(az network vpn-gateway show -g $rg -n $hub2name-vpngw --query provisioningState -o tsv)
if [[ $prState == 'Failed' ]];
then
    echo VPN Gateway is in fail state. Deleting and rebuilding.
    az network vpn-gateway delete -n $hub2name-vpngw -g $rg
    az network vpn-gateway create -n $hub2name-vpngw -g $rg --location $region2 --vhub $hub2name --no-wait
    sleep 5
else
    prState=''
    while [[ $prState != 'Succeeded' ]];
    do
        prState=$(az network vpn-gateway show -g $rg -n $hub2name-vpngw --query provisioningState -o tsv)
        echo $hub2name-vpngw "provisioningState="$prState
        sleep 5
    done
fi

echo Building VPN connections from VPN Gateways to the respective Branches...
# get bgp peering and public ip addresses of VPN GW and VWAN to set up connection
# Branch 1 and Hub1 VPN Gateway variables
bgp1=$(az network vnet-gateway show -n branch1-vpngw -g $rg --query 'bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]' -o tsv)
pip1=$(az network vnet-gateway show -n branch1-vpngw -g $rg --query 'bgpSettings.bgpPeeringAddresses[0].tunnelIpAddresses[0]' -o tsv)
vwanh1gwbgp1=$(az network vpn-gateway show -n $hub1name-vpngw -g $rg --query 'bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]' -o tsv)
vwanh1gwpip1=$(az network vpn-gateway show -n $hub1name-vpngw -g $rg --query 'bgpSettings.bgpPeeringAddresses[0].tunnelIpAddresses[0]' -o tsv)
vwanh1gwbgp2=$(az network vpn-gateway show -n $hub1name-vpngw -g $rg --query 'bgpSettings.bgpPeeringAddresses[1].defaultBgpIpAddresses[0]' -o tsv)
vwanh1gwpip2=$(az network vpn-gateway show -n $hub1name-vpngw -g $rg --query 'bgpSettings.bgpPeeringAddresses[1].tunnelIpAddresses[0]' -o tsv)

# Branch 2 and Hub2 VPN Gateway variables
bgp2=$(az network vnet-gateway show -n branch2-vpngw -g $rg --query 'bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]' -o tsv)
pip2=$(az network vnet-gateway show -n branch2-vpngw -g $rg --query 'bgpSettings.bgpPeeringAddresses[0].tunnelIpAddresses[0]' -o tsv)
vwanh2gwbgp1=$(az network vpn-gateway show -n $hub2name-vpngw -g $rg --query 'bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]' -o tsv)
vwanh2gwpip1=$(az network vpn-gateway show -n $hub2name-vpngw  -g $rg --query 'bgpSettings.bgpPeeringAddresses[0].tunnelIpAddresses[0]' -o tsv)
vwanh2gwbgp2=$(az network vpn-gateway show -n $hub2name-vpngw -g $rg --query 'bgpSettings.bgpPeeringAddresses[1].defaultBgpIpAddresses[0]' -o tsv)
vwanh2gwpip2=$(az network vpn-gateway show -n $hub2name-vpngw -g $rg --query 'bgpSettings.bgpPeeringAddresses[1].tunnelIpAddresses[0]' -o tsv)

# create virtual wan vpn site
az network vpn-site create --ip-address $pip1 -n site-branch1 -g $rg --asn 65010 --bgp-peering-address $bgp1 -l $region1 --virtual-wan $vwanname --device-model 'Azure' --device-vendor 'Microsoft' --link-speed '50' --with-link true --output none
az network vpn-site create --ip-address $pip2 -n site-branch2 -g $rg --asn 65009 --bgp-peering-address $bgp2 -l $region2 --virtual-wan $vwanname --device-model 'Azure' --device-vendor 'Microsoft' --link-speed '50' --with-link true --output none

# create virtual wan vpn connection
az network vpn-gateway connection create --gateway-name $hub1name-vpngw -n site-branch1-conn -g $rg --enable-bgp true --remote-vpn-site site-branch1 --internet-security --shared-key 'abc123' --output none
az network vpn-gateway connection create --gateway-name $hub2name-vpngw -n site-branch2-conn -g $rg --enable-bgp true --remote-vpn-site site-branch2 --internet-security --shared-key 'abc123' --output none

# create connection from vpn gw to local gateway and watch for connection succeeded
az network local-gateway create -g $rg -n lng-$hub1name-gw1 --gateway-ip-address $vwanh1gwpip1 --asn 65515 --bgp-peering-address $vwanh1gwbgp1 -l $region1 --output none
az network vpn-connection create -n branch1-to-$hub1name-gw1 -g $rg -l $region1 --vnet-gateway1 branch1-vpngw --local-gateway2 lng-$hub1name-gw1 --enable-bgp --shared-key 'abc123' --output none

az network local-gateway create -g $rg -n lng-$hub1name-gw2 --gateway-ip-address $vwanh1gwpip2 --asn 65515 --bgp-peering-address $vwanh1gwbgp2 -l $region1 --output none
az network vpn-connection create -n branch1-to-$hub1name-gw2 -g $rg -l $region1 --vnet-gateway1 branch1-vpngw --local-gateway2 lng-$hub1name-gw2 --enable-bgp --shared-key 'abc123' --output none

az network local-gateway create -g $rg -n lng-$hub2name-gw1 --gateway-ip-address $vwanh2gwpip1 --asn 65515 --bgp-peering-address $vwanh2gwbgp1 -l $region2 --output none
az network vpn-connection create -n branch2-to-$hub2name-gw1 -g $rg -l $region2 --vnet-gateway1 branch2-vpngw --local-gateway2 lng-$hub2name-gw1 --enable-bgp --shared-key 'abc123' --output none

az network local-gateway create -g $rg -n lng-$hub2name-gw2 --gateway-ip-address $vwanh2gwpip2 --asn 65515 --bgp-peering-address $vwanh2gwbgp2 -l $region2 --output none
az network vpn-connection create -n branch2-to-$hub2name-gw2 -g $rg -l $region2 --vnet-gateway1 branch2-vpngw --local-gateway2 lng-$hub2name-gw2 --enable-bgp --shared-key 'abc123' --output none

echo Deployment has finished
# Add script ending time but hours, minutes and seconds
end=`date +%s`
runtime=$((end-start))
echo "Script finished at $(date)"
echo "Total script execution time: $(($runtime / 3600)) hours $((($runtime / 60) % 60)) minutes and $(($runtime % 60)) seconds."
