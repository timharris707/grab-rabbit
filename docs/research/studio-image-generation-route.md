# Studio image-generation and privacy route

_Research date: 2026-08-16 · Driving ticket:
[#46 — STUDIO RESEARCH: Define the production image-generation and privacy route](https://github.com/timharris707/grab-rabbit/issues/46)_

## Verdict

**One-line verdict:** Advance direct OpenAI `gpt-image-2-2026-04-21` and Google
`gemini-3.1-flash-image` into an eight-call, text-only visual gate; retain OpenRouter OAuth only
as a user-funded text transport and Apple/Core ML SDXL as a separately approved offline
challenger; no optional camera still may leave the Mac until Tim separately approves it and the
chosen account proves the required retention and region controls, because OpenRouter's GPT Image
route is not ZDR, Google's current model is global-only, and even OpenAI ZDR has a CSAM-review
exception.

**Authorization boundary:** this research authorizes **zero model/API calls and zero still
uploads**. The eight text-only calls are a later [issue #49][issue-49] gate that requires Tim's
explicit go after cost and account controls are rechecked; its optional-still stage requires a
second, separate approval.

This is a route verdict, not a final provider selection. Documentation establishes capability,
policy, and cost boundaries; it cannot establish which model makes the lighting profile look real.
That belongs to the bounded visual comparison in [issue #49][issue-49].

The normal product path remains exactly Q13. The only user-derived content that may leave the Mac
is the user's scene direction and a locally derived textual lighting profile (direction, approximate
color temperature, brightness, contrast, softness, and background depth/blur intent). The request
also carries the fixed output envelope, provider safety settings, and a non-identifying request ID;
these are request-control fields, not camera-derived content. No camera pixel, crop, embedding, face
geometry, device name, room image, audio, live video, or prose description of identity/appearance is
sent. Generation finishes before recording; recording never triggers a cloud regeneration.

## Evidence boundaries

- **Sourced fact** is stated by a cited provider document, current live provider API, pinned
  upstream repository/model card, or license.
- **Inference** follows from those facts but is not a provider promise.
- **Recommendation** is the smallest route or test this evidence supports.
- **Unresolved product judgment** belongs to Tim, the repository's recorded decider.

Prices and live catalogs are point-in-time facts retrieved on 2026-08-16. Costs exclude taxes,
currency conversion, a future Grab Rabbit backend, support, and app-store economics. No credential
was inspected, no API/model call was made, no model was downloaded, and no camera still was read.

## Decision-ready route matrix

| Route | Text-only generation | Optional still | Credential and billing boundary | Privacy/region headline | Evidence verdict |
|---|---|---|---|---|---|
| Direct OpenAI `gpt-image-2-2026-04-21` | Yes; text in, image out. | **Excluded now.** The API supports image inputs, but the exact project controls and Tim's acceptance of the CSAM-review exception must be proven first. | OpenAI says API keys belong on a server, not in client apps. A managed Grab Rabbit service is the documented production shape; manually pasted user keys remain an unendorsed advanced boundary. [OpenAI model][openai-model] [OpenAI auth][openai-auth] | No training; default abuse logs up to 30 days; no Images application-state retention; Images is ZDR-eligible. Regional image processing requires an eligible project and enhanced retention approval. CSAM-flagged images can be retained for review even under ZDR. [OpenAI data controls][openai-data] | **Hosted finalist.** It has the strongest documented snapshot and optional-still control, but the still path is conditional, not approved. |
| Google `gemini-3.1-flash-image` | Yes; text and image are both input/output modalities. | **Excluded now.** The API supports image editing, but cache/logging opt-outs and Tim's acceptance of global processing and the age rule must be proven first. | API key or Google ADC/IAM. A managed service account is the normal production boundary; asking each user to create a billed Cloud project is possible but high-friction. [Google model][google-model] [Google auth][google-auth] | No training without permission. Default in-memory cache has a 24-hour TTL and can be disabled; suspicious prompts can be stored for up to 90 days unless exempt/approved for opt-out. This model is available only through `global`, so processing region cannot be controlled. [Google ZDR][google-zdr] [Google abuse][google-abuse] [Google locations][google-locations] | **Hosted finalist if Tim accepts global processing and Google's age rule.** Optional still also requires cache off and a proven abuse-logging exemption. |
| OpenRouter `openai/gpt-image-2` | Yes; it forwards to one current provider, OpenAI. | **Excluded.** OpenRouter has not established endpoint-specific ZDR for GPT Image 2. | OpenRouter's PKCE flow creates a user-controlled key without a Grab Rabbit secret. The user owns the account, credits, and upstream limits. [OpenRouter OAuth][or-oauth] [OpenRouter endpoint][or-endpoint] | OpenRouter content logging is off by default, but it keeps request metadata and anonymously categorizes a sample. Its provider ledger marks OpenAI as retaining prompts, and GPT Image 2 is absent from the current ZDR catalog. [OpenRouter data][or-data] [OpenRouter provider ledger][or-providers] [OpenRouter ZDR catalog][or-zdr-api] | **Accept only as a user-funded text-only boundary. Reject for optional camera still without a new endpoint-specific contract.** It adds no independent visual model to the matrix. |
| Apple `ml-stable-diffusion` + Core ML SDXL 1.0 | Yes, locally. | Technically local when the VAE encoder is included; separately gated on model-download approval, with no upload or provider retention. | No account or secret after the weights are present; Grab Rabbit must disclose and manage a multi-gigabyte first download. [Apple repository][apple-repo] | Pixels and text stay on-device. There is no provider retention, training, or region boundary; Grab Rabbit inherits moderation, update, security, and license duties. | **Conditional offline challenger, not a production selection.** The measured model is large, slow, square-native, older, and not proven on the target Tahoe Mac. |

No route silently inherits Tim's development credential. The proven OpenRouter CLI remains evidence
that one development call shape works, not authorization for a shipped key, shared billing, or
camera-pixel upload.

## Hosted finalist: direct OpenAI GPT Image 2

### Capability, version, cost, and limits

| Item | Primary-source finding | Consequence |
|---|---|---|
| Model contract | `gpt-image-2` accepts text and image inputs and produces images for generation and editing. OpenAI publishes the dated snapshot `gpt-image-2-2026-04-21`; the model page says snapshots lock a specific version so performance and behavior remain consistent. [OpenAI model][openai-model] | Pin the dated snapshot in any visual evidence and production brief. An alias-only result is not durable evidence. |
| Output envelope | The Images API accepts custom sizes, including the common Stage-1 envelope `1376×768` landscape, with medium quality. Image inputs are always processed at high fidelity for GPT Image 2. [OpenAI image guide][openai-images] | Both hosted finalists use exactly `1376×768`; scoring does not reward a provider for a different native canvas. Optional still input costs more than text-only and cannot be silently downshifted to low fidelity. |
| Price | OpenAI prices image output at `$30/M` image tokens; the dated pricing calculation for `1376×768` medium is 991 output tokens, or `$0.02973` per image. Text input is `$5/M` and image input `$8/M`. [OpenAI pricing][openai-pricing] [OpenAI image guide][openai-images] | Four Stage-1 outputs cost `4 × $0.02973 = $0.11892` before text input. Recalculate image-input cost before an optional-still run. |
| Rate/size limits | The current tier table is 5, 20, 50, 150, or 250 images per minute for tiers 1–5; free is unsupported. The API accepts popular landscape/portrait/square sizes and thousands of valid custom sizes subject to documented pixel bounds. [OpenAI model][openai-model] [OpenAI image guide][openai-images] | The eight-call prototype is below even Tier 1 if paced. Production still needs visible 429/quota handling and a spend cap. |
| Latency/availability | OpenAI says complex prompts may take up to two minutes. No public standard on-demand Images latency or uptime SLA was found in the cited product docs. [OpenAI image guide][openai-images] | Generation is a pre-recording task with progress/cancel/error UI, never a recording-time dependency. “Usually fast” is not an acceptance threshold. |

### Data and policy contract

- OpenAI states API data is not used to train or improve models unless the customer opts in.
  Default abuse-monitoring logs can contain prompts/responses and remain up to 30 days. Both
  `/v1/images/generations` and `/v1/images/edits` have no application-state retention and are ZDR
  eligible for approved customers. There is no per-request delete object because the Images
  response is stateless; the control is default expiry or project-level ZDR. [OpenAI data
  controls][openai-data]
- Image/file inputs are scanned for CSAM. A potentially matching image is retained for manual
  review even when ZDR, Modified Abuse Monitoring, or Eyes Off is enabled. **Inference:** OpenAI
  cannot promise literal exception-free “never retained.” Tim must decide whether Q4 permits this
  narrow safety/legal exception; if not, the cloud-still path is disallowed. [OpenAI data
  controls][openai-data]
- Data residency is a project control requiring eligibility. Images supports the current regional
  service table, but image support outside the ordinary route requires approval for enhanced ZDR
  or enhanced Modified Abuse Monitoring; eligible post-2026-03-05 models carry a 10% regional
  processing uplift. System/usage metadata is outside customer-content residency. [OpenAI data
  controls][openai-data] [OpenAI pricing][openai-pricing]
- All prompts and generated images are filtered. The API exposes stable `moderation_blocked`
  handling and optional coarse stage/category details; a blocked input/output is a visible terminal
  result, not permission to rewrite the user's scene or retry automatically. [OpenAI image
  guide][openai-images]
- OpenAI's under-18 guidance requires additional child-safety controls and says personal data of a
  child under 13 (or local digital-consent age) must not be processed without ZDR. [OpenAI minors
  guidance][openai-minors]
- OpenAI's Services Agreement `ONLINE v.010126` assigns Output rights to the customer as between
  the parties, while noting that output may not be unique and leaving the customer responsible for
  inputs and use. **Inference:** this supports commercial background use; it is not a title,
  uniqueness, or non-infringement guarantee. [OpenAI Services Agreement][openai-services]

## Hosted finalist: Google Gemini 3.1 Flash Image

Imagen 4 is not the current candidate. Google's primary model page says
`imagen-4.0-generate-001`, Fast, and Ultra were discontinued on 2026-06-30 and directs migrations
away from those endpoints. [Google Imagen 4 lifecycle][google-imagen4]

### Capability, version, cost, and limits

| Item | Primary-source finding | Consequence |
|---|---|---|
| Model contract | `gemini-3.1-flash-image` is GA, accepts text and images, generates and edits images, and supports C2PA. Google's lifecycle table dates its release to 2026-05-28 and retirement to 2027-05-28 or later. [Google model][google-model] [Google lifecycle][google-lifecycle] | It is the current Google comparator. It is a lifecycle ID, not a dated immutable snapshot like OpenAI's; preserve prompts/outputs and re-run evidence after material updates. |
| Output envelope | It supports 1:1 through 21:9, including the common `1376×768` landscape envelope, at 512, 1K, and 2K; 4K and video input remain preview. It accepts up to 14 input images, 7 MB inline per image or 30 MB from Cloud Storage. [Google model][google-model] | Request the common `1376×768` landscape envelope for Stage 1. Do not let a prototype accidentally depend on preview 4K or video input. |
| Price | Standard PayGo is `$0.50/M` input tokens, `$3/M` text output tokens, and `$60/M` image output tokens. A 1K image consumes 1,120 output tokens (`$0.0672`); each input image consumes 1,120 input tokens. [Google pricing][google-pricing] [Google model][google-model] | Four Stage-1 outputs cost `4 × (1,120 × $60/M) = $0.26880` before text input. |
| Capacity | Standard and Flex PayGo plus Provisioned Throughput are supported; fixed quota is not. The image-input quota is enforced per project/model/resolution, and capacity can return 429. [Google model][google-model] [Google quotas][google-quotas] | PayGo needs bounded backoff and a visible capacity failure. Provisioned Throughput is a later operating-cost decision, not needed for the prototype. |
| Latency/SLA | Google describes generation as taking a few seconds but possibly slower with capacity. The current Vertex SLA's covered-service table does not name hosted Gemini model inference and supplies no image-latency promise. [Google image guide][google-images] [Google SLA][google-sla] | Record wall time in the prototype; do not convert documentation prose into a latency commitment. |

### Data and policy contract

- Google will not use customer data to train or fine-tune an AI/ML model without prior permission
  or instruction. Request/response logging is disabled by default. Its service terms say prompts
  are not stored outside the customer's account longer than reasonably necessary to create output,
  and generated output is not stored outside the account, absent permission/instruction. [Google
  ZDR][google-zdr] [Google service terms][google-terms]
- Google's published Gemini models use a project-isolated, in-memory input/output/derived-data cache
  with a 24-hour TTL by default. Google calls this compatible with its ZDR definition; it can be
  disabled project-wide. **Q4/Q13 consequence:** disable it before any camera-still evaluation,
  even though it is not at-rest storage. [Google ZDR][google-zdr]
- Each Google `generateContent` call in the later gate is a standalone request: send one complete
  `contents` payload and do not use a conversation, session, or `cachedContent` handle. The
  application must not imply that a prior request, provider session, or cached context is reused;
  the separate 24-hour provider cache policy above remains an account-control gate, not application
  state. [Google generateContent][google-generate-content] [Google ZDR][google-zdr]
- Under ordinary Google Cloud Platform Terms, automated classifiers can cause suspicious prompts
  to be logged for up to 90 days in the selected region and reviewed by authorized staff. Master
  Agreement customers are exempt by default; other customers can request an exception, after
  which Google says it will not store prompts for the approved account. [Google abuse
  monitoring][google-abuse]
- The model page lists only `global`. Google's location rules say global processing may occur
  anywhere and does not provide regional isolation or data-residency guarantees for inference.
  **Consequence:** Google cannot satisfy a US-only or EU-only processing decision with this model,
  regardless of where unrelated at-rest resources live. [Google model][google-model] [Google data
  residency][google-residency]
- Image requests and responses pass multilayer filters for sexual, dangerous, violent, hateful,
  toxic, child, celebrity, PII, and other prohibited content. Inputs may be refused and outputs may
  finish with image-safety/prohibited-content codes. [Google image safety][google-safety]
- Google's service terms prohibit use of a Generative AI Service in a website, application, or
  online service directed toward or likely to be accessed by anyone under 18. **Unresolved product
  judgment:** selecting this route means a truthful Studio-AI age boundary; it cannot be hidden in
  legal copy. [Google service terms][google-terms]
- Generated Output is Customer Data, and Google does not assert ownership in new IP in it. The
  terms warn that outputs may be inaccurate, offensive, or similar across customers and condition
  any output indemnity. **Inference:** these clauses do not prohibit commercial background use,
  but uniqueness, trademark clearance, and safe use remain Grab Rabbit's responsibility. [Google
  service terms][google-terms]

## Existing intermediary: OpenRouter

OpenRouter's live endpoint record reports one provider—OpenAI—for `openai/gpt-image-2`, with
text+image-to-image modality. Therefore an OpenRouter image is not a third visual model; it is a
different account, transport, and policy chain. [OpenRouter endpoint][or-endpoint]

| Area | Sourced fact | Product consequence |
|---|---|---|
| User authentication | PKCE S256 can send the user through OpenRouter authorization and exchange the one-time code for a user-controlled API key. Localhost callbacks are supported; headless codes expire after 10 minutes. [OpenRouter OAuth][or-oauth] | This is the only researched hosted route explicitly designed to provision a third-party app's user-owned key without shipping Grab Rabbit's provider secret. Store the resulting key in Keychain if Tim selects it. |
| OpenRouter-layer retention | Prompt/response storage and use are off by default. OpenRouter stores request metadata such as model, token counts, and latency; it anonymously categorizes a small sample using a ZDR model. Its privacy policy says routed image/audio/video files are not persisted beyond routing except for abuse, security, billing, or legal needs. [OpenRouter data][or-data] [OpenRouter privacy][or-privacy] | Disclose the metadata and categorization. The public docs give no per-request metadata deletion or fixed metadata-retention duration; account deletion is subject to regulatory/business exceptions. |
| Provider-layer retention | OpenRouter says ZDR enforcement is conservative and endpoint-specific. Its live OpenAI ledger has `retainsPrompts: true`; the current ZDR endpoint catalog has no GPT Image 2 entry. [OpenRouter provider logging][or-logging] [OpenRouter provider ledger][or-providers] [OpenRouter ZDR][or-zdr] [OpenRouter ZDR catalog][or-zdr-api] | A text-only request can be offered with disclosure. A camera still cannot be sent merely because OpenAI offers ZDR directly; OpenRouter has not established that contract for this endpoint. |
| Region | Enterprise customers can request EU or US in-region routing, but model availability must be queried through the authenticated regional `/models/user` endpoint. [OpenRouter provider logging][or-logging] | Regional GPT Image 2 availability is vendor/account-held and unproven. Do not claim US/EU processing for this route before written confirmation. |
| Version | The endpoint record exposes only `openai/gpt-image-2`; OpenRouter publishes no dated snapshot endpoint for it. [OpenRouter endpoint][or-endpoint] | Visual results through this route are alias-bound. It loses OpenAI direct's exact snapshot advantage. |
| Price/billing | Inference pricing is passed through without markup. Stripe credit purchases add 5.5% with an `$0.80` minimum; the minimum credit purchase is `$5`. Unused credits may expire after 365 days. [OpenRouter FAQ][or-faq] [OpenRouter terms][or-terms] | At the common envelope, four pass-through outputs are `4 × $0.02973 = $0.11892`; a new user initially pays at least `$5.80`. This is material onboarding, not a per-image price increase. |
| Limits/availability | Paid traffic is subject to upstream capacity and DDoS protection; 429 can originate from OpenRouter or the provider. OpenRouter does not guarantee any model's availability and may change or discontinue the service. [OpenRouter limits][or-limits] [OpenRouter terms][or-terms] | This model currently has no second provider fallback. Generation failure remains visible and pre-recording. |
| Output/content terms | OpenRouter makes upstream Model Terms controlling for output ownership and permissible use and offers no independent quality, availability, retention, or IP warranty. Its account terms require age 13+, with parent/guardian permission under 18. [OpenRouter terms][or-terms] | OpenAI content/ownership/minor rules still flow through. OpenRouter does not simplify policy custody; it simplifies user billing/authentication. |

## Bounded on-device feasibility

The local baseline is Apple's `ml-stable-diffusion` at commit
[`e12202c1f6405b83918b58a5d097cd61e3e1f702`][apple-repo], using Apple's preconverted Core ML SDXL
1.0 assets. This is the best-documented Apple-native baseline found, not a claim that SDXL 1.0 is
the best current image model.

| Area | Primary-source finding | Consequence |
|---|---|---|
| Native integration | Apple supplies a Swift package and CLI. The pipeline supports text-to-image; adding `VAEEncoder.mlmodelc` enables image-to-image/in-painting paths. [Apple README][apple-readme] | No Python runtime or cloud service is required in the shipped path. Optional still can remain entirely local. |
| Weight size | In the pinned 4.50-bit SDXL asset tree, the text encoders, UNet, VAE decoder, and optional VAE encoder weight files total `3,351,878,016` bytes (~3.12 GiB). Omitting the optional encoder saves only `68,338,112` bytes. The corresponding uncompressed component weights total `7,036,895,360` bytes (~6.55 GiB). [Apple mixed-bit assets][apple-mbp] [Apple uncompressed assets][apple-sdxl] | Treat ~3.35 GB plus packaging/compilation overhead as the honest image-conditioned download. Apple itself recommends a disclosed first-launch download rather than inflating the app binary. |
| Latency evidence | Apple's July 2023, 20-step, 1024² **float16** Swift benchmark reports 46 s on M1 Max, 37 s on M2 Max, 25 s on M1 Ultra, and 20 s on M2 Ultra. It used beta-era macOS 14; first model preparation can take minutes, while compiled subsequent loads fall to seconds. [Apple README][apple-readme] | Tahoe/Mac Mini speed, memory, thermals, and coexistence with capture/encode are unknown. Four images took 80–184 seconds on those specific old setups; that is neither a bound nor a current promise for the 4.50-bit build. |
| Shape/quality | The preconverted measured SDXL asset is 1024². Apple supports alternate static latent dimensions through conversion, but the pinned ready asset is not a production 16:9 package. SDXL's card says it lacks perfect photorealism, struggles with composition, faces, and text, and has a lossy autoencoder. [Apple README][apple-readme] [SDXL model card][sdxl-card] | A fair 16:9 comparison needs an explicitly built/pinned landscape asset or a declared crop; either adds work or harms composition. Hosted evidence should run first. |
| Updates/offline failure | Once assets are installed, inference has no network/account dependency. Missing/corrupt/incompatible assets are local preflight failures. [Apple README][apple-readme] | Never fall through to cloud or an old background silently. Offer download/retry, or let the user explicitly record without the generated background before Start. |
| Code license | Apple's repository is MIT and requires preservation of the copyright/permission notice. [Apple code license][apple-license] | The Swift code is redistributable with notice. This says nothing about the weights. |
| Weight/output license | SDXL weights use CreativeML Open RAIL++-M. Redistribution requires the license, notices, modified-file markings, and enforceable flow-down of its use restrictions. The licensor claims no output rights but makes the user accountable and supplies no warranty. [SDXL license][sdxl-license] | Commercial distribution is possible only with license/notice and product-policy work. Grab Rabbit must enforce the restricted-use posture; the optional Apple safety checker is not a complete moderation contract. |

**Recommendation:** keep on-device outside the first eight calls. Add its four-cell replay only if
Tim first accepts the ~3.35 GB download, old-model quality risk, and expected pre-generation wait,
and the prototype prepares a pinned 16:9 asset. No model download was made in this lane.

## Retired and rejected hosted candidates

| Candidate | Current primary-source status | Verdict |
|---|---|---|
| Google Imagen 4 / Fast / Ultra | All three `imagen-4.0-*-001` endpoints show a 2026-06-30 discontinuation date. [Google Imagen 4][google-imagen4] | **Rejected.** They were already retired 47 days before this research date. Historical price/privacy advantages cannot make a dead endpoint production-capable. |
| Amazon Nova Canvas `amazon.nova-canvas-v1:0` | AWS lists it Legacy since 2026-03-30 with EOL on 2026-09-30; new customers cannot use Legacy models, no new Provisioned Throughput can be created, and calls fail after EOL absent a private arrangement. [AWS lifecycle][aws-lifecycle] | **Rejected.** A six-week remaining runway cannot anchor a new production contract. |
| Amazon Titan Image Generator G1 v2 `amazon.titan-image-generator-v2:0` | AWS's dedicated model card lists the model as Legacy with a 2026-06-30 EOL. AWS says requests fail on or soon after EOL unless a private arrangement exists; generic parameter or pricing pages that remain online are not an availability contract. [AWS Titan model card][aws-titan-card] [AWS lifecycle][aws-lifecycle] | **Rejected.** It was already past EOL on the research date. This lane makes no claim that no third-party Bedrock image model exists. |

This is a bounded candidate comparison, not an assertion that every image model or cloud reseller
was evaluated.

## Exact Q4/Q13 privacy boundary

### Normal payload boundary — eligible for a later authorized visual prototype

This defines what a later request may contain; it does not authorize a call in this research lane.

The outbound payload may contain only:

1. the user's scene direction;
2. a local textual lighting description (direction, approximate color temperature, brightness,
   contrast, softness, and background depth/blur intent);
3. the fixed `1376×768` output shape, medium quality, and provider safety settings; and
4. a non-identifying request ID needed for failure support.

It may not contain a frame, crop, thumbnail, face/body measurement, pixel-derived embedding,
device name, room image, audio, live video, or a prose description of identity/appearance. The
returned background is stored locally and locally harmonized during recording.

### Optional still — not authorized by this research

Every condition below is conjunctive:

1. The text-only matrix is complete and one model/route remains a finalist.
2. Tim explicitly approves the experiment and the exact reduced-resolution still after seeing the
   send preview.
3. The product displays provider, purpose, retention exception, processing region, and deletion
   behavior before Send; consent is one-shot, not remembered globally.
4. For OpenAI direct: the exact project is approved and configured for ZDR/enhanced image controls.
   Tim has accepted the CSAM-review exception.
5. For Google: request/response logging and in-memory cache are off, abuse prompt logging is exempt
   or opted out in writing, and Tim has accepted global processing plus the under-18 exclusion.
6. OpenRouter is ineligible unless its live endpoint ledger and written terms newly establish ZDR
   for GPT Image 2. An account toggle alone is not evidence.
7. The request produces a background only; it does not reconstruct the person. No retry, provider
   substitution, or second still occurs without another visible authorization.

If approved, the still must travel as direct inline request bytes in the one-shot provider request:
OpenAI multipart image-edit bytes or Google's `inlineData` part in `generateContent`. Do not use
OpenAI Files, Google Cloud Storage or `fileData`, any provider object/file store, or backend object
storage. The bytes must never be persisted in queues, logs, traces, crash reports, or support
payloads. Strip EXIF and other metadata before sending. Any reduced local still copy is ephemeral
and must be deleted immediately after the one-shot response or abort; no provider retry or second
upload is implicit. These transport and deletion rules supplement the provider account, cache,
logging, abuse-monitoring, and region gates above. [OpenAI image guide][openai-images] [Google
generateContent][google-generate-content]

**Inference:** if Tim requires literal zero retention with no safety/legal exception, the only
researched image-conditioned route is on-device; otherwise the optional cloud-still feature does
not ship.

## Smallest bounded visual-evaluation matrix

### Stage 1 — text only

**Not authorized now:** this is an exact later-run plan, not permission to execute it.

Use two scene directions crossed with two materially different textual lighting profiles. The four
cells go once to each hosted finalist:

| Dimension | A | B |
|---|---|---|
| Scene | Uncluttered warm home office with a clear central subject zone and no people, text, marks, or logos. | Neutral modern studio/library with the same central subject zone and exclusions. |
| Lighting profile | Soft warm key from camera-left (~3200 K), low contrast, gentle fill, rear wall about one stop darker. | Cooler hard key from camera-right (~5600 K), higher contrast, weak fill, plausible directional shadows and depth falloff. |

- **Models:** `gpt-image-2-2026-04-21` and `gemini-3.1-flash-image`, both requested at the common
  `1376×768` landscape envelope, medium-equivalent quality, with image-only response. OpenAI's
  custom-size support and Google's supported landscape ratios make this envelope comparable;
  preserve actual returned dimensions and treat any provider rejection as a failed cell.
- **Paid multiplication:** 2 scenes × 2 lighting profiles × 2 models × 1 output = **8 image
  calls**. No automatic retry or “best of N.” A block, timeout, or 429 is evidence.
- **Exact image-output subtotal before text input:** OpenAI `4 × $0.02973 = $0.11892`; Google
  `4 × (1,120 × $60/M) = 4 × $0.0672 = $0.26880`; combined **`$0.38772`**. Add only the
  measured text-token charges afterward; do not round either provider subtotal in repeated totals.
  OpenRouter adds no call because it is the same visual model; a new OpenRouter user would still face the
  separate `$5.80` minimum cash/fee outlay.
- **Artifacts:** exact prompt, provider/route/model ID, account retention/region settings (never
  secrets), output bytes/hash/dimensions, wall time, request ID, safety/failure result, and billed
  usage/cost.
- **Review:** compare lighting direction/color/contrast, believable room depth, subject-zone
  usability, photorealism, compositional defects, and policy failures. Because both outputs use the
  same `1376×768` envelope, these size-sensitive criteria are comparable; a provider that cannot
  return that envelope is a failed cell, not a score advantage. Documentation sets no pass threshold;
  Tim chooses after seeing the eight outputs.

### Stage 2 — optional still only after Stage 1 and authorization

Select the two hardest cells and the one chosen model. The optional still is exactly one user-approved
`768×432` JPEG (16:9, no audio or video, maximum 1 MB), sent once for each selected cell. For each,
generate one fresh text-only control and one image-conditioned result: **4 calls total**, of which
exactly 2 carry that same approved still. No other model or route participates. This stage remains
locked behind Tim's separate approval; this lane performs no still upload and no paid call.

- If OpenAI is chosen, the image-output floor is **`$0.11892`** (`4 × $0.02973`). OpenAI
  publishes the `$8/M` image-input rate but does not publish a GPT Image 2 input-token formula for
  the exact `768×432` still, so this is a bounded formula rather than a numeric pre-call total:
  `Stage2 = $0.11892 + (2 × input_image_tokens × $8/M) + text charges`. Before Tim can authorize
  it, the later runner must calculate the current input-token charge and display a hard spend ceiling;
  if that preflight calculation is unavailable, the stage cannot run.
- If Google is chosen, the deterministic pre-text total is **`$0.26992`**: four outputs
  (`4 × 1,120 × $60/M = $0.26880`) plus two input images (`2 × 1,120 × $0.50/M = $0.00112`).
- If on-device is chosen, there are zero paid/API calls, but the authorized ~3.35 GB asset and
  measured local time replace the cloud cost.

The result must show a material, repeatable realism advantage to justify offering the optional
still. A merely different or prettier image is not enough.

## Credential, failure, and billing consequences

| Boundary | Shipped secret/account | Offline/error behavior | Operating burden |
|---|---|---|---|
| User-funded OpenRouter OAuth | User authorizes/funds OpenRouter; user-controlled key in Keychain; no Grab Rabbit provider key. | Text generation fails visibly when offline, out of credits, rate-limited, moderated, or unavailable. Existing locally saved backgrounds remain usable only by explicit user selection. | Lowest backend burden; highest onboarding/payment friction; alias and two-party policy chain. |
| Managed Grab Rabbit service | App authenticates to Grab Rabbit; provider key/service account stays server-side. Never embed it in the binary. | Same visible preflight failure. Backend must not persist prompts/stills in logs, traces, queues, crash reports, or support payloads. | Accounts/device identity, abuse controls, spend/rate caps, billing/refunds, availability, security, privacy requests, vendor migrations, and support. |
| On-device | No account/key after an explicit model download. | Works offline after install; missing/corrupt/incompatible weights stop generation visibly. | Download CDN/update provenance, disk cleanup, code/weight notices, policy enforcement, performance and hardware support. |

No route starts recording with a silently substituted provider/model, a stale background, or no
background. The user may explicitly choose a previously saved background or “record without
background” before Start, consistent with Q15.

## Decisions remaining for Tim

| Tim's choice | Options to adjudicate | Downstream consequence |
|---|---|---|
| Credential/service owner | User-funded OpenRouter OAuth, managed Grab Rabbit service, or a separately approved local-model download. | Fixes whether users face third-party signup/credits, Grab Rabbit must operate an account-and-billing backend, or the app must own a multi-gigabyte model-download lifecycle. |
| Hosted model | OpenAI versus Google after the eight outputs; OpenRouter is a transport, not a third model. | Selects the generator contract and eliminates the losing hosted model from implementation; it does not by itself select user-funded versus managed billing. |
| Text privacy | Accept default hosted abuse retention for scene/lighting text, or require ZDR/abuse opt-out even when no camera pixels leave the Mac. | A strict opt-out requirement blocks prototype and production calls until the exact account is approved and configured; accepting defaults requires a truthful retention disclosure. |
| Processing region | Accept global processing, or require US/EU isolation. | Requiring isolation eliminates the current Google model, leaves OpenRouter unproven, and makes direct OpenAI conditional on contracted regional controls. |
| Optional still | Omit it, authorize the separate four-call Stage 2 test, or require on-device conditioning; separately accept or reject narrow safety/legal retention exceptions. | Omitting it keeps Q13 text-only; a cloud test cannot start until every provider/account gate passes; rejecting all retention exceptions leaves on-device as the only researched still route. |
| Billing | User-purchased credits, a Grab Rabbit subscription/allowance with a hard spend cap, or disclosed local storage/time cost. | Determines onboarding, refunds/support, abuse and spend controls, and whether generation can work offline after setup. |
| Local envelope | Accept or reject ~3.35 GB, old SDXL quality risk, a static landscape build, and measured generation wait as an optional route. | Rejection removes Core ML from the prototype; acceptance authorizes only a separately pinned download/build and measured local replay, not silent installation. |
| Age/content posture | Adults-only Studio AI, minors with OpenAI's additional safeguards/ZDR, or local-only; also choose visible moderation/reporting UX. | Google requires an honest under-18 exclusion; an inclusive hosted route adds child-safety and ZDR work; local-only transfers moderation and reporting responsibility to Grab Rabbit. |
| Version/migration posture | OpenAI snapshot pin versus Google's lifecycle ID, evidence-refresh cadence, and treatment of saved prompts/backgrounds after retirement. | Determines reproducibility, requalification timing, migration UI, and whether a retired model disables only new generation or also changes saved-background behavior. |

Vendor/account-held proof is deliberately not guessed. After Tim narrows the route, the selected
vendor must confirm the exact account's ZDR/abuse exemption, image endpoint eligibility, regional
processing, and commercial agreement in writing before an optional-still or production ticket can
claim those controls.

## Acceptance-criteria coverage

| Issue criterion | Coverage |
|---|---|
| Text path and separately optional image conditioning | Route matrix and exact Q4/Q13 boundary. |
| Retention, training, deletion, region | Provider data sections and still gates; unknowns remain explicit. |
| Authentication, version, content policy, limits, cost, latency/SLA, commercial terms | Detailed OpenAI/Google/OpenRouter/on-device tables. |
| User-key, managed, and local service boundaries | Credential/failure/billing table. |
| Existing OpenRouter route remains a candidate | Accepted only as text transport; no reuse of Tim's development key and no duplicate visual call. |
| Smallest visual matrix and rough paid cost | Eight-call Stage 1 image-output subtotal (`$0.38772` before text) plus a separately approved four-call Stage 2 budget: Google has an exact `$0.26992` pre-text total, while OpenAI requires the bounded formula and a preflight spend ceiling above. |
| Remaining Tim decisions | Nine-item decision ledger above. |

## Primary-source ledger

All capability, live-catalog, policy, lifecycle, and pricing facts were checked on 2026-08-16.

### OpenAI

- [GPT Image 2 model/snapshot/rate limits][openai-model]
- [Image generation/editing, dimensions, pricing examples, latency, moderation][openai-images]
- [API pricing][openai-pricing]
- [Data controls, endpoint retention/ZDR, CSAM exception, regional controls][openai-data]
- [API authentication][openai-auth]
- [Under-18 API guidance][openai-minors]
- [Services Agreement][openai-services]

### Google Cloud

- [Gemini 3.1 Flash Image model card][google-model] and [model lifecycle][google-lifecycle]
- [Generate images with Gemini][google-images], [pricing][google-pricing], and [quotas][google-quotas]
- [GenerateContent inference reference][google-generate-content]
- [Zero-data-retention controls][google-zdr], [abuse monitoring][google-abuse],
  [locations][google-locations], and [data residency][google-residency]
- [Authentication][google-auth], [image safety][google-safety], [service terms][google-terms], and
  [Vertex SLA][google-sla]
- [Imagen 4 retirement page][google-imagen4]

### OpenRouter

- [GPT Image 2 model page][or-model] and [live endpoint record][or-endpoint]
- [Data collection][or-data], [provider logging][or-logging], [live provider ledger][or-providers],
  [ZDR rules][or-zdr], and [live ZDR catalog][or-zdr-api]
- [OAuth PKCE][or-oauth], [rate/credit limits][or-limits], [FAQ/fees][or-faq],
  [terms][or-terms], and [privacy policy][or-privacy]

### On-device and rejected candidates

- Pinned Apple [repository][apple-repo], [README][apple-readme], and [MIT license][apple-license]
- Pinned 4.50-bit [Core ML asset tree][apple-mbp] and uncompressed [Core ML asset tree][apple-sdxl]
- Pinned SDXL [model card][sdxl-card] and [Open RAIL++-M license][sdxl-license]
- AWS [model lifecycle][aws-lifecycle] and [Titan Image Generator G1 v2 model card][aws-titan-card]

### Audit limits

- No visual quality, latency, region, or account-level retention result was inferred from a model
  card. The planned prototype or written vendor proof owns those facts.
- OpenRouter's provider/ZDR findings are dated live-catalog observations and must be refreshed at
  the moment of any still authorization.
- The on-device byte totals sum only the named component weight files; package programs,
  tokenizers, archives, caches, and CDN overhead are additional.
- No claim is made that the candidate scan is exhaustive or that cited output-right clauses replace
  product counsel's review of the selected commercial agreement.

[issue-49]: https://github.com/timharris707/grab-rabbit/issues/49
[openai-model]: https://developers.openai.com/api/docs/models/gpt-image-2
[openai-images]: https://developers.openai.com/api/docs/guides/image-generation
[openai-pricing]: https://developers.openai.com/api/docs/pricing#image-generation-models
[openai-data]: https://developers.openai.com/api/docs/guides/your-data
[openai-auth]: https://developers.openai.com/api/docs/api-reference/authentication
[openai-minors]: https://developers.openai.com/api/docs/guides/safety-checks/under-18-api-guidance
[openai-services]: https://cdn.openai.com/osa/openai-services-agreement.pdf
[google-model]: https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/gemini/3-1-flash-image
[google-lifecycle]: https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/model-versions
[google-images]: https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/capabilities/image-generation
[google-generate-content]: https://cloud.google.com/vertex-ai/generative-ai/docs/model-reference/inference
[google-pricing]: https://cloud.google.com/gemini-enterprise-agent-platform/generative-ai/pricing
[google-quotas]: https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/quotas
[google-zdr]: https://docs.cloud.google.com/gemini-enterprise-agent-platform/resources/zero-data-retention
[google-abuse]: https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/abuse-monitoring
[google-locations]: https://docs.cloud.google.com/gemini-enterprise-agent-platform/resources/locations
[google-residency]: https://docs.cloud.google.com/gemini-enterprise-agent-platform/resources/data-residency
[google-auth]: https://docs.cloud.google.com/gemini-enterprise-agent-platform/machine-learning/authentication
[google-safety]: https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/capabilities/gemini-image-responsible-ai
[google-terms]: https://cloud.google.com/terms/service-terms
[google-sla]: https://cloud.google.com/vertex-ai/sla
[google-imagen4]: https://docs.cloud.google.com/vertex-ai/generative-ai/docs/models/imagen/4-0-generate
[or-model]: https://openrouter.ai/openai/gpt-image-2
[or-endpoint]: https://openrouter.ai/api/v1/models/openai/gpt-image-2/endpoints
[or-data]: https://openrouter.ai/docs/guides/privacy/data-collection
[or-logging]: https://openrouter.ai/docs/guides/privacy/provider-logging
[or-providers]: https://openrouter.ai/api/frontend/v1/all-providers
[or-zdr]: https://openrouter.ai/docs/guides/features/zdr
[or-zdr-api]: https://openrouter.ai/api/v1/endpoints/zdr
[or-oauth]: https://openrouter.ai/docs/guides/overview/auth/oauth
[or-limits]: https://openrouter.ai/docs/api_reference/limits
[or-faq]: https://openrouter.ai/docs/faq
[or-terms]: https://openrouter.ai/terms
[or-privacy]: https://openrouter.ai/privacy
[apple-repo]: https://github.com/apple/ml-stable-diffusion/tree/e12202c1f6405b83918b58a5d097cd61e3e1f702
[apple-readme]: https://github.com/apple/ml-stable-diffusion/blob/e12202c1f6405b83918b58a5d097cd61e3e1f702/README.md
[apple-license]: https://github.com/apple/ml-stable-diffusion/blob/e12202c1f6405b83918b58a5d097cd61e3e1f702/LICENSE.md
[apple-mbp]: https://huggingface.co/apple/coreml-stable-diffusion-mixed-bit-palettization/tree/959bf38cbad66f1105a84190cd12434ba815e724
[apple-sdxl]: https://huggingface.co/apple/coreml-stable-diffusion-xl-base/tree/2027f2c8d5ced83ce5726ff66e00da53a9ef163d
[sdxl-card]: https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/blob/462165984030d82259a11f4367a4eed129e94a7b/README.md
[sdxl-license]: https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/blob/462165984030d82259a11f4367a4eed129e94a7b/LICENSE.md
[aws-lifecycle]: https://docs.aws.amazon.com/bedrock/latest/userguide/model-lifecycle.html
[aws-titan-card]: https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-amazon-titan-image-generator-g1-v2.html
