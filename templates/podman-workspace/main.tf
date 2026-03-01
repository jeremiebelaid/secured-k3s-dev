terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}

provider "coder" {}

provider "kubernetes" {
  config_path = null
}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

variable "namespace" {
  type    = string
  default = "coder"
}

variable "cpu_limit" {
  type    = string
  default = "2"
}

variable "memory_limit" {
  type    = string
  default = "4Gi"
}

variable "disk_size" {
  type    = string
  default = "10Gi"
}

locals {
  username = data.coder_workspace_owner.me.name
  home_dir = "/home/${local.username}"
  pvc_name = "coder-${lower(data.coder_workspace_owner.me.name)}-${lower(data.coder_workspace.me.name)}"
}

resource "coder_agent" "main" {
  os   = "linux"
  arch = "amd64"
  dir  = local.home_dir

  display_apps {
    vscode          = true
    web_terminal    = true
    vscode_insiders = false
  }

  env = {
    GIT_AUTHOR_NAME     = data.coder_workspace_owner.me.full_name
    GIT_COMMITTER_NAME  = data.coder_workspace_owner.me.full_name
    GIT_AUTHOR_EMAIL    = data.coder_workspace_owner.me.email
    GIT_COMMITTER_EMAIL = data.coder_workspace_owner.me.email
  }

  metadata {
    display_name = "CPU Usage"
    key          = "0_cpu_usage"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }
  metadata {
    display_name = "RAM Usage"
    key          = "1_ram_usage"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }

  startup_script = <<-EOF
    #!/bin/bash
    set -e

    python --version
    podman --version
    echo "Podman storage driver: $(podman info --format '{{.Store.GraphDriverName}}')"

    podman pull docker.io/library/alpine:latest || true
  EOF
}

resource "kubernetes_persistent_volume_claim_v1" "workspace" {
  metadata {
    name      = local.pvc_name
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"    = "coder-workspace"
      "app.kubernetes.io/part-of" = "coder"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "openebs-hostpath"
    resources {
      requests = {
        storage = var.disk_size
      }
    }
  }

}

resource "kubernetes_pod_v1" "workspace" {
  count = data.coder_workspace.me.start_count

  metadata {
    name      = "coder-${lower(data.coder_workspace_owner.me.name)}-${lower(data.coder_workspace.me.name)}"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"    = "coder-workspace"
      "app.kubernetes.io/part-of" = "coder"
      "coder.workspace.id"        = data.coder_workspace.me.id
      "coder.workspace.owner"     = data.coder_workspace_owner.me.name
    }
  }

  spec {
    security_context {
      fs_group = 1000
    }

    container {
      name              = "dev"
      image             = "coder-podman:latest"
      image_pull_policy = "Never"

      command = ["sh", "-c", coder_agent.main.init_script]

      security_context {
        privileged = true
      }

      env {
        name  = "CODER_AGENT_TOKEN"
        value = coder_agent.main.token
      }

      env {
        name  = "CODER_USERNAME"
        value = local.username
      }

      resources {
        requests = {
          cpu    = "500m"
          memory = "1Gi"
        }
        limits = {
          cpu    = var.cpu_limit
          memory = var.memory_limit
        }
      }

      volume_mount {
        name       = "workspace-data"
        mount_path = local.home_dir
      }

      volume_mount {
        name       = "podman-storage"
        mount_path = "/var/lib/containers"
      }
    }

    volume {
      name = "workspace-data"
      persistent_volume_claim {
        claim_name = local.pvc_name
      }
    }

    volume {
      name = "podman-storage"
      empty_dir {
        size_limit = "10Gi"
      }
    }
  }
}
