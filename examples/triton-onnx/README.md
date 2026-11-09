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

## 6. Ask it through the API

KServe creates no Ingress here, so go through the Service (`onnx-test-predictor`, port 80 →
Triton's 8080). From wherever `oc` runs:
```bash
oc -n inference-test port-forward svc/onnx-test-predictor 8080:80 &
API=http://localhost:8080
M=<model-name>             # the directory under /models, not onnx-test
```
On the node itself you can skip the port-forward and use cluster DNS, which also proves the
split DNS: `API=http://onnx-test-predictor.inference-test.svc.cluster.local`.

Each call below is Triton's v2 (KServe Open Inference Protocol) REST API; each proves one more
thing. Anything but HTTP 200 means stop there, and the body says why.
```bash
curl -s -w '%{http_code}\n' $API/v2/health/live        # 200: the server process is up
curl -s -w '%{http_code}\n' $API/v2/health/ready       # 200: every model loaded
curl -s $API/v2 | jq .                                 # name "triton", its version
curl -s -X POST $API/v2/repository/index | jq .        # [{name, version "1", state "READY"}]
curl -s -w '%{http_code}\n' $API/v2/models/$M/ready    # 200: this model loaded
curl -s $API/v2/models/$M | jq .                       # platform onnxruntime_onnx, inputs, outputs
curl -s $API/v2/models/$M/config | jq .instance_group  # kind KIND_GPU: on the GPU
```
`KIND_CPU` in the last one is the API's view of the CPU fallback in step 5.

**One inference by hand.** Take the input's `name`, `datatype` and `shape` from the metadata call
(a `-1` is the batch: send 1) and post zeros of that size. `jq` is on the node; for one input of
`[1,3,224,224]` FP32:
```bash
jq -cn --arg n input '{inputs: [{name: $n, datatype: "FP32", shape: [1,3,224,224],
                                 data: [range(1*3*224*224) | 0]}]}' > /tmp/req.json
curl -s -X POST -H 'Content-Type: application/json' -d @/tmp/req.json \
  $API/v2/models/$M/infer | jq '.outputs[] | {name, datatype, shape, first: .data[:5]}'
```
A wrong name or shape is a 400 whose `error` names the input and the shape Triton expected.
`infer.py` does the same for every input, from the metadata, and times it:
```bash
python3 examples/triton-onnx/infer.py $API $M 20
```
Zeros prove the path, not the predictions.

**What the requests cost on the device**, without HTTP and JSON in the number:
```bash
curl -s $API/v2/models/$M/stats | jq '.model_stats[0] |
  {inference_count, ms_per_infer: (.inference_stats.compute_infer.ns
                                   / .inference_stats.compute_infer.count / 1e6)}'
```
`inference_count` rising with each request is the proof they reached the model;
`ms_per_infer` is the model's own time. Compare it with the kiosk screen on and off, with
`tegrastats` beside it.

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
