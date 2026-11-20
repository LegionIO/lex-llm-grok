# lex-llm-grok

xAI Grok provider for `Legion::Extensions::Llm`. The provider uses the current
[xAI Responses API](https://docs.x.ai/developers/rest-api-reference/inference/responses)
for text, reasoning, streaming, image understanding, and function calls. It
publishes the model catalog into lex-llm's single Inventory Registry and can
execute exact fleet selections through the shared ProviderResponder.

## Install

```ruby
gem 'lex-llm-grok'
```

Load with:

```ruby
require 'legion/extensions/llm/grok'
```

An xAI API key is required. `XAI_API_KEY` is used when an instance has no
explicit key. Credentials are never included in Inventory metadata or logs.

## Configuration

```yaml
extensions:
  llm:
    grok:
      instances:
        primary:
          enabled: true
          endpoint: https://api.x.ai
          tier: cloud
          credentials:
            api_key: <resolved-api-key>
          fleet:
            enabled: false
            respond_to_requests: false
```

An instance without a resolved key is not discovered or published. The default
endpoint is `https://api.x.ai`. HTTPS connections enable certificate validation.
The shared discovery actor reads `/v1/models`, `/v1/language-models`, and
`/v1/image-generation-models`; catalog facts are joined by exact model ID.
Only catalogued language and image generation models are published.

## Supported operations

| Operation | Implementation |
|---|---|
| Chat | `POST /v1/responses` |
| Streaming chat | Responses SSE, with final response normalization |
| Function calls | Canonical tool definitions, call IDs, arguments, and results |
| Image input | Canonical URL or base64 image blocks |
| Image generation | `POST /v1/images/generations` |

Embedding, audio, moderation, and exact token counting are not advertised in
Inventory. Image editing is not implemented. Model capabilities such as vision
and reasoning are published only when the xAI catalog supplies evidence.

The shared provider funnel enforces `Canonical::Message` and
`Canonical::ToolDefinition` at dispatch. The Grok translator is the only layer
that renders xAI wire shapes or parses them back into `Canonical::Response` and
`Canonical::Chunk`. Unknown or unsupported sampling fields raise instead of
being silently discarded.

Responses requests set `store: false` and request encrypted reasoning. The
returned encrypted item is preserved as Canonical
thinking metadata. A later request can carry that item in an assistant
message's `metadata[:grok_reasoning]`; the translator sends it back unchanged.
The calling pipeline is responsible for retaining that metadata across turns.

## Development

```bash
bundle lock --local
bundle exec rspec --format json --out tmp/rspec_results.json --format progress --out tmp/rspec_progress.txt
bundle exec rubocop -A
```

Tests use documented xAI response shapes and local fakes. They do not contact
xAI or certify live account entitlements. `Gemfile.lock` and built gems are
ignored.
