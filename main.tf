resource "random_id" "id" {
  byte_length = 8
}

resource "hsdp_container_host" "prometheus" {
  count         = 1
  name          = "prometheus-${random_id.id.hex}-${count.index}.dev"
  volumes       = 1
  volume_size   = var.volume_size
  instance_type = var.instance_type

  user_groups     = var.user_groups
  security_groups = ["analytics"]

  connection {
    bastion_host = var.bastion_host
    host         = self.private_ip
    user         = var.user
    private_key  = var.private_key
    script_path  = "/home/${var.user}/bootstrap.bash"
  }

  provisioner "remote-exec" {
    inline = [
      "docker volume create prometheus",
      "docker run -v prometheus:/prometheus -p8080:9090 bitnami/prometheus:latest"
    ]
  }
}

data "archive_file" "fixture" {
  type = "zip"
  source_dir = "${path.module}/nginx-reverse-proxy"
  output_path = "${path.module}/nginx-reverse-proxy.zip"
  depends_on = [local_file.nginx_conf]
}

data "cloudfoundry_org" "org" {
  name = var.org_name
}

data "cloudfoundry_user" "user" {
  name = var.user
}

resource "cloudfoundry_space" "space" {
  name = "prometheus-${random_id.id.hex}"
  org  = data.cloudfoundry_org.org.id

}

resource "cloudfoundry_space_users" "users" {
  space = cloudfoundry_space.space.id
  managers = [ data.cloudfoundry_user.user.id ]
  developers = [ data.cloudfoundry_user.user.id ]
  auditors = [ data.cloudfoundry_user.user.id ]
}

resource "cloudfoundry_app" "prometheus_proxy" {
  name = "nginx-${random_id.id.hex}"
  space = cloudfoundry_space.space.id
  memory = 256
  disk_quota = 256
  path = "${path.module}/nginx-reverse-proxy.zip"
  buildpack = "https://github.com/cloudfoundry/nginx-buildpack.git"

  depends_on = [data.archive_file.fixture]
}

resource "local_file" "nginx_conf" {
  filename = "${path.module}/nginx-reverse-proxy/nginx.conf"
  content=<<EOF
worker_processes 1;
daemon off;
error_log stderr;
events { worker_connections 1024; }
pid /tmp/nginx.pid;
http {
  charset utf-8;
  log_format cloudfoundry 'NginxLog "$request" $status $body_bytes_sent';
  access_log /dev/stdout cloudfoundry;
  default_type application/octet-stream;
  include mime.types;
  sendfile on;
  tcp_nopush on;
  keepalive_timeout 30;
  port_in_redirect off; # Ensure that redirects don't include the internal container PORT - 8080
  resolver 169.254.0.2;

  upstream prometheus {
    server ${hsdp_container_host.prometheus[0].private_ip}:8080;
  }

  server {
      listen {{port}}; # This will be replaced by CF magic. Just leave it here.
      index index.html index.htm Default.htm;

      location / {
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_http_version 1.1;
        proxy_read_timeout 1800;

        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        client_max_body_size 10M;

        proxy_pass http://prometheus;
        break;
      }
  }
}
EOF

}