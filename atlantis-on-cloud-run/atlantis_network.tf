/*
This file represents a single Atlantis Cloud Run instance.
It can be replicated for other domains to host multiple 
Atlantis instances.

Make sure to update the load balancer in atlantis.tf to route
traffic to this, and other, instances.
*/


## Each Atlantis instance is associated with one or more service accounts.
## These service accounts allow Atlantis to impersonate them, granting
## the necessary permissions to manage infrastructure in specific environments.
##
## In this example, we create two service accounts: one for development
## and one for production. The base service account (declared below) 
## can impersonate both of these accounts.
locals {
  atlantis_network_service_accounts = [
    "atlantis-network-dev",
    "atlantis-network-prod",
  ]
}

# This service account is used by the Atlantis Cloud Run service
# It has permissions to impersonate the service accounts declared above.
resource "google_service_account" "atlantis_network" {
  account_id = "atlantis-network"
  project    = local.project_id
}

# Grant the Atlantis Network service accounts permission to read/write Terraform state
# in the shared Terraform state bucket.
# Note: For brevity in this example, we grant full object access here. In practice,
# it's better to restrict access to specific prefixes!
resource "google_storage_bucket_iam_member" "atlantis_network_terraform_state_object_admin" {
  for_each = google_service_account.atlantis_network_service_accounts
  bucket   = data.google_storage_bucket.terraform_state.name
  role     = "roles/storage.objectAdmin"
  member   = "serviceAccount:${each.value.email}"

  depends_on = [
    google_service_account.atlantis_network_service_accounts,
  ]
}

# Create the service accounts that Atlantis can impersonate
resource "google_service_account" "atlantis_network_service_accounts" {
  for_each   = toset(local.atlantis_network_service_accounts)
  account_id = each.value
  project    = local.project_id
}

# Granting the impersonation role to the (base) Atlantis Network service account,
resource "google_service_account_iam_member" "atlantis_network_impersonation" {
  for_each           = google_service_account.atlantis_network_service_accounts
  service_account_id = each.value.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.atlantis_network.email}"
}

resource "google_secret_manager_secret_iam_member" "atlantis_gitlab_token_atlantis_network_secret_accessor" {
  secret_id = google_secret_manager_secret.atlantis_gitlab_token.secret_id
  project   = google_secret_manager_secret.atlantis_gitlab_token.project
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.atlantis_network.email}"
}

resource "google_secret_manager_secret_iam_member" "atlantis_webhook_atlantis_network_secret_accessor" {
  secret_id = google_secret_manager_secret.atlantis_webhook.secret_id
  project   = google_secret_manager_secret.atlantis_webhook.project
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.atlantis_network.email}"
}

resource "google_artifact_registry_repository_iam_member" "ghcr_network_atlantis_registry_reader" {
  project    = google_artifact_registry_repository.ghcr.project
  location   = google_artifact_registry_repository.ghcr.location
  repository = google_artifact_registry_repository.ghcr.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.atlantis_network.email}"
}

resource "google_cloud_run_v2_service" "atlantis_network" {
  provider             = google-beta
  name                 = "atlantis-network"
  location             = "europe-west4"
  deletion_protection  = false
  ingress              = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
  invoker_iam_disabled = true
  launch_stage         = "GA"

  template {
    scaling {
      min_instance_count = 1
      max_instance_count = 1
    }
    execution_environment = "EXECUTION_ENVIRONMENT_GEN2"
    service_account       = google_service_account.atlantis_network.email
    containers {
      image = "europe-west4-docker.pkg.dev/${local.project_id}/ghcr/runatlantis/atlantis:v0.35.1"
      resources {
        limits = {
          cpu    = "1"
          memory = "2Gi"
        }
      }
      volume_mounts {
        name       = "atlantis"
        mount_path = "/app/atlantis"
      }
      env {
        name  = "ATLANTIS_PORT"
        value = "8080"
      }
      env {
        name  = "ATLANTIS_DATA_DIR"
        value = "/app/atlantis"
      }
      env {
        name  = "ATLANTIS_USE_TF_PLUGIN_CACHE"
        value = "true"
      }
      env {
        name  = "ATLANTIS_DISCARD_APPROVAL_ON_PLAN"
        value = "true"
      }
      env {
        name  = "ATLANTIS_HIDE_PREV_PLAN_COMMENTS"
        value = "true"
      }
      env {
        name  = "ATLANTIS_HIDE_UNCHANGED_PLAN_COMMENTS"
        value = "true"
      }
      env {
        name  = "ATLANTIS_EMOJI_REACTION"
        value = "eyes"
      }
      env {
        name  = "ATLANTIS_CHECKOUT_STRATEGY"
        value = "merge"
      }
      env {
        name  = "ATLANTIS_WRITE_GIT_CREDS"
        value = "true"
      }
      env {
        name  = "ATLANTIS_GITLAB_USER"
        value = "acme-org-atlantis"
      }
      env {
        name = "ATLANTIS_GITLAB_TOKEN"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.atlantis_gitlab_token.id
            version = "latest"
          }
        }
      }
      env {
        name = "ATLANTIS_GITLAB_WEBHOOK_SECRET"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.atlantis_webhook.id
            version = "latest"
          }
        }
      }
      env {
        name  = "ATLANTIS_LOCKING_DB_TYPE"
        value = "redis"
      }
      env {
        name  = "ATLANTIS_REDIS_HOST"
        value = google_redis_instance.atlantis.host
      }
      env {
        name  = "ATLANTIS_REDIS_DB"
        value = "0"
      }
      env {
        name  = "ATLANTIS_REDIS_INSECURE_SKIP_VERIFY"
        value = "true"
      }
      env {
        name  = "ATLANTIS_ATLANTIS_URL"
        value = "https://${local.atlantis_domain}"
      }
      env {
        name  = "ATLANTIS_REPO_CONFIG_JSON"
        value = jsonencode(yamldecode(file("${path.module}/atlantis/network.yaml")))
      }
    }
    vpc_access {
      egress = "ALL_TRAFFIC"
      network_interfaces {
        network    = google_compute_network.example.name
        subnetwork = google_compute_subnetwork.example.name
        tags       = ["atlantis"]
      }
    }
    volumes {
      name = "atlantis"
      empty_dir {
        medium     = "MEMORY"
        size_limit = "5Gi"
      }
    }
  }
  project = local.project_id
}

resource "google_compute_managed_ssl_certificate" "atlantis_network" {
  provider = google-beta
  name     = "atlantis-network"
  managed {
    domains = ["network.${local.atlantis_domain}"]
  }
  project = local.project_id
}

resource "google_compute_region_network_endpoint_group" "atlantis_network" {
  name                  = "atlantis-network"
  network_endpoint_type = "SERVERLESS"
  region                = google_cloud_run_v2_service.atlantis_network.location
  cloud_run {
    service = google_cloud_run_v2_service.atlantis_network.name
  }
  project = local.project_id
}

resource "google_compute_backend_service" "atlantis_network" {
  name                  = "atlantis-network"
  protocol              = "HTTP"
  port_name             = "http"
  timeout_sec           = 30
  load_balancing_scheme = "EXTERNAL_MANAGED"
  security_policy       = google_compute_security_policy.atlantis.id
  backend {
    group = google_compute_region_network_endpoint_group.atlantis_network.id
  }
  iap {
    enabled = true
  }
  log_config {
    enable      = true
    sample_rate = 1.0
  }
  project = local.project_id
}

resource "google_compute_backend_service" "atlantis_network_webhooks" {
  name                  = "atlantis-network-webhooks"
  protocol              = "HTTP"
  port_name             = "http"
  timeout_sec           = 30
  load_balancing_scheme = "EXTERNAL_MANAGED"
  security_policy       = google_compute_security_policy.atlantis_events_webhook.id
  backend {
    group = google_compute_region_network_endpoint_group.atlantis_network.id
  }
  log_config {
    enable      = true
    sample_rate = 1.0
  }
  project = local.project_id
}
