# Highly Available Openstack Deployments

## Purpose of this Document

This document aims at defining a high level architecture for a highly
available RHEL OSP setup with the [Pacemaker](http://clusterlabs.org)
cluster manager which provides:

- detection and recovery of machine and application-level failures
- startup/shutdown ordering between applications
- preferences for other applications that must/must-not run on the same machine
- provably correct response to any failure or cluster state

All components are currently modelled as active/active with the exception of:

- openstack-ceilometer-central 
- openstack-heat-engine 
- cinder-volume
- qpid (optional)

Implementation details are contained in scripts linked to from the main document.
Read them carefully before considering to run them in your own environment. 

The current target for this document is RHEL OSP 6, based on the Juno
OpenStack release.

## Disclaimer 

- The referenced scripts contain many comments and warnings - READ THEM CAREFULLY.
- There are probably 2^8 other ways to deploy this same scenario. This is only one of them.
- Due to limited number of available physical LAN connections in the test setup, the instance IP traffic overlaps with the internal/management network.
- Distributed/Shared storage is provided via NFS from the commodity server due to lack of dedicated CEPH servers. Any other kind of storage supported by OpenStack would work just fine.
- Bare metal could be used in place of any or all guests.
- Most of the scripts contain shell expansion to automatically fill in some values.  Use your common sense when parsing data. Example:

  `openstack-config --set /etc/nova/nova.conf DEFAULT vncserver_proxyclient_address $(ip addr show dev vmnet0 scope global | grep inet | sed -e 's#.*inet ##g' -e    's#/.*##g')`

  means that we want the IP address from vmnet0 as vncserver_proxyclient_address.

## Bugs

- N/A

### TODO

- Missing how-to add / remove a node
- Missing how-to move a service from cluster X to cluster Y
- nova network HA
- Compute nodes managed by pacemaker_remoted
- Remove all artificial sleep and use pcs --wait once 7.1 is out of the door
- Copy in the test information from Fabio's document
- Improve nova-compute test section with CLI commands
- re-check keystone -> other services start order require-all=false option

# Hardware / VM deployment

## Assumptions

- To provide additional isolation, every component runs in its own virtual machine
- All APIs are exposed only in the internal LAN
- neutron-agents are directly connected to the external LAN
- nova and horizon are exposed to the external LAN via an extra haproxy instance
- Compute nodes have a management connection to the external LAN but it is not used by OpenStack and hence not reproduced in the diagram. This will be used when adding nova network setup.
- Here is a [list of variables](ha.variables) used when executing the referenced scripts.  Modify them to your needs.

Each box below represents a cluster of three or more guests.

![Deployment architecture](Cluster-of-clusters.png)


## Implementation

Start by creating a minimal CentOS installation on at least three nodes.
No OpenStack services or HA will be running here.

For each service we create a virtual cluster, with one member running
on each of the physical hosts.  Each virtual cluster must contain at
least three members because quorum is not useful with fewer hosts.

Quorum becomes important when a failure causes the cluster to split in
two or more paritions.  In this situation, you want the majority to
ensure the minority are truely dead (through fencing) and continue to
host resources.  For a two-node cluster, no side has the majority and
you can end up in a situations where both sides fence each other, or
both sides are running the same services - leading to data corruption.

Clusters with an even number of hosts suffer from similar issues - a
single network failure could easily cause a N:N split where neither
side retains a majority.  For this reason, we recommend an odd number
of cluster members.

You can have up to 16 cluster members (this is currently limited by
corosync's ability to scale higher).  In extreme cases, 32 and even up
to 64 nodes could be possible however this is not well tested.

In some environments, the available IP address range of the public LAN
is limited. If this applies to you, you will need one additional node
to set up as a [gateway](gateway.scenario) that will provide DNS
and DHCP for the guests containing the OpenStack services and expose
the required nova and horizon APIs to the external network.

Once the machines have been installed, [prepare them](baremetal.scenario) 
for hosting OpenStack.

Next we must [create the image](virt-hosts.scenario) for the
guests that will host the OpenStack services and clone it.  Once the
image has been created, we can prepare the hosting nodes and
[clone](virt-hosts.scenario) it.

# Deploy OpenStack HA controllers

This how-to is divided in 2 sections. The first section is used to
deploy all core non-OpenStack services, the second section all
OpenStack services.

Pacemaker is used to drive all services.

## Installing core non-Openstack services

### Cluster Manager

At its core, a cluster is a distributed finite state machine capable
of co-ordinating the startup and recovery of inter-related services
across a set of machines.

Even a distributed and/or replicated application that is able to
survive failures on one or more machines can benefit from a
cluster manager:

1.  Awareness of other applications in the stack
    
    While SYS-V init replacements like systemd can provide
    deterministic recovery of a complex stack of services, the
    recovery is limited to one machine and lacks the context of what
    is happening on other machines - context that is crucial to
    determine the difference between a local failure, clean startup
    and recovery after a total site failure.

1.  Awareness of instances on other machines

    Services like RabbitMQ and Galera have complicated boot-up
    sequences that require co-ordination, and often serialization, of
    startup operations across all machines in the cluster. This is
    especially true after site-wide failure or shutdown where we must
    first determine the last machine to be active.
    
1.  A shared implementation and calculation of [quorum](http://en.wikipedia.org/wiki/Quorum_%28Distributed_Systems%29)

    It is very important that all members of the system share the same
    view of who their peers are and whether or not they are in the
    majority.  Failure to do this leads very quickly to an internal
    [split-brain](https://en.wikipedia.org/wiki/Split-brain_(computing))
    state - where different parts of the system are pulling in
    different and incompatioble directions.

1.  Data integrity through fencing (a non-responsive process does not imply it is not doing anything)

    A single application does not have sufficient context to know the
    difference between failure of a machine and failure of the
    applcation on a machine.  The usual practice is to assume the
    machine is dead and carry on, however this is highly risky - a
    rogue process or machine could still be responding to requests and
    generally causing havoc.  The safer approach is to make use of
    remotely accessible power switches and/or network switches and SAN
    controllers to fence (isolate) the machine before continuing.

1.  Automated recovery of failed instances
    
    While the application can still run after the failure of several
    instances, it may not have sufficient capacity to serve the
    required volume of requests.  A cluster can automatically recover
    failed instances to prevent additional load induced failures.


For this reason, the use of a cluster manager like
[Pacemaker](http://clusterlabs.org) is highly recommended.  The [basic
cluster setup](basic-cluster.scenario) instructions are required for
every cluster.

When performing an All-in-One deployment, there is only one cluster and now is the time to perform it.
When performing an One-Cluster-per-Service deployment, this should be performed before configuring each component.

### Proxy server

Using a proxy allows:

- simplified process for adding/removing of nodes
- enhanced failure detection
- API isolation
- load distribution

If you are performing a One-Cluster-per-Service deployment, follow the [basic cluster setup](basic-cluster.scenario) instructions.

Once you have a functional cluster, you can then deploy the [load balancer](lb.scenario) to the previously created guests.

The check interval is 1 second however the timeouts vary by service.

Generally we use round-robin to distriute load, however Galera and
Qpid use the `stick-table` options to ensure that incoming connections
to the VIP should be directed to only one of the available backends.

In Galera's case, although it can run active/active, this helps avoid
lock contention and prevent deadlocks.  It is used in combination with
the `httpchk` option that ensures only nodes that are in sync with its
peers are allowed to handle requests.

Qpid however operates in a active/passive configuration, no built-in
clustering, so the `stick-table` option ensures that all requests go
to the active instance.

### Replicated Database

Most OpenStack components require access to a database.

To avoid the database being a single point of failure, we require that
it be replicated and the ability to support multiple masters can help
when trying to scale other components.

One of the most popular database choices is Galera for MySQL, it supports:

- Synchronous replication
- active/active multi-master topology
- Automatic node joining
- True parallel replication, on row level
- Direct client connections, native MySQL look & feel

and claims:

- No slave lag
- No lost transactions
- Both read and write scalability
- Smaller client latencies

Although galera supports active/active configurations, we recommend active/passive (enforced by the load balancer) in order to avoid lock contention.

To configure Galera, first follow the [basic cluster setup](basic-cluster.scenario) instructions to set up a cluster on the guests intended to contain it.
Once you have a functional cluster, you can then [deploy galera](galera.scenario) into it.

To verify the installation was successful, perform the following [test actions](galera-test.sh) from one of the nodes.

### Database Cache

Memcached is a general-purpose distributed memory caching system. It
is used to speed up dynamic database-driven websites by caching data
and objects in RAM to reduce the number of times an external data
source must be read.

First follow the [basic cluster setup](basic-cluster.scenario) instructions to set up a cluster on the guests intended to contain memcached.
Once you have a functional cluster, you can then [deploy memcached](memcached.scenario) into it.

### Message Bus

An AMQP (Advanced Message Queuing Protocol) compliant message bus is required for most OpenStack components in order to co-ordinate the execution of jobs entered into the system.
RabbitMQ and Qpid are common deployment options. Both support:

- reliable message delivery
- flexible routing options
- replicated queues

First follow the [basic cluster setup](basic-cluster.scenario) instructions to set up a cluster on the guests intended to contain RabbitMQ or Qpid.
Once you have a functional cluster, you can then deploy [rabbitmq](rabbitmq.scenario) or [qpid](osp-qpid.scenario)into it.

To verify the installation was successful, perform the following [test actions](rabbitmq-test.sh) from one of the nodes.

### NoSQL Database (optional)

If you plan to install `ceilometer`, you will need a NoSQL database such as mongodb.

MongoDB is a cross-platform document-oriented database that eschews
the traditional table-based relational database structure in favor of
JSON-like documents with dynamic schemas, making the integration of
data in certain types of applications easier and faster.

First follow the [basic cluster setup](basic-cluster.scenario) instructions to set up a cluster on the guests intended to contain mongodb.
Once you have a functional cluster, you can then [deploy mongodb](mongodb.scenario) into it.

## Installing Openstack services
### Keystone

Keystone is an OpenStack project that provides Identity, Token,
Catalog and Policy services for use specifically by projects in the
OpenStack family. It implements OpenStack's Identity API.

First follow the [basic cluster setup](basic-cluster.scenario) instructions to set up a cluster on the guests intended to contain keystone.
Once you have a functional cluster, you can then [deploy keystone](keystone.scenario) into it.

To verify the installation was successful, perform the following [test actions](keystone-test.sh) from one of the nodes.

### Glance

The Glance project provides a service where users can upload and
discover data assets that are meant to be used with other
services. This currently includes images and metadata definitions.

Glance image services include discovering, registering, and retrieving
virtual machine images.

First follow the [basic cluster setup](basic-cluster.scenario) instructions to set up a cluster on the guests intended to contain glance.
Once you have a functional cluster, you can then [deploy glance](glance.scenario) into it.

To verify the installation was successful, perform the following [test actions](glance-test.sh) from one of the nodes.

### Cinder

Cinder provides 'block storage as a service'.

In theory cinder can be run as active/active however there are
currently sufficient concerns that cause us to recommend running the
volume component as active/passive only.

Jon Bernard writes:

> Requests are first seen by Cinder in the API service, and we have a
> fundamental problem there - a standard test-and-set race condition
> exists for many operations where the volume status is first checked
> for an expected status and then (in a different operation) updated to
> a pending status.  The pending status indicates to other incoming
> requests that the volume is undergoing a current operation, however it
> is possible for two simultaneous requests to race here, which
> undefined results.
> 
> Later, the manager/driver will receive the message and carry out the
> operation.  At this stage there is a question of the synchronization
> techniques employed by the drivers and what guarantees they make.
> 
> If cinder-volume processes exist as different process, then the
> 'synchronized' decorator from the lockutils package will not be
> sufficient.  In this case the programmer can pass an argument to
> synchronized() 'external=True'.  If external is enabled, then the
> locking will take place on a file located on the filesystem.  By
> default, this file is placed in Cinder's 'state directory' in
> /var/lib/cinder so won't be visible to cinder-volume instances running
> on different machines.
> 
> However, the location for file locking is configurable.  So an
> operator could configure the state directory to reside on shared
> storage.  If the shared storage in use implements unix file locking
> semantics, then this could provide the requisite synchronization
> needed for an active/active HA configuration.
> 
> The remaining issue is that not all drivers use the synchronization
> methods, and even fewer of those use the external file locks.
> A sub-concern would be whether they use them correctly.

You can read more about these concerns on the [Red Hat
Bugzilla](https://bugzilla.redhat.com/show_bug.cgi?id=1193229) and
there is a [psuedo roadmap](https://etherpad.openstack.org/p/cinder-kilo-stabilisation-work)
for addressing the concerns upstream.

First follow the [basic cluster setup](basic-cluster.scenario) instructions to set up a cluster on the guests intended to contain cinder.
Once you have a functional cluster, you can then [deploy cinder](cinder.scenario) into it.

To verify the installation was successful, perform the following [test actions](cinder-test.sh) from one of the nodes.

### Swift ACO (optional)

Swift is a highly available, distributed, eventually consistent
object/blob store. Organizations can use Swift to store lots of data
efficiently, safely, and cheaply.

As mentioned earlier, limitations in Corosync prevent us from
combining more than 16 machines into a logic unit. In the case of
Swift, although this is fune for the proxy, it is insufficient for the
worker nodes.

There are plans to make use of something called `pacemaker-remote` to
allow the cluster to manage more than 16 worker nodes, but until this
is properly documented, the work-around is to create each Swift worker
as an single node cluster - independant of all the others. This avoids
the 16 node limit while still making sure the individual Swift daemons
are being monitored and recovered as necessary.

First follow the [basic cluster setup](basic-cluster.scenario) instructions to set up a cluster on every guest intended to contain Swift.
Once you have a set of functional single-node clusters, you can then [deploy swift ACOs](swift-aco.scenario) into them.

### Swift Proxy (optional)

The Proxy Server is responsible for tying together the rest of the
Swift architecture. For each request, it will look up the location of
the account, container, or object in the ring (see below) and route
the request accordingly.

First follow the [basic cluster setup](basic-cluster.scenario) instructions to set up a cluster on the guests intended to contain the swift proxy.
Once you have a functional cluster, you can then [deploy swift](swift.scenario) into it.

To verify the installation was successful, perform the following [test actions](swift-test.sh) from one of the nodes.

### Networking

Neutron and Nova are two commonly deployed projects that can provide
'network connectivity as a service' between interface devices (e.g.,
vNICs) managed by other OpenStack services (e.g., nova).

`nova-network` is the legacy networking implementation that was
limited in terms of functionality but has historically been more
reliable but than Neutron.

Neutron has matured to the point that `nova-network` is now rarely
chosen for new deployments.

For completeness, we document the installation of both however Neutron
is the recommended option unless you need `nova-network`'s multi-host
mode which allows every compute node to be used as the gateway to an
external network instead of having to route all traffic from every
compute node through a single network node.

#### Neutron
Server:

Agents:

#### Nova-network (non-compute)

For nova, first follow the [basic cluster setup](basic-cluster.scenario) instructions to set up a cluster on the guests intended to contain nova.
Once you have a functional cluster, you can then [deploy nova](nova.scenario) into it.

To verify the installation was successful, perform the following [test actions](nova-test.sh) from one of the nodes.

### Ceilometer (optional)

The Ceilometer project aims to deliver a unique point of contact for
billing systems to acquire all of the measurements they need to
establish customer billing, across all current OpenStack core
components with work underway to support future OpenStack components.

First follow the [basic cluster setup](basic-cluster.scenario) instructions to set up a cluster on the guests intended to contain ceilometer.
Once you have a functional cluster, you can then [deploy ceilometer](ceilometer.scenario) into it.

To verify the installation was successful, perform the following [test actions](ceilometer-test.sh) from one of the nodes.

### Heat (optional)

Heat is a service to orchestrate multiple composite cloud applications
using the AWS CloudFormation template format, through both an
OpenStack-native ReST API and a CloudFormation-compatible Query API.

First follow the [basic cluster setup](basic-cluster.scenario) instructions to set up a cluster on the guests intended to contain heat.
Once you have a functional cluster, you can then [deploy heat](heat.scenario) into it.

### Horizon

First follow the [basic cluster setup](basic-cluster.scenario) instructions to set up a cluster on the guests intended to contain horizon.
Once you have a functional cluster, you can then [deploy horizon](horizon.scenario) into it.

# Compute nodes (standalone)

Just like Swift, we will usually need more than 16 compute nodes which
is beyond Corosync's ability to manage.  So again we use the
work-around of create each compute node as a single node cluster -
independant of all the others. This avoids the 16 node limit while
still making sure the individual compute daemons are being monitored
and recovered as necessary.

First follow the [basic cluster setup](basic-cluster.scenario) instructions to set up a cluster on every guest intended to contain Swift.
Once you have a set of functional single-node clusters, you can then [deploy compute nodes](compute.scenario) into them.
