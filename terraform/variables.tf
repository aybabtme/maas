variable "region"         { default = "tor1" }
variable "leader_size"    { default = "1gb" }
variable "leader_count"   { default = 3 }
variable "follower_size"  { default = "4gb" }
variable "follower_count" { default = 1 }

# user provided

variable "ssh_keys" { }

variable "discovery_token" {
    description = <<EOF
Run this command to get a discovery URL

    curl -w "\n" 'https://discovery.etcd.io/new?size=${var.leader_size}'

EOF
}

# kubernetes

variable "pod_network"      { default = "10.2.0.0/16" }
variable "service_ip_range" { default = "10.3.0.0/24" }
variable "k8s_service_ip"   { default = "10.3.0.1" }
variable "dns_service_ip"   { default = "10.3.0.10" }
