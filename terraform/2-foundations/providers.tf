terraform {
  required_version = ">= 1.9"
  backend "gcs" {}
  required_providers {
    google      = { source = "hashicorp/google", version = "~> 6.0" }
    google-beta = { source = "hashicorp/google-beta", version = "~> 6.0" }
  }
}

# The sandbox VM reaches Google APIs through a PSC all-apis endpoint whose TLS
# cert covers *.googleapis.com but not the regional *.rep.googleapis.com
# hostnames. Model Armor would default to the regional endpoint and fail TLS
# verification, so override it to the global hostname.
provider "google-beta" {
  model_armor_custom_endpoint = "https://modelarmor.googleapis.com/v1beta/"
}

variable "region" { type = string }

# One variable per project, named for the project it identifies.
# Supplied by stage 1-org as a .auto.tfvars.json artifact.
variable "gclt_aicoe_dev_network_project_id" { type = string }
variable "gclt_aicoe_dev_ingress_project_id" { type = string }
variable "gclt_aicoe_dev_aihub_ui_project_id" { type = string }
variable "gclt_aicoe_dev_st_project_id" { type = string }
variable "gclt_aicoe_dev_llm_project_id" { type = string }
variable "gclt_aicoe_dev_auditlogs_project_id" { type = string }
variable "gclt_aicoe_dev_apigee_project_id" { type = string }
variable "folder_id" { type = string }
variable "attestor_name" {
  type    = string
  default = ""
}
