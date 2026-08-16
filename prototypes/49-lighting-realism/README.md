# Lighting-realism Stage 1 preparation packet

This throwaway prototype packet makes the later text-only visual gate reproducible without
authorizing or performing it. It contains no provider client, credential handling, camera access,
upload path, model download, or generation command.

## Zero-call preparation

From the repository root:

```bash
prototypes/49-lighting-realism/prepare-stage1.sh /tmp/grab-rabbit-stage1
```

The command expands the eight fixed cells from `stage1-plan.json` into one directory per cell.
Each directory contains the exact prompt and an unfilled evidence manifest. The summary repeats
the call and cost ceiling. Preparation refuses a non-empty destination and never creates an image.

The later human reviewer will see four matched scene/profile pairs for each hosted finalist at
exactly 1376×768. Once an independently implemented, explicitly authorized runner fills the
outputs and manifests, the reviewer compares the paired artifacts using `comparison-rubric.json`.
Local exposure/color/contrast checks use the three deterministic scenarios in
`local-adaptation-scenarios.json`; those scenarios describe comparison inputs only and never alter
the person's genuine camera image.

## Hard gates

- Stage 1 is locked until Tim explicitly authorizes **8 image calls** with the exact image-output
  subtotal **$0.38772 before text charges** and the selected accounts satisfy their open
  retention, region, age/content, billing, and commercial gates.
- Each cell permits one output and zero automatic retries. A rejection, timeout, moderation block,
  or rate limit is recorded as the result.
- Stage 2 remains separately locked. No still may be selected, read, copied, or uploaded by this
  packet. Its later maximum is 4 calls only after Stage 1, separate approval of the exact 768×432
  JPEG (maximum 1 MB), provider/account proof, and a displayed hard spend ceiling.
- The on-device challenger remains separately locked; this packet does not download its roughly
  3.35 GB model.
- Live video, segmentation, adaptation, and composition remain local. Generation is pre-recording
  only, with no regeneration during a clip.

`prepare-stage1.sh` is intentionally not an execution wrapper. A later runner must be reviewed as
a separate artifact and must require an explicit approval token; do not add credentials or a
provider invocation here.
