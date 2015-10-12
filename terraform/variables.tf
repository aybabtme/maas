variable "region"         { default = "tor1" }
variable "leader_size"    { default = "1gb" }
variable "leader_count"   { default = 3 }
variable "follower_size"  { default = "4gb" }
variable "follower_count" { default = 10 }

# user provided

variable "ssh_keys" { }

variable "discovery_token" {
    description = <<EOF
Run this command to get a discovery URL

    curl -w "\n" 'https://discovery.etcd.io/new?size=${var.leader_size}'

EOF
}
