# LiteLLM

## Mistral setup

Before merging the Mistral configuration:

1. Create a Mistral API key using the [Studio quickstart](https://docs.mistral.ai/getting-started/quickstarts/studio/activate-and-generate-api-key), with access to `mistral-small-2603` and `mistral-large-4-0`.
2. Store the key in the `password` field of a 1Password item named `Mistral - LiteLLM` in the `Kubernetes` vault. Keep the key out of Git and terminal output.

The `onepassword-connect` ClusterSecretStore can also read the `Infrastructure - Automation` vault. Use a unique item name across these vaults to avoid lookup ambiguity.

The `litellm` ExternalSecret maps that field to `MISTRAL_API_KEY` in the `ai/litellm` Secret. Both LiteLLMModel resources reference that Secret directly; no proxy environment variable is needed. The ExternalSecret refresh interval is 12 hours. A missing item or field prevents the shared ExternalSecret from refreshing successfully.

The exposed model names are `mistral/small-4` and `mistral/large-4`. Both are allowed by the Hermes virtual key; the default Hermes model is unchanged.

After deployment, check the `litellm` ExternalSecret and the two LiteLLMModel resources in namespace `ai`, then test each model through LiteLLM. Local manifest rendering does not verify credentials, account access, or API responses.
