#!/bin/bash

set -ex

source stackrc

# If your machines don't conform to this structure, try calling the script like this:
#  COMPUTE_PATTERN=mycompute ./iha-uninstall.sh upgrade
: ${COMPUTE_PATTERN=novacompute}
: ${CONTROLLER_PATTERN=controller}

COMPUTES=$(nova list | grep ${COMPUTE_PATTERN} | awk -F\| '{ print $3}' | tr '\n' ' ')
CONTROLLERS=$(nova list | grep ${CONTROLLER_PATTERN} | awk -F\| '{ print $3}'  | tr '\n' ' ')

FIRST_COMPUTE=$(echo $COMPUTES | awk '{print $1}')
FIRST_CONTROLLER=$(echo $CONTROLLERS | awk '{print $1}')

ssh ${FIRST_CONTROLLER} -- sudo pcs property set stonith-enabled=false

if [ $1 = "upgrade" ]; then

    SERVICES="nova-evacuate neutron-openvswitch-agent-compute libvirtd-compute-clone ceilometer-compute-clone nova-compute-checkevacuate-clone nova-compute-clone"

    helper=iha-helper-remove.sh
    cat <<EOF > $helper
set -ex
pcs property set maintenance-mode=true

for resource in $COMPUTES $SERVICES $FUDGE; do
    pcs resource cleanup \${resource}
    pcs --force resource delete \${resource} 
done

for node in $COMPUTES; do
    cibadmin --delete --xml-text "<node id='\${node}'/>"
    cibadmin --delete --xml-text "<node_state id='\${node}'/>"
done

pcs property set maintenance-mode=false --wait

EOF

    scp $helper heat-admin@${FIRST_CONTROLLER}:
    ssh heat-admin@${FIRST_CONTROLLER} -- sudo bash $helper
fi

helper=iha-helper-reenable.sh
cat <<EOF > $helper
set -ex
for service in neutron-openvswitch-agent openstack-ceilometer-compute openstack-nova-compute libvirtd; do
   systemctl enable \${service}
done
EOF

for node in $COMPUTES; do scp $helper heat-admin@${node}: ; ssh heat-admin@${node} -- sudo bash $helper ; done

