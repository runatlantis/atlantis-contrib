resource "google_service_account" "atlantis_management" {
  account_id = "atlantis-management"
  project    = local.project_id
}

resource "google_project_iam_member" "atlantis_management_owner" {
  member  = "serviceAccount:${google_service_account.atlantis_management.email}"
  project = local.project_id
  role    = "roles/owner"
}

# Grant the Atlantis Management service account permission to read/write Terraform state
# in the shared Terraform state bucket.
# Note: For brevity in this example, we grant full object access here. In practice,
# it's better to restrict access to specific prefixes!
resource "google_storage_bucket_iam_member" "atlantis_management_terraform_state_object_admin" {
  bucket = data.google_storage_bucket.terraform_state.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.atlantis_management.email}"
}

resource "google_secret_manager_secret_iam_member" "atlantis_gitlab_token_atlantis_management_secret_accessor" {
  secret_id = google_secret_manager_secret.atlantis_gitlab_token.secret_id
  project   = google_secret_manager_secret.atlantis_gitlab_token.project
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.atlantis_management.email}"
}

resource "google_secret_manager_secret_iam_member" "atlantis_webhook_atlantis_management_secret_accessor" {
  secret_id = google_secret_manager_secret.atlantis_webhook.secret_id
  project   = google_secret_manager_secret.atlantis_webhook.project
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.atlantis_management.email}"
}

resource "google_artifact_registry_repository_iam_member" "ghcr_management_atlantis_registry_reader" {
  project    = google_artifact_registry_repository.ghcr.project
  location   = google_artifact_registry_repository.ghcr.location
  repository = google_artifact_registry_repository.ghcr.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.atlantis_network.email}"
}

resource "google_cloud_run_v2_service" "atlantis_management" {
  provider             = google-beta
  name                 = "atlantis-management"
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
    service_account       = google_service_account.atlantis_management.email
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
        value = jsonencode(yamldecode(file("${path.module}/atlantis/management.yaml")))
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

resource "google_compute_managed_ssl_certificate" "atlantis_management" {
  provider = google-beta
  name     = "atlantis-management"
  managed {
    domains = ["management.${local.atlantis_domain}"]
  }
  project = local.project_id
}

resource "google_compute_region_network_endpoint_group" "atlantis_management" {
  name                  = "atlantis-management"
  network_endpoint_type = "SERVERLESS"
  region                = google_cloud_run_v2_service.atlantis_management.location
  cloud_run {
    service = google_cloud_run_v2_service.atlantis_management.name
  }
  project = local.project_id
}

resource "google_compute_backend_service" "atlantis_management" {
  name                  = "atlantis-management"
  protocol              = "HTTP"
  port_name             = "http"
  timeout_sec           = 30
  load_balancing_scheme = "EXTERNAL_MANAGED"
  security_policy       = google_compute_security_policy.atlantis.id
  backend {
    group = google_compute_region_network_endpoint_group.atlantis_management.id
  }
  iap {
    enabled              = true
    oauth2_client_id     = data.google_secret_manager_secret_version_access.atlantis_oauth2_client_id.secret_data
    oauth2_client_secret = data.google_secret_manager_secret_version_access.atlantis_oauth2_client_secret.secret_data
  }
  log_config {
    enable      = true
    sample_rate = 1.0
  }
  project = local.project_id
}

resource "google_compute_backend_service" "atlantis_management_webhooks" {
  name                  = "atlantis-management-webhooks"
  protocol              = "HTTP"
  port_name             = "http"
  timeout_sec           = 30
  load_balancing_scheme = "EXTERNAL_MANAGED"
  security_policy       = google_compute_security_policy.atlantis_events_webhook.id
  backend {
    group = google_compute_region_network_endpoint_group.atlantis_management.id
  }
  log_config {
    enable      = true
    sample_rate = 1.0
  }
  project = local.project_id
}
