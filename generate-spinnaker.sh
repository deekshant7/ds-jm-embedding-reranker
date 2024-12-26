#!/bin/bash

# Check if the necessary arguments are given
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 path_to_server-config.yaml env(dsdev|stage|dsprod|...)"
    exit 1
fi

CONFIG_FILE=$1
ENV=$2

# Validate mandatory parameters
validate_mandatory_params() {
    for param in "$@"; do
        value=$(yq eval "$param" $CONFIG_FILE)
        if [ "$value" == "null" ]; then
            echo "Mandatory parameter $param missing in config file."
            exit 1
        fi
    done
}

validate_mandatory_params '.project' '.version' '.kubernetes.cpus' '.kubernetes.mem'

# Extract values using yq
project=$(yq eval '.project' $CONFIG_FILE)
version=$(yq eval '.version' $CONFIG_FILE)
port=$(yq eval '.server.applicationConnectors[0].port' $CONFIG_FILE)
k8s_cpus=$(yq eval '.kubernetes.cpus' $CONFIG_FILE)
k8s_mem=$(yq eval '.kubernetes.mem' $CONFIG_FILE)
k8s_workload=$(yq eval '.kubernetes.workload' $CONFIG_FILE)
#k8s_strategyType=$(yq eval '.kubernetes.strategyType' $CONFIG_FILE)
k8s_env_instances=$(yq eval ".kubernetes.env.$ENV.instances" $CONFIG_FILE)

# Extract Kubernetes specific details for the given environment
replicas=$(yq eval ".kubernetes.env.$ENV.instances" $CONFIG_FILE)
hpa_max=$(yq eval ".kubernetes.env.$ENV.hpaSpec.maxReplicas" $CONFIG_FILE)
hpa_min=$(yq eval ".kubernetes.env.$ENV.hpaSpec.minReplicas" $CONFIG_FILE)
target_cpu=$(yq eval ".kubernetes.env.$ENV.hpaSpec.targetCPUUtilizationPercentage" $CONFIG_FILE)
target_mem=$(yq eval ".kubernetes.env.$ENV.hpaSpec.targetMemoryUtilizationPercentage" $CONFIG_FILE)

# Generate Kubernetes deployment manifest
generate_k8s_manifest() {
    echo "apiVersion: apps/v1"
    echo "kind: Deployment"
    echo "metadata:"
    echo "  name: app"
    echo "spec:"
    echo "  replicas: $k8s_env_instances"
    echo "  strategy:"
    echo "    type: RollingUpdate"
    echo "  template:"
    echo "    metadata:"
    echo "      annotations:"
    echo "        sidecar.istio.io/inject: \"false\""
    echo "    spec:"
    echo "      containers:"
    echo "      - name: app"
#    echo "        image: $project:$version"
    echo "        ports:"
    echo "        - containerPort: $port"
    echo "          protocol: TCP"
    echo "          name: http"
    echo "        resources:"
    echo "          limits:"
    echo "            cpu: \"$k8s_cpus\""
    echo "            memory: ${k8s_mem}Mi"


    # Check if there are any env_vars specified
    env_vars=$(yq eval '.kubernetes.containerSpec.env' server-config.yaml)
    if [ ! -z "$env_vars" ] && [ "$env_vars" != "null" ]; then
        echo "        env:"
        echo "$env_vars" | \
        sed 's/^/         /' | sed 's/^         -/         -/'
    fi


    # Healthchecks
    healthcheck=$(yq eval '.kubernetes.healthcheck' $CONFIG_FILE)
    if [ "$healthcheck" == "default" ]; then
        echo "        livenessProbe:"
        echo "          httpGet:"
        echo "            path: /healthcheck"
        echo "            port: $port"
        echo "          initialDelaySeconds: 15"
        echo "        readinessProbe:"
        echo "          httpGet:"
        echo "            path: /healthcheck"
        echo "            port: $port"
        echo "          initialDelaySeconds: 15"
    else
        # You can dump direct configs here if they're in the format
        # that Kubernetes expects
        liveness=$(yq eval '.kubernetes.livenessProbe' $CONFIG_FILE)
        readiness=$(yq eval '.kubernetes.readinessProbe' $CONFIG_FILE)
        echo "        livenessProbe: $liveness"
        echo "        readinessProbe: $readiness"
    fi


    # Check if the volumes mounts exists
    volumesMounts=$(yq eval '.kubernetes.containerSpec.volumeMounts' server-config.yaml)
    if [ ! -z "$volumesMounts" ] && [ "$volumesMounts" != "null" ]; then
        echo "      volumeMounts:"
        echo "$volumesMounts" | \
        sed 's/^/        /' | sed 's/^       -/      -/'
    fi

    # Check if the volumes key exists
    volumes=$(yq eval '.kubernetes.deploymentSpec.template.spec.volumes' server-config.yaml)
    if [ ! -z "$volumes" ] && [ "$volumes" != "null" ]; then
        echo "      volumes:"
        echo "$volumes" | \
        sed 's/^/        /' | sed 's/^       -/      -/'
    fi

    if [ "$ENV" == "dsdev" ]; then
      if [ "$k8s_workload" == "gpu" ]; then
        cat <<EOFF
      nodeSelector:
        lifecycle: spot
        appType: gpuSpot
      tolerations:
        - value: gpuSpot
          effect: NoSchedule
          key: appType
          operator: Equal
EOFF
      else
        cat <<EOFF
      nodeSelector:
        lifecycle: spot
        appType: cpuIntensiveSpot
      tolerations:
        - value: cpuIntensiveSpot
          effect: NoSchedule
          key: appType
          operator: Equal
EOFF
      fi
    elif [ "$ENV" == "stage" ]; then
        if [ "$k8s_workload" == "gpu" ]; then
          cat <<EOFF
      tolerations:
        - value: gpuSpot
          effect: NoSchedule
          key: appType
          operator: Equal
EOFF
        else
          cat <<EOFF
      tolerations:
        - value: cpuIntensiveSpot
          effect: NoSchedule
          key: appType
          operator: Equal
EOFF
        fi
    elif [ "$ENV" == "dsprod" ]; then
        if [ "$k8s_workload" == "gpu" ]; then
          cat <<EOFF
      nodeSelector:
        lifecycle: spot
        appType: gpu
        appName: gpuSpot
      tolerations:
        - value: gpu
          effect: NoSchedule
          key: appType
          operator: Equal
        - value: gpuSpot
          effect: NoSchedule
          key: appName
          operator: Equal
EOFF
        fi
    fi
    # Generate Service
    cat <<EOL
---
apiVersion: v1
kind: Service
metadata:
  name: ms
spec:
  ports:
    - protocol: TCP
      port: 80
      name: http
      targetPort: $port
EOL
# Generate HPA manifest
    cat <<EOL
---
apiVersion: autoscaling/v2beta2
kind: HorizontalPodAutoscaler
metadata:
  name: hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: $project
  minReplicas: $hpa_min
  maxReplicas: $hpa_max
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: $target_cpu
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: $target_mem
EOL
# Generate Service Monitor
    cat <<EOL
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: sm
spec:
  endpoints:
    - interval: 10s
      path: /metrics
      port: http
EOL
# Add Virtual Service
    cat <<EOL
---
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: vs
spec:
  gateways:
    - jupiter/api-gateway-internal
  hosts:
    - $project-ms.dsdev.internal
  http:
    - match:
        - uri:
            prefix: /
      name: http
      route:
        - destination:
            host: $project-ms.jupiter.svc.cluster.local
            port:
              number: 80
EOL

}

generate_kustomization() {
  if [ "$ENV" == "stage" ]; then
    cat <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namePrefix: $project-
namespace: jupiter
commonLabels:
  app: $project
bases:
  - ../../base/

images:
  - name: app
    newName: 640468885682.dkr.ecr.ap-south-1.amazonaws.com/$project
patchesStrategicMerge:
  - patch.yml
EOF
  elif [ "$ENV" == "dsdev" ]; then
    cat <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namePrefix: $project-
namespace: jupiter
commonLabels:
  app: $project
bases:
  - ../base/

images:
  - name: app
    newName: 640468885682.dkr.ecr.ap-south-1.amazonaws.com/$project
patchesStrategicMerge:
  - patch.yml
EOF
  elif [ "$ENV" == "dsprod" ]; then
    cat <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namePrefix: $project-
namespace: jupiter
commonLabels:
  app: $project
bases:
  - ../base/

images:
  - name: app
    newName: 403223234871.dkr.ecr.ap-south-1.amazonaws.com/$project
patchesStrategicMerge:
  - patch.yml
EOF
  else
    echo "Unsupported Environment: $ENV"
    exit 1
  fi
}

# Generate pipeline.json
generate_pipeline() {
  if [ "$ENV" == "stage" ]; then
    cat <<EOF
{
    "name": "Deploy to stage",
    "variables": {
      "service": "$project",
      "namespace": "jupiter",
      "dockerAccount": "dsdev-ecr",
      "dockerImage": "$project",
      "imageTag": "master-*",
      "project": "$project",
      "basedir": "services/$project",
      "dockerRegistry": "640468885682.dkr.ecr.ap-south-1.amazonaws.com"
    },
    "description": "Deployment pipeline for $project on staging",
    "schema": "v2",
    "application": "$project",
    "template": {
      "artifactAccount": "front50ArtifactCredentials",
      "reference": "spinnaker://stage-kustomize-ds:latest",
      "type": "front50/pipelineTemplate"
    },
    "exclude": [],
    "triggers": [],
    "parameters": [],
    "notifications": [],
    "stages": []
}
EOF

  elif [ "$ENV" == "dsdev" ]; then
    cat <<EOF
{
    "name": "Deploy to $ENV",
    "variables": {
      "service": "$project",
      "namespace": "jupiter",
      "dockerAccount": "dsdev-ecr",
      "dockerImage": "$project",
      "imageTag": "",
      "project": "$project",
      "basedir": "services/$project",
      "dockerRegistry": "640468885682.dkr.ecr.ap-south-1.amazonaws.com"
    },
    "description": "Deployment pipeline for $project on dsdev",
    "schema": "v2",
    "application": "$project",
    "template": {
      "artifactAccount": "front50ArtifactCredentials",
      "reference": "spinnaker://dsdev-kustomize-staging:latest",
      "type": "front50/pipelineTemplate"
    },
    "exclude": [],
    "triggers": [],
    "parameters": [],
    "notifications": [],
    "stages": []
}
EOF

  elif [ "$ENV" == "dsprod" ]; then
    cat <<EOF
{
    "name": "Deploy to $ENV",
    "variables": {
      "service": "$project",
      "namespace": "jupiter",
      "dockerAccount": "dsprod-ecr",
      "dockerImage": "$project",
      "imageTag": "master-*",
      "project": "$project",
      "basedir": "services/$project",
      "dockerRegistry": "403223234871.dkr.ecr.ap-south-1.amazonaws.com"
    },
    "description": "Deployment pipeline for $project",
    "schema": "v2",
    "application": "$project",
    "template": {
      "artifactAccount": "front50ArtifactCredentials",
      "reference": "spinnaker://dsprod-kustomize:latest",
      "type": "front50/pipelineTemplate"
    },
    "exclude": [],
    "triggers": [],
    "parameters": [],
    "notifications": [],
    "stages": []
}
EOF

  else
    echo "Unsupported Environment: $ENV"
    exit 1
  fi
}

mkdir -p $ENV-manifests

generate_k8s_manifest > $ENV-manifests/patch.yml
generate_kustomization > $ENV-manifests/kustomization.yaml
generate_pipeline > $ENV-manifests/pipeline.json


echo "Generated $ENV-manifests successfully!"