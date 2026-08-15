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
credential in the environment: never print it, write it to a tracked file, or put a
literal value in a command.

## Proven generation invocation

Set `prompt_file` and `output_file` to the approved local input and output paths,
then use the bundled CLI through OpenRouter's OpenAI-compatible endpoint:

```bash
image_gen_cli="${CODEX_HOME:-$HOME/.codex}/skills/.system/imagegen/scripts/image_gen.py"

OPENAI_API_KEY="$OPENROUTER_API_KEY" \
OPENAI_BASE_URL=https://openrouter.ai/api/v1 \
uv run --with openai python "$image_gen_cli" generate \
    --model gpt-image-2 \
    --prompt-file "$prompt_file" \
    --quality low \
    --size 1024x1024 \
    --no-augment \
    --out "$output_file"
```

`gpt-image-2` generation is proven on this route. The visual-identity run used one
call per concept; its prompts and output hashes are in the tracked
[generation ledger](https://github.com/timharris707/grab-rabbit/blob/fa5a826/docs/design/visual-identity/prompts.md).

## Edit boundary

The OpenRouter image-edit endpoint returned `404 Not Found` for the attempted
`gpt-image-2` optical-size edit. Treat editing as unsupported on this route: stop and
report the limitation without retrying or silently switching model or provider.
