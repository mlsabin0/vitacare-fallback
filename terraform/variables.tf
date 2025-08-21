variable "project_id" {
  type        = string
  description = "O ID do seu projeto no Google Cloud Platform. Ex: 'meu-projeto-12345'."
}

variable "region" {
  type        = string
  description = "A região do GCP onde a infraestrutura será criada."
  default     = "southamerica-east1"
}

variable "compute_service_account" {
  type        = string
  description = "O e-mail da conta de serviço que será usada pelas VMs. O padrão geralmente é '[NUMERO_DO_PROJETO]-compute@developer.gserviceaccount.com'."
}

variable "iap_support_email" {
  type        = string
  description = "O e-mail de suporte que será exibido na tela de consentimento do IAP."
}

variable "iap_access_group_email" {
  type        = string
  description = "O e-mail do Google Group que terá permissão de acesso à aplicação. Ex: 'grupo-fallback@suaempresa.com'."
}

variable "dns_domain_name" {
  type        = string
  description = "O novo nome de domínio que você registrou (ex: 'fallback-vitacare.com.br')."
}