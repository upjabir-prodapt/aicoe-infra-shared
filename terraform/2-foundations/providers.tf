terraform {
  required_version = ">= 1.9"
  backend "gcs" {}
  required_providers {
    google      = { source = "hashicorp/google",      version = "~> 6.0" }
    google-beta = { source = "hashicorp/google-beta", version = "~> 6.0" }
  }
}

variable "region" { type = string }

# One variable per project, named for the project it identifies.
# Supplied by stage 1-org as a .auto.tfvars.json artifact.
variable "gclt_aicoe_dev_network_project_id"   { type = string }
variable "gclt_aicoe_dev_ingress_project_id"   { type = string }
variable "gclt_aicoe_dev_aihub_ui_project_id"  { type = string }
variable "gclt_aicoe_dev_st_project_id"        { type = string }
variable "gclt_aicoe_dev_llm_project_id"       { type = string }
variable "gclt_aicoe_dev_auditlogs_project_id" { type = string }
variable "gclt_aicoe_dev_apigee_project_id"    { type = string }
variable "folder_id"            { type = string }
variable "org_log_project"      { type = string }
variable "attestor_name" {
  type    = string
  default = ""
}
variable "apigee_llm_runtime_sa" { type = string }
