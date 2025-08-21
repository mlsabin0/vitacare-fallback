output "load_balancer_ip" {
  description = "IP público do Load Balancer. Aponte o DNS do seu domínio de fallback para este IP."
  value       = google_compute_global_address.lb_ip.address
}

output "nat_ip_for_whitelist" {
  description = "IP de saída fixo do Cloud NAT. ESTE é o IP para adicionar à whitelist do sistema VitaCare."
  value       = google_compute_address.nat_ip.address
}

output "artifact_registry_repository_url" {
  description = "URL do repositório no Artifact Registry para onde a imagem Docker do proxy deve ser enviada."
  value       = "${google_artifact_registry_repository.proxy_repo.location}-docker.pkg.dev/${google_artifact_registry_repository.proxy_repo.project}/${google_artifact_registry_repository.proxy_repo.name}"
}

output "cloud_dns_name_servers" {
  description = "Name Servers do Cloud DNS. Configure estes endereços no seu registrador de domínio (Registro.br)."
  value       = google_dns_managed_zone.vitacare_fallback_zone.name_servers
}