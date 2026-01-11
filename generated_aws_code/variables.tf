variable "aws_region" {
  description = "The AWS region to deploy resources in."
  type        = string
  default     = "us-east-1"
}

variable "api_name" {
  description = "The name for the API Gateway API."
  type        = string
  default     = "UnderwritingAPI"
}

variable "stage_name" {
  description = "The deployment stage name for the API."
  type        = string
  default     = "prod"
}

variable "backend_url" {
  description = "The backend SOAP service endpoint URL."
  type        = string
  sensitive   = true
  default     = "https://backend.example.com/soap/UnderwritingService"
}

variable "ldap_host" {
  description = "LDAP server hostname or IP address."
  type        = string
  default     = "ldap.example.com"
}

variable "ldap_port" {
  description = "LDAP server port."
  type        = number
  default     = 389
}

variable "ldap_base_dn" {
  description = "LDAP Base DN for searches."
  type        = string
  default     = "DC=example,DC=com"
}

variable "ldap_group_dn" {
  description = "The distinguished name of the group required for authorization."
  type        = string
  default     = "CN=Underwriters,OU=Groups,DC=example,DC=com"
}

variable "ldap_bind_dn" {
  description = "The service account DN for binding to LDAP."
  type        = string
  default     = "CN=svc-datapower,OU=ServiceAccounts,DC=example,DC=com"
}

variable "ldap_bind_password" {
  description = "The password for the LDAP bind service account."
  type        = string
  sensitive   = true
  default     = "REPLACE_WITH_SECURE_PASSWORD"
}
