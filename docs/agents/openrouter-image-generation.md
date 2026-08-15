# Proven OpenRouter image-generation route

The bundled image-generation CLI route below generated the visual-identity concepts
successfully on 2026-08-14.

## Credential availability

`OPENROUTER_API_KEY` is supplied by the environment. Check whether it is available
without printing its value:

```bash
if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
    printf '%s\n' 'OPENROUTER_API_KEY is available'
else
    printf '%s\n' 'OPENROUTER_API_KEY is missing'
fi
```

Run this check before asking Tim to create, paste, or reconfigure a key. Keep the
credential in process memory: receive it through the environment and use the
unexported runtime copy below. Never print it, write it to a tracked file, or put a
literal value in a command.

## Pinned two-stage generation invocation

Set `prompt_file` and `output_file` to the approved local input and output paths,
then prepare the exact SDK version with all provider credentials removed:

```bash
image_gen_cli="${CODEX_HOME:-$HOME/.codex}/skills/.system/imagegen/scripts/image_gen.py"

env -u OPENROUTER_API_KEY \
    -u OPENAI_API_KEY \
    -u OPENAI_BASE_URL \
    uv run --with 'openai==3.1.0' --no-env-file --no-project python -c \
    'import openai; assert openai.__version__ == "3.1.0"'
```

Preparation is complete only when that import exits `0`. It is the only stage that
may resolve or download a package, and it runs without provider credentials. Then
run the bundled CLI offline, with the key held in a non-exported subshell variable:

```bash
(
    openrouter_key=${OPENROUTER_API_KEY:?OPENROUTER_API_KEY is missing}
    export -n openrouter_key

    env -u OPENROUTER_API_KEY \
        OPENAI_API_KEY="$openrouter_key" \
        OPENAI_BASE_URL=https://openrouter.ai/api/v1 \
        uv run --offline --with 'openai==3.1.0' --no-env-file --no-project \
        python "$image_gen_cli" generate \
        --model gpt-image-2 \
        --prompt-file "$prompt_file" \
        --quality low \
        --size 1024x1024 \
        --no-augment \
        --out "$output_file"
)
```

If the offline run reports that the pinned package is unavailable, stop and repeat
the credential-free preparation stage; keep the runtime stage offline.

`gpt-image-2` generation is proven on this route. The visual-identity run used one
call per concept; its prompts and output hashes are in the tracked
[generation ledger](https://github.com/timharris707/grab-rabbit/blob/fa5a826/docs/design/visual-identity/prompts.md).

## Edit boundary

The OpenRouter image-edit endpoint returned `404 Not Found` for the attempted
`gpt-image-2` optical-size edit. Treat editing as unsupported on this route: stop and
report the limitation without retrying or silently switching model or provider.
