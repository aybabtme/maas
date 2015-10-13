provider "digitalocean" {}

resource "template_file" "cloud_config" {
    filename = "cloud_config.tpl"
    vars {
        discovery_url = "https://discovery.etcd.io/${var.discovery_token}"
    }
}

resource "digitalocean_droplet" "core_leader" {
    count = "${var.leader_count}"

    image              = "coreos-alpha"
    name               = "leader${count.index}.core"
    region             = "${var.region}"
    size               = "${var.leader_size}"
    ssh_keys           = ["${split(",", var.ssh_keys)}"]
    user_data          = "${template_file.cloud_config.rendered}"
    private_networking = true

    connection { user = "core" }
    provisioner "remote-exec" {
        script = "wait_etcd_healthy.sh"
    }
}

resource "digitalocean_droplet" "k8s_leader" {
    image              = "coreos-alpha"
    name               = "leader.kube"
    region             = "${var.region}"
    size               = "${var.follower_size}"
    ssh_keys           = ["${split(",", var.ssh_keys)}"]
    user_data          = "${template_file.cloud_config.rendered}"
    private_networking = true

    connection { user = "core" }
    provisioner "remote-exec" {
        script = "wait_etcd_healthy.sh"
    }

    # generate certificates
    provisioner "local-exec" {
        command = <<CMD
mkdir certs
pushd certs
# root cert authority
openssl genrsa -out ca-key.pem 2048
openssl req -x509 -new -nodes -key ca-key.pem -days 10000 -out ca.pem -subj "/CN=kube-ca"

cat > openssl.cnf <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names
[alt_names]
DNS.1 = kubernetes
DNS.2 = kubernetes.default
IP.1 = ${var.k8s_service_ip}
IP.2 = ${self.ipv4_address_private}
EOF

# API server keypair
openssl genrsa -out apiserver-key.pem 2048
openssl req -new -key apiserver-key.pem -out apiserver.csr -subj "/CN=kube-apiserver" -config openssl.cnf
openssl x509 -req -in apiserver.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -out apiserver.pem -days 365 -extensions v3_req -extfile openssl.cnf

# k8s worker keypair
openssl genrsa -out worker-key.pem 2048
openssl req -new -key worker-key.pem -out worker.csr -subj "/CN=kube-worker"
openssl x509 -req -in worker.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -out worker.pem -days 365

# admin keypair
openssl genrsa -out admin-key.pem 2048
openssl req -new -key admin-key.pem -out admin.csr -subj "/CN=kube-admin"
openssl x509 -req -in admin.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -out admin.pem -days 365

CMD
    }

    # install certificates
    provisioner "remote-exec" { inline = ["mkdir -p /etc/kubernetes/ssl/"] }
    provisioner "file" {
        source      = "certs/ca.pem"
        destination = "/etc/kubernetes/ssl/ca.pem"
    }
    provisioner "file" {
        source      = "certs/apiserver.pem"
        destination = "/etc/kubernetes/ssl/apiserver.pem"
    }
    provisioner "file" {
        source      = "certs/apiserver-key.pem"
        destination = "/etc/kubernetes/ssl/apiserver-key.pem"
    }

    provisioner "remote-exec" { inline = ["mkdir -p /etc/kubernetes/manifests/"] }
    provisioner "file" {
        source      = "kube/etc/kubernetes/manifests/kube-proxy.yaml"
        destination = "/etc/kubernetes/manifests/kube-proxy.yaml"
    }
    provisioner "file" {
        source      = "kube/srv/kubernetes/manifests/kube-controller-manager.yaml"
        destination = "/srv/kubernetes/manifests/kube-controller-manager.yaml"
    }
    provisioner "file" {
        source      = "kube/srv/kubernetes/manifests/kube-scheduler.yaml"
        destination = "/srv/kubernetes/manifests/kube-scheduler.yaml"
    }

    # setup dynamically rendered files =[
    provisioner "remote-exec" {
        inline = <<CMD
cat > /etc/flannel/options.env <<EOF
FLANNELD_IFACE=${self.ipv4_address_private}
FLANNELD_ETCD_ENDPOINTS=${join(":4001,", digitalocean_droplet.core_leader.*.ipv4_address_private)}
EOF

cat > /etc/systemd/system/flanneld.service.d/40-ExecStartPre-symlink.conf <<EOF
[Service]
ExecStartPre=/usr/bin/ln -sf /etc/flannel/options.env /run/flannel/options.env
EOF

cat > /etc/systemd/system/docker.service.d/40-flannel.conf <<EOF
[Unit]
Requires=flanneld.service
After=flanneld.service
EOF

cat > /etc/systemd/system/kubelet.service <<EOF
[Service]
ExecStart=/usr/bin/kubelet \
  --api_servers=http://127.0.0.1:8080 \
  --register-node=false \
  --allow-privileged=true \
  --config=/etc/kubernetes/manifests \
  --hostname-override=${self.ipv4_address_private} \
  --cluster_dns=${var.dns_service_ip} \
  --cluster_domain=cluster.local \
  --cadvisor-port=0
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/kubernetes/manifests/kube-apiserver.yaml <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: kube-apiserver
  namespace: kube-system
spec:
  hostNetwork: true
  containers:
  - name: kube-apiserver
    image: gcr.io/google_containers/hyperkube:v1.0.6
    command:
    - /hyperkube
    - apiserver
    - --bind-address=0.0.0.0
    - --etcd_servers=${join(":4001,", digitalocean_droplet.core_leader.*.ipv4_address_private)}
    - --allow-privileged=true
    - --service-cluster-ip-range=${var.service_ip_range}
    - --secure_port=443
    - --advertise-address=${self.ipv4_address_private}
    - --admission-control=NamespaceLifecycle,NamespaceExists,LimitRanger,SecurityContextDeny,ServiceAccount,ResourceQuota
    - --tls-cert-file=/etc/kubernetes/ssl/apiserver.pem
    - --tls-private-key-file=/etc/kubernetes/ssl/apiserver-key.pem
    - --client-ca-file=/etc/kubernetes/ssl/ca.pem
    - --service-account-key-file=/etc/kubernetes/ssl/apiserver-key.pem
    ports:
    - containerPort: 443
      hostPort: 443
      name: https
    - containerPort: 8080
      hostPort: 8080
      name: local
    volumeMounts:
    - mountPath: /etc/kubernetes/ssl
      name: ssl-certs-kubernetes
      readOnly: true
    - mountPath: /etc/ssl/certs
      name: ssl-certs-host
      readOnly: true
  volumes:
  - hostPath:
      path: /etc/kubernetes/ssl
    name: ssl-certs-kubernetes
  - hostPath:
      path: /usr/share/ca-certificates
    name: ssl-certs-host
EOF

cat > /etc/kubernetes/manifests/kube-podmaster.yaml <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: kube-podmaster
  namespace: kube-system
spec:
  hostNetwork: true
  containers:
  - name: scheduler-elector
    image: gcr.io/google_containers/podmaster:1.1
    command:
    - /podmaster
    - --etcd-servers=${join(":4001,", digitalocean_droplet.core_leader.*.ipv4_address_private)}
    - --key=scheduler
    - --whoami=${self.ipv4_address_private}
    - --source-file=/src/manifests/kube-scheduler.yaml
    - --dest-file=/dst/manifests/kube-scheduler.yaml
    volumeMounts:
    - mountPath: /src/manifests
      name: manifest-src
      readOnly: true
    - mountPath: /dst/manifests
      name: manifest-dst
  - name: controller-manager-elector
    image: gcr.io/google_containers/podmaster:1.1
    command:
    - /podmaster
    - --etcd-servers=${join(":4001,", digitalocean_droplet.core_leader.*.ipv4_address_private)}
    - --key=controller
    - --whoami=${self.ipv4_address_private}
    - --source-file=/src/manifests/kube-controller-manager.yaml
    - --dest-file=/dst/manifests/kube-controller-manager.yaml
    terminationMessagePath: /dev/termination-log
    volumeMounts:
    - mountPath: /src/manifests
      name: manifest-src
      readOnly: true
    - mountPath: /dst/manifests
      name: manifest-dst
  volumes:
  - hostPath:
      path: /srv/kubernetes/manifests
    name: manifest-src
  - hostPath:
      path: /etc/kubernetes/manifests
    name: manifest-dst
EOF

cat > /srv/kubernetes/manifests/kube-controller-manager.yaml <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: kube-controller-manager
  namespace: kube-system
spec:
  containers:
  - name: kube-controller-manager
    image: gcr.io/google_containers/hyperkube:v1.0.6
    command:
    - /hyperkube
    - controller-manager
    - --master=http://127.0.0.1:8080
    - --service-account-private-key-file=/etc/kubernetes/ssl/apiserver-key.pem
    - --root-ca-file=/etc/kubernetes/ssl/ca.pem
    livenessProbe:
      httpGet:
        host: 127.0.0.1
        path: /healthz
        port: 10252
      initialDelaySeconds: 15
      timeoutSeconds: 1
    volumeMounts:
    - mountPath: /etc/kubernetes/ssl
      name: ssl-certs-kubernetes
      readOnly: true
    - mountPath: /etc/ssl/certs
      name: ssl-certs-host
      readOnly: true
  hostNetwork: true
  volumes:
  - hostPath:
      path: /etc/kubernetes/ssl
    name: ssl-certs-kubernetes
  - hostPath:
      path: /usr/share/ca-certificates
    name: ssl-certs-host
EOF
CMD
    }

    # start all the services
    provisioner "remote-exec" {
        inline = <<CMD
sudo systemctl daemon-reload

etcdctl set /coreos.com/network/config {"Network":"${var.pod_network}"}

sudo systemctl enable kubelet
sudo systemctl start kubelet

try=0
until [ $try -ge 30 ]; do
    curl http://127.0.0.1:8080/version && break
    try=$[$try+1]
    sleep 1
done

curl -XPOST -d'{"apiVersion":"v1","kind":"Namespace","metadata":{"name":"kube-system"}}' "http://127.0.0.1:8080/api/v1/namespaces"

CMD
    }
}



resource "digitalocean_droplet" "k8s_worker" {
    count = "${var.follower_count}"

    depends_on = ["digitalocean_droplet.k8s_leader"]

    image              = "coreos-alpha"
    name               = "worker${count.index}.kube"
    region             = "${var.region}"
    size               = "${var.follower_size}"
    ssh_keys           = ["${split(",", var.ssh_keys)}"]
    user_data          = "${template_file.cloud_config.rendered}"
    private_networking = true

    connection { user = "core" }
    provisioner "remote-exec" {
        script = "wait_etcd_healthy.sh"
    }

    # install certificates
    provisioner "file" {
        source      = "certs/ca.pem"
        destination = "/etc/kubernetes/ssl/ca.pem"
    }
    provisioner "file" {
        source      = "certs/worker.pem"
        destination = "/etc/kubernetes/ssl/worker.pem"
    }
    provisioner "file" {
        source      = "certs/worker-key.pem"
        destination = "/etc/kubernetes/ssl/worker-key.pem"
    }

    provisioner "file" {
        source      = "certs/etc/kubernetes/worker-kubeconfig.yaml"
        destination = "/etc/kubernetes/worker-kubeconfig.yaml"
    }

    # setup dynamically rendered files =[
    provisioner "remote-exec" {
        inline = <<CMD
cat > /etc/flannel/options.env <<EOF
FLANNELD_IFACE=${self.ipv4_address_private}
FLANNELD_ETCD_ENDPOINTS=${join(":4001,", digitalocean_droplet.core_leader.*.ipv4_address_private)}
EOF

cat > /etc/systemd/system/flanneld.service.d/40-ExecStartPre-symlink.conf <<EOF
[Service]
ExecStartPre=/usr/bin/ln -sf /etc/flannel/options.env /run/flannel/options.env
EOF

cat > /etc/systemd/system/docker.service.d/40-flannel.conf <<EOF
[Unit]
Requires=flanneld.service
After=flanneld.service
EOF

cat > /etc/systemd/system/kubelet.service <<EOF
[Service]
ExecStart=/usr/bin/kubelet \
  --api_servers=https://${digitalocean_droplet.k8s_leader.ipv4_address_private} \
  --register-node=true \
  --allow-privileged=true \
  --config=/etc/kubernetes/manifests \
  --hostname-override=${self.ipv4_address_private} \
  --cluster_dns=${var.dns_service_ip} \
  --cluster_domain=cluster.local \
  --kubeconfig=/etc/kubernetes/worker-kubeconfig.yaml \
  --tls-cert-file=/etc/kubernetes/ssl/worker.pem \
  --tls-private-key-file=/etc/kubernetes/ssl/worker-key.pem \
  --cadvisor-port=0
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF

car > /etc/kubernetes/manifests/kube-proxy.yaml <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: kube-proxy
  namespace: kube-system
spec:
  hostNetwork: true
  containers:
  - name: kube-proxy
    image: gcr.io/google_containers/hyperkube:v1.0.6
    command:
    - /hyperkube
    - proxy
    - --master=https://${digitalocean_droplet.k8s_leader.ipv4_address_private}
    - --kubeconfig=/etc/kubernetes/worker-kubeconfig.yaml
    securityContext:
      privileged: true
    volumeMounts:
      - mountPath: /etc/ssl/certs
        name: "ssl-certs"
      - mountPath: /etc/kubernetes/worker-kubeconfig.yaml
        name: "kubeconfig"
        readOnly: true
      - mountPath: /etc/kubernetes/ssl
        name: "etc-kube-ssl"
        readOnly: true
  volumes:
    - name: "ssl-certs"
      hostPath:
        path: "/usr/share/ca-certificates"
    - name: "kubeconfig"
      hostPath:
        path: "/etc/kubernetes/worker-kubeconfig.yaml"
    - name: "etc-kube-ssl"
      hostPath:
        path: "/etc/kubernetes/ssl"
EOF
CMD
    }

    provisioner "remote-exec" {
        inline = <<CMD
sudo systemctl daemon-reload
sudo systemctl start kubelet
sudo systemctl enable kubelet
CMD
    }
}
