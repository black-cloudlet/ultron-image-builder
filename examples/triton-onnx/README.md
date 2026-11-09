# Test InferenceService: an ONNX modelcar from the air-gapped Quay

A by-hand test that the serving stack in the image works on a node: KServe's controller and
webhook, the `triton-igpu` runtime, the modelcar injection, restricted-v2 admission, and the GPU
slice from the device plugin. Nothing here is in the OS image, and no CI runs it.

The model is **pulled** at run time from the air-gapped Quay, not embedded: CI cannot reach that
registry. So this needs the node on the air-gapped network while the pod starts. A served model
for missions has to be embedded instead (`SERVICE_IMAGES` in `services/Containerfile`).

| File | What it is |
|---|---|
| `inferenceservice.yaml` | the InferenceService, namespace `inference-test`; edit `storageUri` |
| `infer.py` | sends an all-zeros request built from the model's metadata, prints latency |

`oc` below runs either on the node (`sudo -i`, then
`export KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig`) or on a laptop through the
SSH tunnel in the top-level README. Replace `quay.cloudlet.local` with your Quay host throughout.

## 0. The cluster is ready for it

```bash
oc get clusterservingruntime triton-igpu                  # exists
oc -n kserve get pods                                     # kserve-controller-manager 2/2 Running
oc get node -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}{"\n"}'   # 4
```

## 1. The image has the layout Triton and KServe expect

On any machine that can pull it:
```bash
podman run --rm --entrypoint sh quay.cloudlet.local/apps/onnx-model:1 -c 'ls -lR /models'
```
It must show `/models/<model-name>/1/model.onnx` (`config.pbtxt` beside `1/` is optional: Triton
derives one from ONNX). `<model-name>` is what you call it on later, not `onnx-test`. The command
itself proves `sh` is there; KServe's sidecar also runs `ln`, `ls` and `sleep`, so the image
needs a base (busybox, `ubi-minimal`), not `scratch`.

## 2. The node can pull from Quay

This is CRI-O pulling, on the node, so the node's DNS and trust are what count:
```bash
getent hosts quay.cloudlet.local          # resolves through 192.168.1.1
# Only if Quay's certificate is from your own CA (CRI-O reads this on every pull, no restart):
sudo mkdir -p /etc/containers/certs.d/quay.cloudlet.local
sudo cp quay-ca.crt /etc/containers/certs.d/quay.cloudlet.local/ca.crt
```
Your Quay host is not in `microshift/crio.conf.d/20-pinned-images.conf`, so kubelet may delete
the pulled image once it is unused. Keep it that way: a pinned pulled image is never deleted.

## 3. Namespace and pull secret

A Quay robot account with read access is enough. `read -s` keeps the token out of the history:
```bash
oc create namespace inference-test
read -rs QUAY_TOKEN
oc -n inference-test create secret docker-registry quay-pull \
  --docker-server=quay.cloudlet.local \
  --docker-username='<org>+<robot>' --docker-password="$QUAY_TOKEN"
unset QUAY_TOKEN
```
A public repository needs no secret; the missing one is only a warning event.

## 4. Deploy

Set `storageUri` in `inferenceservice.yaml` to `oci://<your image>`, then:
```bash
oc apply -f examples/triton-onnx/inferenceservice.yaml
oc -n inference-test get isvc onnx-test -w                # READY True, a minute or two
oc -n inference-test get pods                             # onnx-test-predictor-… 2/2 Running
```
The pod has an init container `modelcar-init` (checks `/models` is not empty), then
`kserve-container` (Triton) and `modelcar` (holds the model; Triton reads it through
`/proc/<pid>/root`, hence `shareProcessNamespace`). `kserve-container` may restart once if it
starts before the sidecar has linked `/mnt/models`. It should have been admitted as
restricted-v2:
```bash
oc -n inference-test get pod -l serving.kserve.io/inferenceservice=onnx-test \
  -o jsonpath='{.items[0].metadata.annotations.openshift\.io/scc}{"\n"}'   # restricted-v2
```

## 5. It runs on the GPU, not the CPU

Triton falls back to the CPU without a word if it cannot open the GPU, and the requests still
succeed. Its log says which:
```bash
oc -n inference-test logs deploy/onnx-test-predictor -c kserve-container \
  | grep -E 'ModelInstanceInitialize|CUDA|GPU'
```
`TRITONBACKEND_ModelInstanceInitialize: <model>_0 (GPU device 0)` is the pass.
`(CPU device 0)`, or a CUDA error, means the pod's UID could not open the Tegra device nodes:
```bash
oc -n inference-test exec deploy/onnx-test-predictor -c kserve-container -- \
  sh -c 'id; ls -ln /dev/nvmap /dev/nvhost-*'
getent group video          # on the node: the GID those nodes have there
```
- Nodes show the `video` GID, mode `0660`, and `id` lacks it: add it to the pod and re-apply
  (restricted-v2 allows any supplemental group):
  ```yaml
  spec:
    predictor:
      securityContext:
        supplementalGroups: [39]   # the GID getent printed
  ```
- Nodes show `0 0` (root:root) inside the container: a group cannot help. That is CRI-O's
  `device_ownership_from_security_context` question in the top-level README, not this manifest.
- A CUDA driver/runtime version error instead: the `25.02-py3-igpu` tag does not match JetPack
  6.2.2 (`services/manifests/040-triton-runtime/`).

Either way, write down what you saw: it settles an open item in `CLAUDE.md`.

## 6. Ask it something

KServe creates no Ingress here, so go through the Service (`onnx-test-predictor`, port 80 →
Triton's 8080):
```bash
oc -n inference-test port-forward svc/onnx-test-predictor 8080:80 &
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/v2/health/ready   # 200
curl -s -X POST localhost:8080/v2/repository/index; echo                   # names, READY
python3 examples/triton-onnx/infer.py http://localhost:8080 <model-name> 20
```
`infer.py` reads the inputs from `/v2/models/<model-name>`, sends zeros of that shape (a dynamic
dimension as 1) and prints the outputs' first values and the latency: the first request apart,
since it warms up, then the median of the rest. Zeros prove the path, not the predictions. Run
it with the kiosk screen on and off to see what the display costs (`tegrastats` beside it).

On the node itself, the same through cluster DNS, which also checks the split DNS:
```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  http://onnx-test-predictor.inference-test.svc.cluster.local/v2/health/ready
```

## 7. Remove it

```bash
kill %1                                    # the port-forward
oc delete namespace inference-test         # the InferenceService, pod, Service and secret
```
The model image stays in containers-storage until kubelet's image GC or `sudo crictl rmi <ref>`.
`/etc/containers/certs.d/<host>/` stays too; it is node state, kept across upgrades.

## When it does not come up

| Symptom | Where to look |
|---|---|
| `isvc` never READY, no pod | `oc -n inference-test describe isvc onnx-test` (runtime or protocol refused), `oc -n inference-test describe rs` (admission) |
| `ErrImagePull` / `ImagePullBackOff` on `modelcar-init` | `oc -n inference-test describe pod`: `no such host` → DNS; `x509` → step 2's CA; `unauthorized` → the secret or the robot's permission |
| `modelcar-init` exits `NOK` | `/models` missing or empty in the image (step 1) |
| `modelcar` crash-loops, `sh: not found` | image built `FROM scratch` (step 1) |
| Pod `Pending` | `oc describe pod`: `Insufficient nvidia.com/gpu` (all four slices taken) or memory (Triton asks 8Gi) |
| `kserve-container` keeps restarting | its log: `failed to load` names the model and why (opset, a missing `1/`) |
| Triton image pull error | it is embedded: `grep tritonserver /usr/lib/containers-image-cache/mapping.txt`, `journalctl -b -u copy-embedded-images` |
