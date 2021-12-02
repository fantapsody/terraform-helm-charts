#
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
#

terraform {
  required_version = ">=1.0.0"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = ">=2.2.0"
    }
  }
}

### Module defaults are managed below:
locals {
  atomic           = var.atomic != null ? var.atomic : true
  chart_name       = var.chart_name != null ? var.chart_name : "opentelemetry-collector"
  chart_repository = var.chart_repository != null ? var.chart_repository : "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart_version    = var.chart_version != null ? var.chart_version : "0.8.0"
  cleanup_on_fail  = var.cleanup_on_fail != null ? var.cleanup_on_fail : true
  cloud_provider   = var.cloud_provider != null ? var.cloud_provider : null
  create_namespace = var.create_namespace != null ? var.create_namespace : true
  image_version = var.image_version != null ? var.image_version : "0.40.0"
  namespace        = var.namespace != null ? var.namespace : "sn-system"
  release_name     = var.release_name != null ? var.release_name : "otel-collector"
  settings         = var.settings != null ? var.settings : {}
  timeout          = var.timeout != null ? var.timeout : 120
  values           = var.values != null ? var.values : [yamlencode(
    {
      "fullNameOverride": "opentelemetry-collector",
      "nameOverride": "opentelemetry-collector",
      "agentCollector": {
        "enabled": false
      },
      "autoscaling": {
        "enabled": true,
        "minReplicas": 1,
        "maxReplicas": 10,
        "targetCPUUtilizationPercentage": 80,
        "targetMemoryUtilizationPercentage": 80
      },
      "image": {
        "tag": local.image_version
      },
      "securityContext": {
        "fsGroup": 65534
      },
      "standaloneCollector": {
        "enabled": true
        "resources": {
          "limits": {
            "cpu": "500m",
            "memory": "256M"
          }
        }
      }
    }
  )]
}

resource "helm_release" "helm_chart" {
  atomic           = local.atomic
  chart            = local.chart_name
  cleanup_on_fail  = local.cleanup_on_fail
  create_namespace = local.create_namespace
  name             = local.release_name
  namespace        = local.namespace
  repository       = local.chart_repository
  timeout          = local.timeout
  version          = local.chart_version
  values           = local.values

  dynamic "set" {
    for_each = local.settings
    content {
      name  = set.key
      value = set.value
    }
  }
}

### Creates the configmap for exporting to Google Cloud Trace, if enabled
resource "kubernetes_manifest" "otel_configmap_gcp" {
  count = var.cloud_provider == "gcp" ? 1 : 0
  manifest = {
    "apiVersion" = "v1"
    "data" = {
      "relay" = <<-EOT
      exporters:
        googlecloud: {}
      extensions:
        health_check: {}
      processors:
        batch: {}
        memory_limiter:
          ballast_size_mib: 100
          check_interval: 5s
          limit_mib: 200
          spike_limit_mib: 62
      receivers:
        otlp:
          protocols:
            grpc:
            http:
      service:
        extensions:
        - health_check
        pipelines:
          traces:
            receivers: [otlp]
            processors: [memory_limiter, batch]
            exporters: [googlecloud]
          metrics:
            receivers: [otlp]
            processors: [memory_limiter, batch]
            exporters: [googlecloud]
      
      EOT
    }
    "kind" = "ConfigMap"
    "metadata" = {
      "labels" = {
        "app.kubernetes.io/instance" = "opentelemtry-collector"
        "app.kubernetes.io/name" = "opentelemetry-collector"
      }
      "name" = "opentelemetry-collector"
      "namespace" = local.namespace
    }
  }
}

resource "kubernetes_manifest" "otel_configmap_aws" {
  count = var.cloud_provider == "aws" ? 1 : 0
  manifest = {
    "apiVersion" = "v1"
    "data" = {
      "relay" = <<-EOT
      exporters:
        awsxray:
          index_all_attributes: true
      extensions:
        health_check: {}
      processors:
        batch: {}
        memory_limiter:
          ballast_size_mib: 100
          check_interval: 5s
          limit_mib: 200
          spike_limit_mib: 62
      receivers:
        otlp:
          protocols:
            grpc:
            http:
      service:
        extensions:
        - health_check
        pipelines:
          traces:
            exporters: [awsxray]
            processors: [memory_limiter, batch]
            receivers: [otlp]
      
      EOT
    }
    "kind" = "ConfigMap"
    "metadata" = {
      "labels" = {
        "app.kubernetes.io/instance" = "opentelemtry-collector"
        "app.kubernetes.io/managed-by" = "Helm"
        "app.kubernetes.io/name" = "opentelemetry-collector"
        "app.kubernetes.io/version" = "0.22.0"
        "helm.sh/chart" = "opentelemetry-collector-0.5.4"
      }
      "name" = "opentelemetry-collector"
      "namespace" = "sn-system"
    }
  }
}
