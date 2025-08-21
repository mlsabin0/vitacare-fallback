# Arquivo: main.tf
# VERSÃO FINAL, CORRIGIDA E CONSOLIDADA

# --- 0. Configuração do Provedor ---
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}
provider "google" {
  project = var.project_id
  region  = var.region
}

# --- 1. Rede VPC e Sub-redes ---
resource "google_compute_network" "vpc_hub" {
  name                    = "vpc-hub-inteligente"
  auto_create_subnetworks = false
}
resource "google_compute_subnetwork" "subnet_hub" {
  name          = "subnet-hub-proxies"
  ip_cidr_range = "10.10.0.0/24"
  network       = google_compute_network.vpc_hub.id
  region        = var.region
  private_ip_google_access = true
}
# Sub-rede especial exigida pelo Balanceador de Carga Regional.
resource "google_compute_subnetwork" "proxy_subnet" {
  name          = "proxy-only-subnet"
  ip_cidr_range = "10.10.1.0/26"
  network       = google_compute_network.vpc_hub.id
  region        = var.region
  purpose       = "REGIONAL_MANAGED_PROXY"
  role          = "ACTIVE"
}

# --- 2. Saída com IP Fixo (Cloud NAT) ---
resource "google_compute_address" "nat_ip" {
  name   = "ip-saida-vitacare"
  region = var.region
}
resource "google_compute_router" "router_hub" {
  name    = "router-hub-nat"
  network = google_compute_network.vpc_hub.id
  region  = var.region
}
resource "google_compute_router_nat" "nat_gateway" {
  name                               = "nat-gateway-vitacare"
  router                             = google_compute_router.router_hub.name
  region                             = var.region
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"
  nat_ip_allocate_option             = "MANUAL_ONLY"
  nat_ips                            = [google_compute_address.nat_ip.self_link]
  subnetwork {
    name                    = google_compute_subnetwork.subnet_hub.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
}

# --- 3. Repositório para a Aplicação ---
resource "google_artifact_registry_repository" "proxy_repo" {
  location      = var.region
  repository_id = "proxy-vitacare-repo"
  description   = "Repositório para a imagem do proxy customizado."
  format        = "DOCKER"
}

# --- 4. Firewall ---
resource "google_compute_firewall" "allow_lb_and_health_check" {
  name    = "allow-lb-and-health-check"
  network = google_compute_network.vpc_hub.id
  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = ["proxy-vm"]
}
resource "google_compute_firewall" "allow_ssh_iap" {
  name    = "allow-ssh-iap"
  network = google_compute_network.vpc_hub.id
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = ["35.235.240.0/20"]
}

# --- 5. Backend ---
# CORRIGIDO: Health Check GLOBAL para ser compatível com o Backend Service GLOBAL.
resource "google_compute_health_check" "http_health_check" {
  name = "http-proxy-health-check"
  tcp_health_check { port = "8080" }
}

resource "google_compute_instance_template" "proxy_template" {
  name_prefix  = "template-proxy-vitacare-"
  machine_type = "e2-medium"
  region       = var.region
  tags         = ["proxy-vm"]

  disk {
    source_image = "cos-cloud/cos-stable"
    auto_delete  = true
    boot         = true
  }

  network_interface {
    network       = google_compute_network.vpc_hub.id
    subnetwork    = google_compute_subnetwork.subnet_hub.id
  }

  metadata_startup_script = file("startup-script.sh")

  metadata = {
    "gce-container-declaration" = <<-EOT
      spec:
        containers:
          - name: proxy-app
            image: ${google_artifact_registry_repository.proxy_repo.location}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.proxy_repo.repository_id}/proxy-app:v6
            stdin: false
            tty: false
        restartPolicy: Always
    EOT
  }

  service_account {
    email  = var.compute_service_account
    scopes = ["cloud-platform"]
  }

  lifecycle {
    create_before_destroy = true
  }
}


resource "google_compute_region_instance_group_manager" "mig_proxy" {
  name               = "mig-proxy-vitacare"
  region             = var.region
  base_instance_name = "proxy-vm"
  target_size        = 1
  version {
    instance_template = google_compute_instance_template.proxy_template.id
  }
  
  named_port {
    name = "http"
    port = 8080
  }

  auto_healing_policies {
    # CORRIGIDO: A referência agora aponta para o health check GLOBAL.
    health_check      = google_compute_health_check.http_health_check.id
    initial_delay_sec = 300
  }
}
resource "google_compute_region_autoscaler" "autoscaler_proxy" {
  name   = "autoscaler-proxy-vitacare"
  region = var.region
  target = google_compute_region_instance_group_manager.mig_proxy.id
  autoscaling_policy {
    max_replicas    = 5
    min_replicas    = 1
    cpu_utilization { target = 0.60 }
    cooldown_period = 90
  }
}

# --- 6. Entrada (Load Balancer de Aplicativo GLOBAL) ---
resource "google_compute_global_address" "lb_ip" {
  name = "ip-externo-fallback-global"
}
resource "google_compute_managed_ssl_certificate" "ssl_certificate" {
  name = "cert-fallback-vitacare"
  managed {
    domains = [google_dns_record_set.fallback_a_record.name]
  }
}
resource "google_compute_backend_service" "backend_proxy" {
  name                  = "backend-service-proxy-global"
  protocol              = "HTTP"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  # CORRIGIDO: A referência agora aponta para o health check GLOBAL.
  health_checks         = [google_compute_health_check.http_health_check.id]
  backend {
    group             = google_compute_region_instance_group_manager.mig_proxy.instance_group
    balancing_mode    = "UTILIZATION"
    capacity_scaler   = 1.0
    max_utilization   = 0.8
  }
  iap {
    oauth2_client_id     = google_iap_client.iap_client.client_id
    oauth2_client_secret = google_iap_client.iap_client.secret
  }
}
resource "google_compute_url_map" "url_map_proxy" {
  name            = "url-map-proxy-global"
  default_service = google_compute_backend_service.backend_proxy.id
}
resource "google_compute_target_https_proxy" "https_proxy" {
  name             = "https-proxy-fallback-global"
  url_map          = google_compute_url_map.url_map_proxy.id
  ssl_certificates = [google_compute_managed_ssl_certificate.ssl_certificate.id]
}
resource "google_compute_global_forwarding_rule" "https_forwarding_rule" {
  name                  = "fr-https-fallback-global"
  ip_protocol           = "TCP"
  port_range            = "443"
  ip_address            = google_compute_global_address.lb_ip.address
  load_balancing_scheme = "EXTERNAL_MANAGED"
  target                = google_compute_target_https_proxy.https_proxy.id
}
resource "google_compute_url_map" "url_map_redirect" {
  name = "url-map-redirect-global"
  default_url_redirect {
    https_redirect         = true
    strip_query            = false
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
  }
}
resource "google_compute_target_http_proxy" "http_proxy_redirect" {
  name    = "http-proxy-redirect-global"
  url_map = google_compute_url_map.url_map_redirect.id
}
resource "google_compute_global_forwarding_rule" "http_forwarding_rule" {
  name                  = "fr-http-fallback-redirect-global"
  ip_protocol           = "TCP"
  port_range            = "80"
  ip_address            = google_compute_global_address.lb_ip.address
  load_balancing_scheme = "EXTERNAL_MANAGED"
  target                = google_compute_target_http_proxy.http_proxy_redirect.id
}

# --- 7. Segurança (Identity-Aware Proxy - IAP) ---
data "google_project" "project" {}
resource "google_iap_brand" "project_brand" {
  support_email     = var.iap_support_email
  application_title = "Acesso de Contingência VitaCare"
  project           = data.google_project.project.project_id
}
resource "google_iap_client" "iap_client" {
  display_name = "Cliente IAP para Acesso VitaCare"
  brand        = google_iap_brand.project_brand.name
}
# Versão GLOBAL do recurso de permissão do IAP.
resource "google_iap_web_backend_service_iam_member" "iap_access" {
  project             = google_compute_backend_service.backend_proxy.project
  web_backend_service = google_compute_backend_service.backend_proxy.name
  role                = "roles/iap.httpsResourceAccessor"
  member              = "group:${var.iap_access_group_email}"
}

# --- 8. DNS ---
resource "google_dns_managed_zone" "vitacare_fallback_zone" {
  name        = "vitacare-fallback-zone"
  dns_name    = "${var.dns_domain_name}."
  description = "Zona de DNS para o sistema de fallback do VitaCare."
}
resource "google_dns_record_set" "fallback_a_record" {
  name         = google_dns_managed_zone.vitacare_fallback_zone.dns_name
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.lb_ip.address]
  managed_zone = google_dns_managed_zone.vitacare_fallback_zone.name
}