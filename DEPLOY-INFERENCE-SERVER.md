# Deploying an Inference Server on Jetson

Nov 9, 2026 · Yuval Dekel

Package an ONNX model as an image, commit four manifests, and Argo CD deploys it to the Jetson. Triton serves it on the GPU over the v2 inference API.

## Before you start

| What | Value |
| --- | --- |
| Namespace | `<namespace>` |
| Argo CD | Your instance, connected to the Jetson's MicroShift as the destination cluster `<jetson_name>` |
| ClusterSecretStore | `<secret_store>` |
| Route hosts | Any name under `*.apps.<jetson_name>.<base_domain>` |
| Serving runtime | `triton-igpu`, below |

KServe and External Secrets are already on the device.

## KServe and the Triton runtime

**KServe** serves models on Kubernetes. You describe a model in an InferenceService: its format, where it is stored and which runtime serves it. KServe creates the Deployment, the Service and the wiring between them. Here it runs in Standard mode: one plain Deployment per model, with no autoscaling and no ingress, which is why you add a Route to test.

**A serving runtime** is the server template KServe starts for a model: its container image, the formats it loads, its ports and its resources. A ClusterServingRuntime is one every namespace can use.

**`triton-igpu`** is the runtime we install: NVIDIA Triton Inference Server, built for the Jetson's integrated GPU. Your InferenceService names it in step 4. KServe runs your model image beside Triton in the same pod (a "modelcar", from the `oci://` address), and Triton reads the model files straight from it. Its settings:

| Setting | Value |
| --- | --- |
| Image | `nvcr.io/nvidia/tritonserver:25.02-py3-igpu`, Triton built for Jetson's integrated GPU |
| Model formats | `onnx` and `tensorrt` |
| API | v2 REST on port 8080, the only port the Service exposes; gRPC is not exposed |
| Model repository | `/mnt/models`, linked to `/models` in your image |
| GPU | One `nvidia.com/gpu`: a time slice of the Orin's GPU, shared by up to four pods, with no memory isolation between them |
| Memory | 8 GiB request and limit. GPU allocations count against it: the integrated GPU uses system RAM |
| CPU | 1 core requested, up to 4 |

- **TensorRT plans** load only in this image's TensorRT version: build them with `trtexec` from the same image, on an Orin. Name the file `model.plan` and set `modelFormat: tensorrt`.
- **More memory or CPU:** set `resources` under `spec.predictor.model` in the InferenceService. Ask us first: the device is shared.

## 1. Model image

A Triton model repository under `/models`:

```text
models/
└── resnet50/
    ├── config.pbtxt     # optional
    └── 1/
        └── model.onnx
```

```dockerfile
FROM registry.access.redhat.com/ubi9/ubi-minimal
COPY models/ /models/
```

```bash
chmod -R a+rX models/
podman build --platform linux/arm64 -t <quay_host>/<quay_org>/resnet50:1 .
podman push <quay_host>/<quay_org>/resnet50:1
```

- **A shell in the base** (`ubi-minimal`, `busybox`): KServe runs `sh` inside it. `FROM scratch` fails.
- **`linux/arm64`**: the Jetson is ARM.
- **World-readable files**: the pod runs as a random UID.
- **A new tag per version**: the device never re-pulls a tag it already has.

## 2. Argo CD Application

Point it at the folder holding the manifests from steps 3 to 5:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: resnet50
  namespace: <argocd_namespace>
spec:
  project: <argocd_project>
  source:
    repoURL: https://<gitlab_host>/<group>/<repository>.git
    targetRevision: main
    path: resnet50
  destination:
    name: <jetson_name>
    namespace: <namespace>
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

## 3. Pull secret

Create a Quay robot with read access to the image, and store its credentials in `<secret_store>`'s backend under `<robot_secret_key>`, as the properties `username` and `token`. This ExternalSecret turns them into the pull secret `quay-pull`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: quay-pull
  namespace: <namespace>
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: <secret_store>
  target:
    name: quay-pull
    template:
      type: kubernetes.io/dockerconfigjson
      data:
        .dockerconfigjson: '{"auths":{"<quay_host>":{"auth":"{{ printf "%s:%s" .username .token | b64enc }}"}}}'
  data:
    - secretKey: username
      remoteRef:
        key: <robot_secret_key>
        property: username
    - secretKey: token
      remoteRef:
        key: <robot_secret_key>
        property: token
```

## 4. InferenceService

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: resnet50
  namespace: <namespace>
  annotations:
    serving.kserve.io/autoscalerClass: none
spec:
  predictor:
    imagePullSecrets:
      - name: quay-pull
    model:
      runtime: triton-igpu
      protocolVersion: v2
      modelFormat:
        name: onnx
      storageUri: oci://<quay_host>/<quay_org>/resnet50:1
```

- **`protocolVersion: v2`** is required: KServe defaults ONNX to v1, which Triton does not serve.
- **`autoscalerClass: none`**: the cluster has no metrics server, so an autoscaler never works.
- **`oci://`** runs your image beside Triton, which reads the model from it. To ship a new version, push a new tag and change it here.

## 5. Test through a Route

```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: resnet50
  namespace: <namespace>
spec:
  host: resnet50.apps.<jetson_name>.<base_domain>
  to:
    kind: Service
    name: resnet50-predictor      # <inferenceservice_name>-predictor
  port:
    targetPort: 8080
  tls:
    termination: edge
```

```bash
URL=https://resnet50.apps.<jetson_name>.<base_domain>
curl -k $URL/v2/models/resnet50/ready                        # 200 when loaded
curl -k $URL/v2/models/resnet50                              # input and output names, shapes
curl -k $URL/v2/models/resnet50/config | jq .instance_group  # KIND_GPU, not KIND_CPU
curl -k -X POST $URL/v2/models/resnet50/infer -H 'Content-Type: application/json' \
  -d '{"inputs": [{"name": "input", "datatype": "FP32", "shape": [1, 3, 224, 224], "data": [ ... ]}]}'
```

- **`-k`**: the Route uses the device's own certificate.
- **The model name in the URL** is the directory under `/models`, not the InferenceService name.
- **No authentication** on the Route: delete it when you finish testing.

## If something fails

| Symptom | Cause |
| --- | --- |
| ExternalSecret not synced | Wrong `<secret_store>` or `<robot_secret_key>`, or the properties are not `username` and `token` |
| `ImagePullBackOff` | The robot cannot read the image |
| `exec format error` | Image not built for `linux/arm64` |
| `sh: not found` | Image built `FROM scratch` |
| Pod Running, `/ready` not 200 | Triton could not load the model; the `kserve-container` logs say why |
| `instance_group` is `KIND_CPU` | The model is not on the GPU; tell us |
| Argo CD cannot reach `<jetson_name>` | The device is off the network; tell us |
