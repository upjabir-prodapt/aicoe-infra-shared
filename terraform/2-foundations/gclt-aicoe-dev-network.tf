# gclt-aicoe-dev-network
# Deliberately thin: the network itself is network/base.

module "gclt_aicoe_dev_network_baseline" {
  source     = "../modules/project-baseline"
  project_id = var.gclt_aicoe_dev_network_project_id
  services = [
    "compute.googleapis.com",
    "dns.googleapis.com",
    "cloudkms.googleapis.com",
    "servicenetworking.googleapis.com", # enabled but unused — no PSA, no peering
    "networkconnectivity.googleapis.com",
  ]
  service_accounts = {
  }
}

output "gclt_aicoe_dev_network_service_accounts" { value = module.gclt_aicoe_dev_network_baseline.service_accounts }
