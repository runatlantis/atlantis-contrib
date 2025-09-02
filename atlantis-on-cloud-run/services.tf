data "google_project" "default" {
  project_id = local.project_id
}

# Below APIs are required for Atlantis on Cloud Run to function properly.
locals {
  services = [
    "compute.googleapis.com",
    "redis.googleapis.com",
    "run.googleapis.com",
    "memorystore.googleapis.com",
    "vpcaccess.googleapis.com",
    "artifactregistry.googleapis.com",
    "iam.googleapis.com",
    "iap.googleapis.com",
    "storage.googleapis.com",
    "secretmanager.googleapis.com",
    "dns.googleapis.com",
    "servicenetworking.googleapis.com",
    "networkmanagement.googleapis.com",
    "containerscanning.googleapis.com",
  ]
}

resource "google_project_service" "services" {
  for_each           = toset(local.services)
  project            = data.google_project.default.project_id
  service            = each.value
  disable_on_destroy = false
}
