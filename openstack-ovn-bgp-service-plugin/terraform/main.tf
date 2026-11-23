terraform {
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 3.0"
    }
  }
}

provider "openstack" {
  cloud = "devstack-admin"
}

provider "openstack" {
  alias = "demo"
  cloud = "devstack"
}

locals {
  guests = {
    controller = { host = "infra-lab-openstack", name = "ovn-bgp-vm", ip = "10.53.0.22" }
    compute    = { host = "infra-lab-openstack-compute", name = "ovn-bgp-compute-vm", ip = "10.53.0.23" }
  }
}

data "openstack_identity_project_v3" "demo" {
  name = "demo"
}

resource "openstack_compute_flavor_v2" "guest" {
  name      = "ovn-bgp-ubuntu"
  ram       = 1024
  vcpus     = 1
  disk      = 10
  is_public = true
}

resource "openstack_compute_aggregate_v2" "placement" {
  for_each = local.guests
  name     = "ovn-bgp-${each.key}"
  zone     = "ovn-bgp-${each.key}"
  hosts    = [each.value.host]
}

resource "openstack_networking_network_v2" "direct" {
  name      = "ovn-bgp-direct"
  tenant_id = data.openstack_identity_project_v3.demo.id
  external  = false
  shared    = false
  segments {
    physical_network = "public"
    network_type     = "flat"
  }
}

resource "openstack_networking_subnet_v2" "direct" {
  provider    = openstack.demo
  name        = "ovn-bgp-direct-v4"
  network_id  = openstack_networking_network_v2.direct.id
  cidr        = "10.53.0.0/24"
  gateway_ip  = "10.53.0.1"
  enable_dhcp = true
}

resource "openstack_networking_secgroup_v2" "guest" {
  provider    = openstack.demo
  name        = "ovn-bgp-icmp"
  description = "Allow the fabric spine to probe guest addresses"
}

resource "openstack_networking_secgroup_rule_v2" "icmp" {
  provider          = openstack.demo
  security_group_id = openstack_networking_secgroup_v2.guest.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "icmp"
  remote_ip_prefix  = "10.211.255.3/32"
}

resource "openstack_networking_port_v2" "guest" {
  provider           = openstack.demo
  for_each           = local.guests
  name               = "${each.value.name}-port"
  network_id         = openstack_networking_network_v2.direct.id
  security_group_ids = [openstack_networking_secgroup_v2.guest.id]
  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.direct.id
    ip_address = each.value.ip
  }
}

resource "openstack_compute_instance_v2" "guest" {
  provider          = openstack.demo
  for_each          = local.guests
  name              = each.value.name
  availability_zone = openstack_compute_aggregate_v2.placement[each.key].zone
  flavor_id         = openstack_compute_flavor_v2.guest.id
  image_name        = "ubuntu-cloud"
  network {
    port = openstack_networking_port_v2.guest[each.key].id
  }
}
