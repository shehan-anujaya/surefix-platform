# SureFix Lite — Microservices Platform (parent repository)

| | |
|---|---|
| **Student Name** | Shehan Anujaya |
| **Student Number** | __STUDENT_NUMBER__ |
| **Slack Handle** | __SLACK_HANDLE__ |
| **GCP Project ID** | `surefix-eca` |
| **Module** | ITS 2130 – Enterprise Cloud Architecture (HDSE @ IJSE) |

## Project Description

**SureFix Lite** is a cloud-native, microservice-based bug pipeline inspired by an AI QA tool:
a bug is **detected**, a **run** reproduces / fixes it, and **evidence** (screenshots, traces) is attached.

This repository is the **platform layer** super-repo. It contains the Spring Cloud infrastructure
services as Git submodules plus the GCP infrastructure scripts:

| Submodule | Purpose | Port |
|---|---|---|
| [`config-server`](https://github.com/shehan-anujaya/surefix-config-server) | Spring Cloud Config Server – centralised configuration for all services (backed by [`surefix-config`](https://github.com/shehan-anujaya/surefix-config)) | 8888 |
| [`eureka-server`](https://github.com/shehan-anujaya/surefix-eureka-server) | Eureka Service Registry – service registration & discovery | 8761 |
| [`api-gateway`](https://github.com/shehan-anujaya/surefix-api-gateway) | Spring Cloud Gateway – single entry point for every backend API | 8080 |

Related repositories: [Services parent](https://github.com/shehan-anujaya/surefix-services) ·
[Frontend](https://github.com/shehan-anujaya/surefix-frontend) · [Config repo](https://github.com/shehan-anujaya/surefix-config)

## Architecture on GCP

```
 Browser ──HTTPS──▶ Cloud Run (frontend, nginx) ──HTTP──▶ External HTTP Load Balancer
                                                             │
                                        VPC surefix-vpc      ▼   regional MIG (2 × e2-small, 3 zones)
                                        ┌──────────────── api-gateway ────────────────┐
                                        │        ▲ discovery              ▲ config     │
                                        │  ILB eureka.surefix.internal  ILB config.surefix.internal
                                        │  regional MIG eureka-server   regional MIG config-server ──▶ GitHub (surefix-config)
                                        │        ▲                                                       via Cloud NAT
                                        │  MIG bug-service (autoscaled)  MIG run-service (autoscaled)  MIG evidence-service (autoscaled)
                                        │        │                              │                              │
                                        │  Cloud SQL (PostgreSQL 17)     Firestore (MongoDB API)     Cloud Storage bucket
                                        └────────────────────────────────────────────────────────────────────┘
                                   Zipkin on Cloud Run collects traces from every service
```

GCP resources used: VPC network, subnet, firewall rules, Cloud Router, Cloud NAT, custom disk image,
instance templates, regional managed instance groups + autoscalers, health checks, internal & external
load balancing, private Cloud DNS zone, Cloud SQL, Firestore (Enterprise, MongoDB compatible),
Cloud Storage buckets, Secret Manager, service accounts, Workload Identity Federation (GitHub Actions),
Cloud Run (frontend + Zipkin).

Deployment model: **backend = IaaS** (Compute Engine VMs managed by PM2, no containers),
**frontend = PaaS/Serverless** (Cloud Run).

## Technology Stack

- Java 25, Spring Boot 4.0.8, Spring Cloud 2025.1.3 (Config, Netflix Eureka, Gateway, LoadBalancer)
- Micrometer Tracing + Zipkin (distributed tracing)
- PM2 (process management, auto-restart, boot persistence) on Debian 12 VMs
- Google Cloud Platform (see list above), gcloud CLI scripts in [`infra/`](infra)
- GitHub Actions + Workload Identity Federation for CI/CD

## Setup / Getting Started

### Clone with submodules
```bash
git clone --recurse-submodules https://github.com/shehan-anujaya/surefix-platform.git
# or, after a plain clone:
git submodule update --init --recursive
```

### Run locally
Requires JDK 25 and Maven 3.9+. Start in this order (each in its own terminal):
```bash
# 1. registry
cd eureka-server && mvn spring-boot:run
# 2. config server (point it at a local clone of surefix-config, or leave the default GitHub URL)
cd config-server && CONFIG_GIT_URI=file:///path/to/surefix-config ENCRYPT_KEY=local-dev-key mvn spring-boot:run
# 3. gateway
cd api-gateway && mvn spring-boot:run
```
Then start the services from the [services repo](https://github.com/shehan-anujaya/surefix-services).
Eureka dashboard: http://localhost:8761 — Gateway: http://localhost:8080

### Deploy to GCP
All scripts are idempotent and use only the gcloud CLI:
```bash
cd infra
./01-network.sh   # VPC, subnet, firewall rules, Cloud Router, Cloud NAT
./02-data.sh      # Secret Manager, Cloud SQL (PostgreSQL), Firestore (MongoDB API), buckets
./03-iam.sh       # service accounts, Workload Identity Federation for GitHub Actions
./04-image.sh     # custom disk image: Debian 12 + Temurin 25 + Node 22 + PM2
./deploy.sh ../config-server && ./deploy.sh ../eureka-server && ./deploy.sh ../api-gateway   # build + upload jars
./05-migs.sh      # Zipkin, private DNS, health checks, instance templates, regional MIGs, autoscalers
./06-lb.sh        # internal LBs (config, eureka) + external HTTP LB (gateway)
```
`startup.sh` runs on every VM boot: it downloads the component jar from the artifact bucket,
writes `/etc/surefix/env` and starts the app with PM2 (`pm2 startOrReload` + `pm2 save`).
PM2 itself is registered as a systemd service in the image, so processes survive VM restarts.

### CI/CD
Every component repository has a GitHub Actions workflow that builds the jar, authenticates to GCP
with **Workload Identity Federation** (no service-account keys), uploads the jar to the artifact bucket
and performs a **rolling replace** of the corresponding managed instance group.
