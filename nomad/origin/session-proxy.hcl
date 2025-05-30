variable "load_balancer_conf" {
  type = string
  default = <<EOF
map $host $dbk_port {
  default         "";
  "~^(?<p>\d+)-"  ":$p";
}

map $host $dbk_session_id {
  default         "";
  "~-(?<s>\w+)-"  $s;
}

map $http_upgrade $conn_upgrade {
  default     "";
  "websocket" "Upgrade";
}

map $http_user_agent $is_browser {
  default                                 0;
  "~*mozilla|chrome|safari|opera|edge"    1;
}

log_format logger-json escape=json
'{'
'"source": "session-proxy",'
'"time": "$time_iso8601",'
'"resp_body_size": $body_bytes_sent,'
'"host": "$http_host",'
'"address": "$remote_addr",'
'"request_length": $request_length,'
'"method": "$request_method",'
'"uri": "$request_uri",'
'"status": $status,'
'"user_agent": "$http_user_agent",'
'"resp_time": $request_time,'
'"upstream_addr": "$upstream_addr",'
'"session_id": "$dbk_session_id",'
'"session_port": "$dbk_port"'
'}';
access_log /var/log/nginx/access.log logger-json;

server {
  listen 3003;
  
  # DNS server resolved addreses as to <sandbox-id> <ip-address>
  resolver 127.0.0.4 valid=0s;
  resolver_timeout 5s;

  proxy_set_header Host $host;
  proxy_set_header X-Real-IP $remote_addr;

  proxy_set_header Upgrade $http_upgrade;
  proxy_set_header Connection $conn_upgrade;

  proxy_hide_header x-frame-options;

  proxy_http_version 1.1;

  client_body_timeout 86400s;
  client_header_timeout 10s;

  proxy_read_timeout 600s;
  proxy_send_timeout 86400s;

  proxy_cache_bypass 1;
  proxy_no_cache 1;

  proxy_cache off;

  client_max_body_size 1024m;

  proxy_buffering off;
  proxy_request_buffering off;

  tcp_nodelay on;
  tcp_nopush on;
  sendfile on;

  # send_timeout                600s;

  proxy_connect_timeout 5s;
  keepalive_requests 8192;
  keepalive_timeout 630s;
  # gzip off;

  error_page 502 = @upstream_error;

  location @upstream_error {
    default_type text/html;
    absolute_redirect off;

    if ($is_browser = 1) {
      return 502; 
    } 

    rewrite ^ /error-json last;
  }

  location /error-json {
    default_type application/json;
    return 502 '{"error": "The sandbox is running but port is not open", "sandboxId": "$dbk_session_id", "port": "$dbk_port"}';
  }

  location / {
    if ($dbk_session_id = "") {
      # If you set any text, the header will be set to `application/octet-stream` and then browser won't be able to render the content
      return 400;
    }

    proxy_cache_bypass 1;
    proxy_no_cache 1;

    proxy_cache off;

    proxy_pass $scheme://$dbk_session_id$dbk_port$request_uri;
  }
}

server {
  listen 3004;

  location /health {
    access_log off;
    add_header 'Content-Type' 'application/json';
    return 200 '{"status":"UP"}';
  }

  location /status {
    access_log off;
    stub_status;
    allow all;
  }
}
EOF
}

variable "nginx_conf" {
  type = string
  default = <<EOF
user  nginx;
worker_processes  auto;

error_log  /var/log/nginx/error.log notice;
pid        /var/run/nginx.pid;


events {
    worker_connections  1024;
}


http {
    default_type  application/octet-stream;

    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;

    sendfile        on;
    #tcp_nopush     on;

    keepalive_time     86400s;

    #gzip  on;

    include /etc/nginx/conf.d/*.conf;
}
EOF
}

job "session-proxy" {
  type = "system"
  datacenters = ["${aws_az1}", "${aws_az2}"]

  priority = 80


  group "session-proxy" {
    network {
      port "session" {
        static = 3003
      }
      port "status" {
        static = 3004
      }
    }

    service {
      name = "session-proxy"
      port = "session"
      meta {
        Client = node.unique.id
      }

      check {
        type     = "http"
        name     = "health"
        path     = "/health"
        interval = "20s"
        timeout  = "5s"
        port     = "status"
      }

    }

    task "session-proxy" {
      driver = "docker"

      config {
        image        = "nginx:1.27.0"
        network_mode = "host"
        ports        = ["session", "status"]
        volumes = [
          "local:/etc/nginx",
          "/var/log/session-proxy:/var/log/nginx"
        ]
      }

      // TODO: Saner resources
      resources {
        memory_max = 6000
        memory = 2048
        cpu    = 1000
      }

      template {
        left_delimiter  = "[["
        right_delimiter = "]]"
        data            = var.load_balancer_conf
        destination     = "local/conf.d/load-balancer.conf"
        change_mode     = "signal"
        change_signal   = "SIGHUP"
      }

      template {
        left_delimiter  = "[["
        right_delimiter = "]]"
        data            = var.nginx_conf
        destination     = "local/nginx.conf"
        change_mode     = "signal"
        change_signal   = "SIGHUP"
      }
    }
  }
}